import Foundation
import AppKit
import NZSCore
import NZSGame
import AmigaEmu

/// Runs the translated original on its own thread, paced by the audio output,
/// and hands finished frames to the view.
final class GameHost: @unchecked Sendable {
    let disk: DiskImage
    private(set) var runtime: Runtime
    private var thread: Thread?
    let audio: AudioOutput
    private let lock = NSLock()
    /// Recent 50 Hz frames, each stamped with the audio sample count at its
    /// end, so the display can show the frame whose sound is playing now.
    private var frames: [(stamp: Int, pixels: [UInt32])] = []
    private var input = JoystickState()
    private var keys: [UInt8] = []
    private var paused = false
    private let pauseCondition = NSCondition()
    var onFrameReady: (() -> Void)?
    var onStop: ((String) -> Void)?
    private var stopRequested = false
    private var saveCompletion: ((Data) -> Void)?
    private var loadData: Data?

    /// Save state: taken by the game thread at its next safe point.
    func requestSave(_ done: @escaping (Data) -> Void) { lock.lock(); saveCompletion = done; lock.unlock() }
    func requestLoad(_ d: Data) { lock.lock(); loadData = d; lock.unlock() }

    struct JoystickState { var up = false, down = false, left = false, right = false, fire = false }

    init(disk: DiskImage, audio: AudioOutput) throws {
        self.disk = disk
        self.audio = audio
        runtime = try Runtime(disk: disk)
    }

    /// Latest high-score table (copied on the game thread every 5 s).
    private(set) var highScores: [UInt8]?
    private var framesSinceScores = 0

    func start(restoringHighScores hs: [UInt8]?) {
        let rt = runtime
        rt.highScoreRestore = hs
        let m = rt.machine
        m.paula.sink = { [audio] l, r in audio.push(l, r) }
        // The game thread keeps the host alive until it has unwound (stop/reset).
        rt.onFrame = { self.frameBoundary() }
        let th = Thread {
            do { try rt.run() } catch {
                if !self.stopRequested { DispatchQueue.main.async { self.onStop?("\(error)") } }
            }
            rt.onFrame = nil            // break the cycle
            rt.machine.paula.sink = nil
        }
        th.stackSize = 1 << 28        // the original's main loop never returns; give it room
        th.qualityOfService = .userInteractive
        th.name = "NZS game"
        thread = th
        th.start()
    }

    /// Called on the game thread at every 50 Hz frame end.
    private func frameBoundary() {
        let m = runtime.machine
        let stamp = audio.writtenCount
        lock.lock()
        frames.append((stamp, m.video.lastFrame))
        if frames.count > 12 { frames.removeFirst(frames.count - 12) }
        let j = input
        if !keys.isEmpty { m.keyQueue.append(contentsOf: keys); keys.removeAll() }
        if let done = saveCompletion { runtime.saveRequest = { d in DispatchQueue.main.async { done(d) } }; saveCompletion = nil }
        if let d = loadData { runtime.pendingLoad = d; loadData = nil }
        lock.unlock()
        m.joyUp = j.up; m.joyDown = j.down; m.joyLeft = j.left; m.joyRight = j.right; m.joyFire = j.fire
        audio.ledFilter = m.ciaA.pra & 0x02 == 0       // power LED on = audio filter on
        framesSinceScores += 1
        if framesSinceScores >= 250 {
            framesSinceScores = 0
            let hs = runtime.currentHighScores()
            if Runtime.validHighScores(hs) { lock.lock(); highScores = hs; lock.unlock() }
        }
        onFrameReady?()
        // pacing: keep ~3 frames of audio queued (audio clock is the master)
        audio.waitForSpace()
        pauseCondition.lock()
        while paused && !stopRequested { pauseCondition.wait() }
        pauseCondition.unlock()
        // unwind the game thread cleanly: the runtime stops at its next service point
        if stopRequested { m.resetRequested = true }
    }

    func latestHighScores() -> [UInt8]? { lock.lock(); defer { lock.unlock() }; return highScores }

    /// Newest frame.
    func takeFrame() -> [UInt32] {
        lock.lock(); defer { lock.unlock() }
        return frames.last?.pixels ?? []
    }

    /// The newest frame whose sound has finished playing by sample position
    /// `pos` (nil: newest frame). Returns nil if no frame has reached `pos`.
    func takeFrame(atAudioPosition pos: Double?) -> (stamp: Int, pixels: [UInt32])? {
        lock.lock(); defer { lock.unlock() }
        guard let pos else { return frames.last }
        guard let i = frames.lastIndex(where: { Double($0.stamp) <= pos }) else { return nil }
        let f = frames[i]
        frames.removeFirst(i)          // keep the chosen frame and newer ones
        return f
    }

    func setInput(_ j: JoystickState) { lock.lock(); input = j; lock.unlock() }
    func keyEvent(_ amigaCode: UInt8, down: Bool) { lock.lock(); keys.append(down ? amigaCode : amigaCode | 0x80); lock.unlock() }

    var isPaused: Bool { paused }
    func setPaused(_ p: Bool) {
        pauseCondition.lock(); paused = p; pauseCondition.broadcast(); pauseCondition.unlock()
        audio.setMuted(p)
    }

    func stop() {
        stopRequested = true
        setPaused(false)
        audio.releaseWaiters()
    }
}
