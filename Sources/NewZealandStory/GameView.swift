import AppKit
import GameController
import QuartzCore
import AmigaEmu

/// Shows the emulated display canvas (352x272 lowres pixels incl. border) with
/// nearest-neighbour scaling, and turns keyboard / gamepad into joystick input.
final class GameView: NSView {
    var host: GameHost?
    private var pressed = Set<UInt16>()
    /// Width/height of one Amiga lowres pixel on screen. PAL lowres pixels are
    /// slightly wider than tall (~1.09); 1.0 keeps them square. Square by default.
    var pixelAspect: CGFloat = 1.0

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.magnificationFilter = .nearest
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: frame pacing
    // A display link fires once per screen refresh (vsync). Each refresh shows
    // the emulated frame that belongs to the sound now playing, read from a
    // smoothed audio clock. The game runs a few frames ahead of the speaker
    // and the audio device takes samples in bursts, so showing "the newest
    // frame" (as before) made frames arrive unevenly.
    private var link: CADisplayLink?
    private var clockBase = 0.0, clockTime = 0.0, clockValid = false
    private var shownStamp = -1

    func startDisplayLink() {
        let l = displayLink(target: self, selector: #selector(refresh(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func refresh(_ l: CADisplayLink) {
        updateJoystick()
        guard let host else { return }
        let t = l.targetTimestamp
        var pos: Double? = nil
        if let measured = host.audio.playbackPosition(at: t) {
            // Run a steady 44.1 kHz clock, nudged towards the measured position
            // so device-buffer jitter does not reach the picture.
            var p = clockBase + (t - clockTime) * 44100
            let err = measured - p
            if !clockValid || abs(err) > 4410 { p = measured } else { p += err * 0.05 }
            clockBase = p; clockTime = t; clockValid = true
            pos = p
        } else { clockValid = false }
        let f = host.takeFrame(atAudioPosition: pos)
        if GameView.pacingLog { pacingSteps.append(f.map { shownStamp < 0 ? 0 : Int((Double($0.stamp - shownStamp) / 882).rounded()) } ?? 0) }
        guard let f, f.stamp != shownStamp else { return }
        shownStamp = f.stamp
        present(f.pixels)
    }

    /// Diagnostics (--pacing-log): emulated frames advanced at each refresh.
    static let pacingLog = CommandLine.arguments.contains("--pacing-log")
    var pacingSteps: [Int] = []

    func present(_ pixels: [UInt32]) {
        guard pixels.count == Video.width * Video.height else { return }
        let w = Video.width, h = Video.height
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let p = pixels[i]
            rgba[i * 4] = UInt8(p >> 16 & 0xff); rgba[i * 4 + 1] = UInt8(p >> 8 & 0xff); rgba[i * 4 + 2] = UInt8(p & 0xff)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = img
        CATransaction.commit()
    }

    // MARK: input
    // Joystick: arrow keys or WASD-free cursor block; fire: Space, Right Alt/Option, Left Ctrl.
    static let joyKeys: [UInt16: String] = [0x7e: "up", 0x7d: "down", 0x7b: "left", 0x7c: "right",
                                            0x31: "fire", 0x3d: "fire", 0x3b: "fire"]

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) { super.keyDown(with: e); return }
        if !e.isARepeat { pressed.insert(e.keyCode); forwardKey(e.keyCode, down: true) }
        updateJoystick()
    }
    override func keyUp(with e: NSEvent) {
        pressed.remove(e.keyCode); forwardKey(e.keyCode, down: false)
        updateJoystick()
    }
    override func flagsChanged(with e: NSEvent) {
        for (code, flag) in [(UInt16(0x3d), NSEvent.ModifierFlags.option), (0x3b, .control)] where e.keyCode == code {
            if e.modifierFlags.contains(flag) { pressed.insert(code) } else { pressed.remove(code) }
        }
        updateJoystick()
    }

    private func forwardKey(_ code: UInt16, down: Bool) {
        guard GameView.joyKeys[code] == nil, let a = KeyMap.amiga[code] else { return }
        host?.keyEvent(a, down: down)
    }

    func updateJoystick() {
        var j = GameHost.JoystickState()
        for k in pressed {
            switch GameView.joyKeys[k] {
            case "up": j.up = true; case "down": j.down = true
            case "left": j.left = true; case "right": j.right = true
            case "fire": j.fire = true
            default: break
            }
        }
        if let pad = GCController.current?.extendedGamepad {
            j.up = j.up || pad.dpad.up.isPressed || pad.leftThumbstick.yAxis.value > 0.5
            j.down = j.down || pad.dpad.down.isPressed || pad.leftThumbstick.yAxis.value < -0.5
            j.left = j.left || pad.dpad.left.isPressed || pad.leftThumbstick.xAxis.value < -0.5
            j.right = j.right || pad.dpad.right.isPressed || pad.leftThumbstick.xAxis.value > 0.5
            j.fire = j.fire || pad.buttonA.isPressed || pad.buttonB.isPressed
        }
        host?.setInput(j)
    }
}

/// macOS virtual key codes -> Amiga raw key codes (US layout).
enum KeyMap {
    static let amiga: [UInt16: UInt8] = [
        0x32: 0x00, 0x12: 0x01, 0x13: 0x02, 0x14: 0x03, 0x15: 0x04, 0x17: 0x05, 0x16: 0x06, 0x1a: 0x07,
        0x1c: 0x08, 0x19: 0x09, 0x1d: 0x0a, 0x1b: 0x0b, 0x18: 0x0c, 0x2a: 0x0d,
        0x0c: 0x10, 0x0d: 0x11, 0x0e: 0x12, 0x0f: 0x13, 0x11: 0x14, 0x10: 0x15, 0x20: 0x16, 0x22: 0x17,
        0x1f: 0x18, 0x23: 0x19, 0x21: 0x1a, 0x1e: 0x1b,
        0x00: 0x20, 0x01: 0x21, 0x02: 0x22, 0x03: 0x23, 0x05: 0x24, 0x04: 0x25, 0x26: 0x26, 0x28: 0x27,
        0x25: 0x28, 0x29: 0x29, 0x27: 0x2a,
        0x06: 0x31, 0x07: 0x32, 0x08: 0x33, 0x09: 0x34, 0x0b: 0x35, 0x2d: 0x36, 0x2e: 0x37,
        0x2b: 0x38, 0x2f: 0x39, 0x2c: 0x3a,
        0x31: 0x40, 0x33: 0x41, 0x30: 0x42, 0x24: 0x44, 0x35: 0x45, 0x75: 0x46,
        0x7e: 0x4c, 0x7d: 0x4d, 0x7c: 0x4e, 0x7b: 0x4f,
        0x7a: 0x50, 0x78: 0x51, 0x63: 0x52, 0x76: 0x53, 0x60: 0x54, 0x61: 0x55, 0x62: 0x56, 0x64: 0x57, 0x65: 0x58, 0x6d: 0x59,
        0x38: 0x60, 0x3c: 0x61,
        0x72: 0x5f,   // Help/Insert -> HELP
    ]
}
