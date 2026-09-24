// meeting-display — menu-bar indicator and switcher for which display OBS records.
//
// The menu-bar label always names the display the Meeting scene will record:
// red "● Studio Display" while recording, "○ Studio Display" when idle (what the
// next recording will use). The menu lists every display source; picking one
// switches to it. "Auto — follow Zoom" switches to whichever display holds the
// Zoom meeting window.
//
// It never touches OBS directly. meeting-notify.lua publishes its state to
// ~/Library/Logs/meeting-notify.display and applies whatever source name we drop
// into meeting-notify.display-request (see the "display switcher" section there).
//
// Compile: swiftc -O tools/meeting-display.swift -o ~/.local/bin/meeting-display
// Runs from launchd: launchd/com.meetingrecorder.meeting-display.plist

import AppKit
import ColorSync  // CGDisplayCreateUUIDFromDisplayID

let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
let statePath = logs.appendingPathComponent("meeting-notify.display")
let requestPath = logs.appendingPathComponent("meeting-notify.display-request")
let staleAfter: TimeInterval = 90     // the script rewrites the state at least every 30s
let followEvery: TimeInterval = 2
let followConfirmations = 2           // same target this many polls in a row before switching
let autoKey = "followZoom"

struct Source: Decodable { let name: String; let display_uuid: String; let visible: Bool }
struct State: Decodable { let recording: Bool; let scene: String; let sources: [Source]; let updated: TimeInterval }

struct Screen { let uuid: String; let name: String; let bounds: CGRect }

func connectedScreens() -> [Screen] {
    NSScreen.screens.compactMap { s in
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(n.uint32Value)
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let str = CFUUIDCreateString(nil, u) as String? else { return nil }
        // CGDisplayBounds is in the same top-left-origin space as window bounds.
        return Screen(uuid: str.uppercased(), name: s.localizedName, bounds: CGDisplayBounds(id))
    }
}

/// The display holding Zoom's meeting window, or nil when there is nothing to follow.
/// Window titles would need Screen Recording permission, so this uses only owner and
/// geometry: the largest normal-layer zoom.us window. Zoom's other windows (toolbar,
/// reactions, the floating thumbnail while you share) are far smaller, and when none
/// is big enough we hold the current display rather than guess.
func zoomScreen(_ screens: [Screen]) -> Screen? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return nil }
    var best: CGRect?
    for w in list {
        guard w[kCGWindowOwnerName as String] as? String == "zoom.us",
              w[kCGWindowLayer as String] as? Int == 0,
              let dict = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: dict),
              r.width * r.height >= 480 * 360 else { continue }
        if r.width * r.height > (best.map { $0.width * $0.height } ?? 0) { best = r }
    }
    guard let r = best else { return nil }
    return screens.first { $0.bounds.contains(CGPoint(x: r.midX, y: r.midY)) }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var state: State?
    var pendingTarget: String?
    var pendingCount = 0

    var followZoom: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: followEvery, repeats: true) { [weak self] _ in self?.follow() }
    }

    /// Current state, or nil if OBS/the script is gone or has stopped updating.
    func freshState() -> State? {
        guard let data = try? Data(contentsOf: statePath),
              let s = try? JSONDecoder().decode(State.self, from: data),
              Date().timeIntervalSince1970 - s.updated < staleAfter else { return nil }
        return s
    }

    func label(for src: Source, _ screens: [Screen]) -> (String, Bool) {
        if let s = screens.first(where: { $0.uuid == src.display_uuid.uppercased() }) { return (s.name, true) }
        return (src.name + " (disconnected)", false)
    }

    func refresh() {
        state = freshState()
        let screens = connectedScreens()
        let (text, color): (String, NSColor)
        if let s = state {
            let active = s.sources.first { $0.visible }
            if s.recording && s.scene != "Meeting" {
                (text, color) = ("● " + s.scene, .systemRed)
            } else if let a = active {
                let (name, connected) = label(for: a, screens)
                if !connected { (text, color) = ("⚠ " + name, .systemOrange) }
                else if s.recording { (text, color) = ("● " + name, .systemRed) }
                else { (text, color) = ("○ " + name, .labelColor) }
            } else {
                (text, color) = ("⚠ no display selected", .systemOrange)
            }
        } else {
            let obsUp = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == "com.obsproject.obs-studio"
            }
            (text, color) = obsUp ? ("⚠ OBS script not responding", .systemOrange) : ("○ OBS off", .secondaryLabelColor)
        }
        item.button?.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color, .font: NSFont.menuBarFont(ofSize: 0),
        ])
    }

    func request(_ sourceName: String) {
        let tmp = requestPath.appendingPathExtension("tmp")
        do {
            try (sourceName + "\n").write(to: tmp, atomically: false, encoding: .utf8)
            // rename(2) is atomic, so the script never reads a half-written request.
            if rename(tmp.path, requestPath.path) != 0 {
                NSLog("meeting-display: could not place switch request: errno \(errno)")
            }
        } catch {
            NSLog("meeting-display: could not write switch request: \(error)")
        }
    }

    func follow() {
        guard followZoom, let s = state, let target = zoomScreen(connectedScreens()),
              let src = s.sources.first(where: { $0.display_uuid.uppercased() == target.uuid }),
              !src.visible else {
            pendingTarget = nil
            return
        }
        // Debounce, so dragging the Zoom window across screens doesn't flip-flop.
        if pendingTarget == src.name { pendingCount += 1 } else { (pendingTarget, pendingCount) = (src.name, 1) }
        if pendingCount >= followConfirmations {
            request(src.name)
            pendingTarget = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let s = state else {
            menu.addItem(withTitle: "OBS is not running (or its script is not responding)", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            return
        }
        menu.addItem(withTitle: s.recording ? "Recording:" : "Next recording will capture:", action: nil, keyEquivalent: "")
        let screens = connectedScreens()
        for src in s.sources {
            let (name, connected) = label(for: src, screens)
            let mi = NSMenuItem(title: name, action: connected ? #selector(pick(_:)) : nil, keyEquivalent: "")
            mi.target = self
            mi.representedObject = src.name
            mi.state = src.visible ? .on : .off
            mi.indentationLevel = 1
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let auto = NSMenuItem(title: "Auto — follow Zoom window", action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = followZoom ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        // A manual choice would be undone by the next follow poll, so it turns Auto off.
        followZoom = false
        request(name)
    }

    @objc func toggleAuto() { followZoom.toggle() }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
