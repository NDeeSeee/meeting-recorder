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
// It also keeps the recording off dead displays. Unplugging the monitor that the
// visible source captures used to leave OBS recording black frames for days
// (capture-01). So this helper:
//   * publishes the online displays to ~/Library/Logs/meeting-notify.display-online
//     as {"online":["UUID",...],"main":"UUID","updated":<epoch>}, rewritten on every
//     display reconfiguration and at least every 15 s. The Lua reads it at record
//     start so it can pick a live display without shelling out;
//   * when the visible source's display goes offline, requests the effective
//     display (preferred if online, else the main display, else any online one)
//     and posts a notification;
//   * remembers a *preferred* display (the last manual pick, kept in
//     UserDefaults) apart from the *effective* one that is visible right now, and
//     switches back to the preferred display when it comes back online.
//
// Compile: swiftc -O tools/meeting-display.swift -o ~/.local/bin/meeting-display
// Runs from launchd: launchd/com.meetingrecorder.meeting-display.plist

import AppKit
import ColorSync  // CGDisplayCreateUUIDFromDisplayID

let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
let statePath = logs.appendingPathComponent("meeting-notify.display")
let requestPath = logs.appendingPathComponent("meeting-notify.display-request")
let onlinePath = logs.appendingPathComponent("meeting-notify.display-online")
let staleAfter: TimeInterval = 90     // the script rewrites the state at least every 30s
let followEvery: TimeInterval = 2
let followConfirmations = 2           // same target this many polls in a row before switching
let onlineRefresh: TimeInterval = 15  // rewrite an unchanged online file this often (contract: <= 30 s)
let requestRetry: TimeInterval = 5    // re-drop an identical request only after this long
let noticeCooldown: TimeInterval = 60 // a flapping cable must not post a Basso banner per flap
let autoKey = "followZoom"
let preferredKey = "preferredDisplayUUID"
let suspendKey = "followSuspended"

struct Source: Decodable { let name: String; let display_uuid: String; let visible: Bool }
struct State: Decodable { let recording: Bool; let scene: String; let sources: [Source]; let updated: TimeInterval }

struct Screen { let uuid: String; let name: String; let bounds: CGRect }

func displayUUID(_ id: CGDirectDisplayID) -> String? {
    guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
          let str = CFUUIDCreateString(nil, u) as String? else { return nil }
    return str.uppercased()
}

/// UUIDs of every online display. "Online" (unlike "active") includes displays that
/// are asleep or mirrored, so a display sleeping overnight does not count as gone:
/// falling back then would only flip sources for nothing, since every display
/// sleeps together.
func onlineUUIDs() -> [String] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).compactMap(displayUUID)
}

func connectedScreens() -> [Screen] {
    NSScreen.screens.compactMap { s in
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(n.uint32Value)
        guard let uuid = displayUUID(id) else { return nil }
        // CGDisplayBounds is in the same top-left-origin space as window bounds.
        return Screen(uuid: uuid, name: s.localizedName, bounds: CGDisplayBounds(id))
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

/// Banner via osascript rather than UNUserNotificationCenter: this binary is not an
/// app bundle, and UNUserNotificationCenter.current() aborts in an unbundled process.
/// Text goes in as argv, never spliced into the script, so no quoting can break it.
func notify(_ title: String, _ body: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "on run argv",
                   "-e", "display notification (item 2 of argv) with title (item 1 of argv) sound name \"Basso\"",
                   "-e", "end run", title, body]
    do { try p.run() } catch { NSLog("meeting-display: notification failed: \(error)") }
}

/// Called by CoreGraphics for every display add/remove/mode change. A C callback
/// cannot capture, so the App instance rides in userInfo.
func displayReconfigured(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
                         _ info: UnsafeMutableRawPointer?) {
    // Each change is announced twice; the "begin" half precedes the new layout.
    guard !flags.contains(.beginConfigurationFlag), let info = info else { return }
    let app = Unmanaged<App>.fromOpaque(info).takeUnretainedValue()
    DispatchQueue.main.async { app.displaysChanged() }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var state: State?
    var pendingTarget: String?
    var pendingCount = 0

    var online: Set<String> = []
    var onlineBody = ""                 // last online-file payload written, minus "updated"
    var onlineWrote: TimeInterval = 0
    var changeScheduled = false
    var lastRequest: (name: String, at: TimeInterval)?
    var outageNotice: String?           // notice already posted for the current outage (once each)
    var noticeAt: [String: TimeInterval] = [:]  // when each kind of notice last went out
    var preferredWasOffline = false     // preferred display left; restore it when it returns
    var lastRecording: Bool?            // to spot the end of a recording

    var followZoom: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }
    /// A manual pick pauses Zoom follow, which would otherwise undo it within two
    /// polls, but only until the current (or next) recording ends. It used to switch
    /// follow off for good, so one mid-meeting pick silently disabled it forever
    /// (capture-06). Persisted so a launchd restart does not drop the pause.
    /// A followZoom=false saved by that old bug is deliberately not migrated: it
    /// cannot be told apart from the user turning follow off, so re-enabling it is
    /// left to the owner (menu: "Auto — follow Zoom window").
    var followSuspended: Bool {
        get { UserDefaults.standard.bool(forKey: suspendKey) }
        set { UserDefaults.standard.set(newValue, forKey: suspendKey) }
    }
    /// The display the user wants recorded, by UUID (source names can be renamed in
    /// OBS; the display UUID is what the source is bound to).
    var preferred: String? {
        get { UserDefaults.standard.string(forKey: preferredKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferredKey) }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        online = Set(onlineUUIDs())
        publishOnline()
        refresh()
        // Two sources for the same event on purpose: the CG callback is the earliest
        // signal for hot-plug, the AppKit notification also covers arrangement and
        // main-display changes. Both are coalesced into one displaysChanged().
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.displaysChanged() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: followEvery, repeats: true) { [weak self] _ in self?.follow() }
    }

    /// Coalesce the burst of callbacks a single plug/unplug produces, then act.
    func displaysChanged() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.changeScheduled = false
            self.refresh()
        }
    }

    /// Writes the online-display file when it changed, or when it is about to look
    /// stale. Write-then-rename, so the Lua never reads half a file.
    func publishOnline() {
        let main = displayUUID(CGMainDisplayID()) ?? ""
        let list = online.sorted().map { "\"\($0)\"" }.joined(separator: ",")
        let body = "\"online\":[\(list)],\"main\":\"\(main)\""
        let now = Date().timeIntervalSince1970
        if body == onlineBody && now - onlineWrote < onlineRefresh { return }
        let tmp = onlinePath.appendingPathExtension("tmp")
        do {
            try "{\(body),\"updated\":\(Int(now))}\n".write(to: tmp, atomically: false, encoding: .utf8)
            if rename(tmp.path, onlinePath.path) == 0 {
                (onlineBody, onlineWrote) = (body, now)
            } else {
                NSLog("meeting-display: could not place online-display file: errno \(errno)")
            }
        } catch {
            NSLog("meeting-display: could not write online-display file: \(error)")
        }
    }

    /// Current state, or nil if OBS/the script is gone or has stopped updating.
    func freshState() -> State? {
        guard let data = try? Data(contentsOf: statePath),
              let s = try? JSONDecoder().decode(State.self, from: data),
              Date().timeIntervalSince1970 - s.updated < staleAfter else { return nil }
        return s
    }

    func isOnline(_ src: Source) -> Bool { online.contains(src.display_uuid.uppercased()) }

    func label(for src: Source, _ screens: [Screen]) -> (String, Bool) {
        let uuid = src.display_uuid.uppercased()
        guard online.contains(uuid) else { return (src.name + " (disconnected)", false) }
        // An online display that is asleep has no NSScreen; fall back to the source name.
        return (screens.first { $0.uuid == uuid }?.name ?? src.name, true)
    }

    /// Posts a banner unless the same kind of notice (same key) went out within
    /// noticeCooldown, so a loose cable or a monitor power-cycling does not spam.
    func throttledNotify(_ key: String, _ title: String, _ body: String) {
        let now = Date().timeIntervalSince1970
        if let t = noticeAt[key], now - t < noticeCooldown {
            NSLog("meeting-display: notice suppressed (cooldown): \(title): \(body)")
            return
        }
        noticeAt[key] = now
        notify(title, body)
    }

    /// Posts once per outage of the visible source: a repeat of the same notice is
    /// dropped, but a different one (e.g. "no display online" followed by "now
    /// recording X" once a display appears) still goes out, so the last banner the
    /// user saw is never stale.
    func outageNotify(_ key: String, _ title: String, _ body: String) {
        guard outageNotice != key else { return }
        outageNotice = key
        throttledNotify(key, title, body)
    }

    /// Where recording should go given only what is online: the preferred display,
    /// else the main display, else any online display (owner-decided order).
    func effectiveSource(_ s: State) -> Source? {
        let live = s.sources.filter(isOnline)
        if let p = preferred, let src = live.first(where: { $0.display_uuid.uppercased() == p }) { return src }
        if let m = displayUUID(CGMainDisplayID()),
           let src = live.first(where: { $0.display_uuid.uppercased() == m }) { return src }
        return live.first
    }

    /// Keep the visible source on a live display. Runs every second and right after
    /// a display change; cheap when nothing is wrong.
    func reconcile() {
        // Track the preferred display's absence even while OBS is off, so plugging
        // it back in before OBS starts still restores it once the state appears.
        if let p = preferred, !online.contains(p) { preferredWasOffline = true }
        guard let s = state else { return }

        // Recording just ended: a manual pick's pause on Zoom follow is over.
        if lastRecording == true && !s.recording && followSuspended { followSuspended = false }
        lastRecording = s.recording

        let visible = s.sources.first { $0.visible }
        // Seed the preferred display once, from whatever the user had chosen before
        // this logic existed, so a later unplug/replug restores it. Seed even when
        // that display is offline (the capture-01 state: Screen 2 visible, monitor
        // unplugged): seeding only from an online source would wait for the fallback
        // below and then adopt the built-in display, losing the real choice.
        if preferred == nil, let v = visible {
            preferred = v.display_uuid.uppercased()
            if !isOnline(v) { preferredWasOffline = true }
        }

        if let v = visible, !isOnline(v) {
            // The recorded display is gone: every frame from here on would be black.
            guard let target = effectiveSource(s) else {
                outageNotify("\(v.name)|none", "⚠ Recording display disconnected",
                             "\(v.name) is offline and no other display source is online.")
                return
            }
            request(target.name)
            if outageNotice != "\(v.name)|\(target.name)" {
                NSLog("meeting-display: \(v.name) offline, requesting \(target.name)")
            }
            outageNotify("\(v.name)|\(target.name)", "Display disconnected",
                         "\(v.name) is offline — now recording \(target.name).")
            return
        }
        outageNotice = nil

        // Bring the preferred display back once it returns. Only on the way back,
        // not continuously, so Zoom follow and the user stay free to move the
        // recording elsewhere while the preferred display is connected.
        guard let p = preferred, online.contains(p), preferredWasOffline else { return }
        preferredWasOffline = false
        // While Zoom follow is active and has a Zoom window to follow, it owns the
        // placement: restoring here would be undone two follow polls later, giving a
        // few seconds of the wrong display and a banner that is no longer true.
        if followZoom && !followSuspended && zoomScreen(connectedScreens()) != nil { return }
        if let src = s.sources.first(where: { $0.display_uuid.uppercased() == p }), !src.visible {
            request(src.name)
            throttledNotify("reconnect|\(src.name)", "Display reconnected", "Recording \(src.name) again.")
        }
    }

    func refresh() {
        online = Set(onlineUUIDs())
        publishOnline()
        state = freshState()
        reconcile()
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
        // The script polls every 500 ms, so the same request repeated every second
        // until the state catches up is just noise. Re-drop it only if it seems lost.
        let now = Date().timeIntervalSince1970
        if let last = lastRequest, last.name == sourceName, now - last.at < requestRetry { return }
        lastRequest = (sourceName, now)
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
        guard followZoom, !followSuspended, let s = state, let target = zoomScreen(connectedScreens()),
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
        func info(_ title: String) { menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false }
        guard let s = state else {
            info("OBS is not running (or its script is not responding)")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            return
        }
        if let v = s.sources.first(where: { $0.visible }), !isOnline(v) {
            info("⚠ Recorded display is disconnected — switching")
        }
        info(s.recording ? "Recording:" : "Next recording will capture:")
        let screens = connectedScreens()
        for src in s.sources {
            var (name, connected) = label(for: src, screens)
            if src.display_uuid.uppercased() == preferred { name += " — preferred" }
            if src.visible && !connected { name = "⚠ " + name }
            // A disconnected display cannot be picked: it would record black.
            let mi = NSMenuItem(title: name, action: connected ? #selector(pick(_:)) : nil, keyEquivalent: "")
            mi.target = self
            mi.isEnabled = connected
            mi.representedObject = src
            mi.state = src.visible ? .on : .off
            mi.indentationLevel = 1
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let paused = followZoom && followSuspended
        let auto = NSMenuItem(title: paused ? "Auto — follow Zoom window (paused until the recording ends)"
                                            : "Auto — follow Zoom window",
                              action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = !followZoom ? .off : (paused ? .mixed : .on)
        menu.addItem(auto)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard let src = sender.representedObject as? Source else { return }
        preferred = src.display_uuid.uppercased()
        preferredWasOffline = false
        // Otherwise the next follow poll would undo the pick; see followSuspended.
        if followZoom { followSuspended = true }
        lastRequest = nil  // an explicit pick always goes out
        request(src.name)
    }

    @objc func toggleAuto() {
        if followZoom && followSuspended { followSuspended = false }  // resume a paused follow
        else { followZoom.toggle(); followSuspended = false }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
