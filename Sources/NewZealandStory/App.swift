import AppKit
import UniformTypeIdentifiers
import NZSCore
import AmigaEmu

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var view: GameView!
    var host: GameHost?
    let audio = AudioOutput()
    static let diskKey = "DiskImagePath", scaleKey = "WindowScale", scoresKey = "HighScores"

    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let scale = max(1, UserDefaults.standard.integer(forKey: AppDelegate.scaleKey) == 0 ? 3 : UserDefaults.standard.integer(forKey: AppDelegate.scaleKey))
        view = GameView(frame: NSRect(x: 0, y: 0, width: Video.width * scale, height: Video.height * scale))
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "The New Zealand Story"
        window.contentView = view
        window.contentAspectRatio = NSSize(width: Video.width, height: Video.height)
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        audio.start()
        view.startDisplayLink()
        // Diagnostics: --snapshot <png> <seconds> saves what the view presents, then quits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count, let secs = Double(args[i + 2]) {
            let out = args[i + 1]
            Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
                if let px = self?.host?.takeFrame(), !px.isEmpty {
                    try? ImageFile.writePNG(out, width: Video.width, height: Video.height, pixels: px, scale: 2)
                }
                if let steps = self?.view.pacingSteps, !steps.isEmpty {
                    let tail = steps.suffix(steps.count / 2)
                    var hist = [Int: Int](); for x in tail { hist[x, default: 0] += 1 }
                    print("refreshes:", tail.count, "frames advanced per refresh:", hist.sorted { $0.key < $1.key })
                    print("sequence:", tail.prefix(90).map(String.init).joined())
                }
                print("snapshot written; frame \(self?.host?.runtime.machine.frame ?? -1); audio engine running: \(self?.audio.engineRunning ?? false)")
                NSApp.terminate(nil)
            }
        }
        if let i = args.firstIndex(of: "--reset-at"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in self?.reset(nil) }
        }
        if let path = UserDefaults.standard.string(forKey: AppDelegate.diskKey), FileManager.default.fileExists(atPath: path) {
            startGame(path)
        } else {
            openDisk(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func storeHighScores() {
        if let hs = host?.latestHighScores() { UserDefaults.standard.set(Data(hs), forKey: AppDelegate.scoresKey) }
    }

    func startGame(_ path: String) {
        storeHighScores()
        host?.stop()
        host = nil
        do {
            let disk = try DiskImage(contentsOf: URL(fileURLWithPath: path))
            _ = try GameData(disk: disk)                  // validates the disk layout
            let h = try GameHost(disk: disk, audio: audio)
            h.onStop = { [weak self] msg in self?.gameStopped(msg) }
            view.host = h
            host = h
            h.start(restoringHighScores: (UserDefaults.standard.data(forKey: AppDelegate.scoresKey)).map { [UInt8]($0) })
            UserDefaults.standard.set(path, forKey: AppDelegate.diskKey)
            window.title = "The New Zealand Story"
        } catch {
            alert("This disk image could not be used", "\(error)\n\nChoose the New Zealand Story ADF.")
        }
    }

    func gameStopped(_ message: String) {
        FileHandle.standardError.write(("game stopped: " + message + "\n").data(using: .utf8)!)
        if message.contains("reset") {      // the original exits by jumping into Kickstart: restart it
            if let p = UserDefaults.standard.string(forKey: AppDelegate.diskKey) { startGame(p) }
            return
        }
        alert("The game stopped", message)
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    // MARK: menu
    func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title); items.forEach(m.addItem)
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: ""); it.submenu = m; main.addItem(it)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; return i
        }
        sub("New Zealand Story", [
            item("About The New Zealand Story", #selector(about(_:)), ""),
            .separator(),
            item("Hide", #selector(NSApplication.hide(_:)), "h"),
            item("Quit", #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub("File", [
            item("Open Disk Image…", #selector(openDisk(_:)), "o"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        sub("Game", [
            item("Pause", #selector(togglePause(_:)), "p"),
            item("Reset", #selector(reset(_:)), "r"),
            .separator(),
            item("Save State", #selector(saveState(_:)), "s"),
            item("Load State", #selector(loadState(_:)), "l"),
        ])
        sub("View", [
            item("Actual Size ×2", #selector(scale2(_:)), "2"),
            item("Size ×3", #selector(scale3(_:)), "3"),
            item("Size ×4", #selector(scale4(_:)), "4"),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        sub("Window", [item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")])
        NSApp.mainMenu = main
    }

    @objc func about(_ s: Any?) {
        alert("The New Zealand Story", "Native macOS port of the Amiga version (© 1988 Taito, 1989 Ocean; Amiga conversion by Choice Software).\n\nThe game code is translated from the original program; graphics, sound and levels are read from your own disk image at run time.\n\nControls: arrow keys to move, Space / Option / Control to fire. A gamepad also works.")
    }

    @objc func openDisk(_ s: Any?) {
        let p = NSOpenPanel()
        p.title = "Choose your New Zealand Story disk image (.adf)"
        p.allowedContentTypes = [UTType(filenameExtension: "adf") ?? .data]
        p.allowsOtherFileTypes = true
        if p.runModal() == .OK, let url = p.url { startGame(url.path) }
        else if host == nil { alert("No disk image", "The game needs your New Zealand Story ADF. Use File ▸ Open Disk Image…") }
    }

    @objc func togglePause(_ s: Any?) {
        guard let h = host else { return }
        h.setPaused(!h.isPaused)
        window.title = h.isPaused ? "The New Zealand Story — Paused" : "The New Zealand Story"
    }

    var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NewZealandStory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("quicksave.nzs")
    }

    @objc func saveState(_ s: Any?) {
        host?.requestSave { [weak self] data in
            guard let self else { return }
            do { try data.write(to: self.stateURL); self.flashTitle("State saved") }
            catch { self.alert("Could not save the state", "\(error)") }
        }
    }

    @objc func loadState(_ s: Any?) {
        guard let d = try? Data(contentsOf: stateURL) else { alert("No saved state", "Use Game ▸ Save State first."); return }
        host?.requestLoad(d)
        flashTitle("State loaded")
    }

    func flashTitle(_ t: String) {
        window.title = "The New Zealand Story — \(t)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let h = self.host else { return }
            self.window.title = h.isPaused ? "The New Zealand Story — Paused" : "The New Zealand Story"
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // AppKit also passes command-line arguments here; only accept disk images
        guard filename.lowercased().hasSuffix(".adf"), FileManager.default.fileExists(atPath: filename) else { return false }
        if window != nil { startGame(filename) } else { UserDefaults.standard.set(filename, forKey: AppDelegate.diskKey) }
        return true
    }

    @objc func reset(_ s: Any?) {
        if let p = UserDefaults.standard.string(forKey: AppDelegate.diskKey) { startGame(p) }
    }

    func setScale(_ k: Int) {
        UserDefaults.standard.set(k, forKey: AppDelegate.scaleKey)
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.setContentSize(NSSize(width: Video.width * k, height: Video.height * k))
    }
    @objc func scale2(_ s: Any?) { setScale(2) }
    @objc func scale3(_ s: Any?) { setScale(3) }
    @objc func scale4(_ s: Any?) { setScale(4) }

    func windowWillClose(_ n: Notification) { storeHighScores(); host?.stop() }
    func applicationWillTerminate(_ n: Notification) { storeHighScores() }
}
