import AVFoundation
import os

/// Paula's 44.1 kHz stereo output -> AVAudioEngine via AVAudioSourceNode.
/// The ring buffer also paces the game thread (audio clock is the master).
///
/// Filtering is an APPROXIMATION of the A500: a fixed one-pole low-pass at
/// about 4.4 kHz, plus a two-pole ~3.3 kHz "LED" filter while the power LED
/// (CIA-A PRA bit 1) is on. Real filter shapes were not measured.
final class AudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode!
    private let capacity = 1 << 15
    private var ring: UnsafeMutablePointer<Float>
    private var readPos = 0, writePos = 0
    /// Stereo samples ever queued / ever played (or discarded). Frames are
    /// stamped with `written`; the display compares stamps with `consumed`.
    private var written = 0, consumed = 0, lastPullCount = 0
    private let lock = OSAllocatedUnfairLock()
    private let space = DispatchSemaphore(value: 0)
    private var waiting = false
    private var muted = false
    var ledFilter = false
    let targetFill = 44100 / 50 * 3
    // filter state
    private var lp1 = (0.0 as Float, 0.0 as Float), led1 = (0.0 as Float, 0.0 as Float), led2 = (0.0 as Float, 0.0 as Float)

    init() {
        ring = .allocate(capacity: 1 << 16)
        ring.initialize(repeating: 0, count: 1 << 16)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        node = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frames, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let l = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let r = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            self.pull(l, r, Int(frames))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
    }

    func start() {
        do { try engine.start(); engineRunning = true } catch { engineRunning = false }
    }

    private var fill: Int { (writePos - readPos + capacity) % capacity / 2 }

    /// Game thread: one stereo sample.
    func push(_ l: Int16, _ r: Int16) {
        var fl = Float(l) / 32768, fr = Float(r) / 32768
        // ~4.4 kHz one-pole (always on in the A500)
        let a: Float = 0.47
        lp1.0 += a * (fl - lp1.0); lp1.1 += a * (fr - lp1.1)
        fl = lp1.0; fr = lp1.1
        if ledFilter {
            let b: Float = 0.38
            led1.0 += b * (fl - led1.0); led1.1 += b * (fr - led1.1)
            led2.0 += b * (led1.0 - led2.0); led2.1 += b * (led1.1 - led2.1)
            fl = led2.0; fr = led2.1
        }
        lock.lock()
        written += 1
        if fill < capacity / 2 - 2 {
            ring[writePos] = fl; ring[writePos + 1] = fr
            writePos = (writePos + 2) % capacity
        } else { consumed += 1 }
        lock.unlock()
    }

    private var lastPull = DispatchTime.now()
    private var lastFrameTime = DispatchTime.now()
    private(set) var engineRunning = false

    /// Game thread: block while enough audio is queued. If the audio device is
    /// not consuming (no output, engine stopped), pace by the PAL frame period.
    func waitForSpace() {
        while true {
            lock.lock()
            let f = fill
            let stale = DispatchTime.now().uptimeNanoseconds - lastPull.uptimeNanoseconds > 200_000_000
            if stale || muted {
                lock.unlock()
                let period: UInt64 = 20_032_000      // 1 / 49.92 Hz
                let next = lastFrameTime.uptimeNanoseconds + period
                let now = DispatchTime.now().uptimeNanoseconds
                if next > now { Thread.sleep(forTimeInterval: Double(next - now) / 1e9) }
                lastFrameTime = DispatchTime(uptimeNanoseconds: max(next, now))
                if stale { lock.lock(); consumed += fill; readPos = writePos; lock.unlock() }
                return
            }
            if f < targetFill { lock.unlock(); lastFrameTime = .now(); return }
            waiting = true
            lock.unlock()
            _ = space.wait(timeout: .now() + .milliseconds(30))
        }
    }

    func releaseWaiters() { space.signal() }
    func setMuted(_ m: Bool) { lock.lock(); muted = m; if m { consumed += fill; readPos = writePos }; lock.unlock() }

    /// Sample count of everything queued so far (stamp for a finished frame).
    var writtenCount: Int { lock.lock(); defer { lock.unlock() }; return written }

    /// Estimated playback position (in samples) at host time `t` (seconds,
    /// CACurrentMediaTime base), or nil when the audio device is not the clock
    /// (no output, paused). Interpolated between the device's buffer pulls.
    func playbackPosition(at t: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let pulledAt = Double(lastPull.uptimeNanoseconds) / 1e9
        guard !muted, t - pulledAt < 0.2 else { return nil }
        let start = Double(consumed - lastPullCount)
        return min(Double(consumed) + Double(lastPullCount), start + (t - pulledAt) * 44100)
    }

    private func pull(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        lock.lock()
        lastPull = .now()
        lastPullCount = n
        for k in 0..<n {
            if readPos != writePos && !muted {
                l[k] = ring[readPos]; r[k] = ring[readPos + 1]
                readPos = (readPos + 2) % capacity
                consumed += 1
            } else { l[k] = 0; r[k] = 0 }
        }
        let wake = waiting && fill < targetFill
        if wake { waiting = false }
        lock.unlock()
        if wake { space.signal() }
    }
}
