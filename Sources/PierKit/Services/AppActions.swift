import AppKit
import ApplicationServices

/// Everything you can do *to* an app from the dock.
@MainActor
public enum AppActions {

    /// Launches or activates an app the same way the Dock does: through LaunchServices, which also sends
    /// a reopen event so apps without windows (Finder, Mail…) open one.
    public static func open(_ ref: AppRef, newInstance: Bool = false) {
        let running = RunningAppsService.shared.running(ref) != nil
        if !running { RunningAppsService.shared.markLaunching(ref) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = newInstance
        NSWorkspace.shared.openApplication(at: ref.url, configuration: config) { _, error in
            if let error {
                NSLog("Pier: could not open \(ref.name): \(error.localizedDescription)")
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
    }

    public static func open(files: [URL], with ref: AppRef) {
        guard !files.isEmpty else { return open(ref) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: ref.url, configuration: config) { _, error in
            if let error { NSLog("Pier: could not open files with \(ref.name): \(error.localizedDescription)") }
        }
    }

    public static func bringToFront(pid: pid_t) {
        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, AX.timeout)
            AX.set(app, kAXFrontmostAttribute, kCFBooleanTrue)
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    public static func hide(_ ref: AppRef) {
        RunningAppsService.shared.nsApp(ref)?.hide()
    }

    public static func hideOthers(except ref: AppRef) {
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            if let url = app.bundleURL, let other = AppRef(url: url), other.matches(ref) { continue }
            app.hide()
        }
    }

    public static func showAll() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            app.unhide()
        }
    }

    public static func quit(_ ref: AppRef) {
        RunningAppsService.shared.nsApp(ref)?.terminate()
    }

    public static func forceQuit(_ ref: AppRef) {
        RunningAppsService.shared.nsApp(ref)?.forceTerminate()
    }

    public static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Sends ⌘N to the app after bringing it forward. Needs Accessibility to post the keystroke.
    public static func newWindow(_ ref: AppRef) {
        guard let app = RunningAppsService.shared.running(ref) else { return open(ref) }
        bringToFront(pid: app.pid)
        guard AXIsProcessTrusted() else { return open(ref) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0x2D, keyDown: true)  // N
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0x2D, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.postToPid(app.pid)
            up?.postToPid(app.pid)
        }
    }

    /// App Exposé via the Dock's private notification, falling back to Mission Control.
    public static func appExpose(_ ref: AppRef) {
        if let app = RunningAppsService.shared.running(ref) { bringToFront(pid: app.pid) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            typealias SendFn = @convention(c) (CFString, Int32) -> Void
            if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") {
                unsafeBitCast(sym, to: SendFn.self)("com.apple.expose.front.awake" as CFString, 0)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            }
        }
    }

    public static func openSystemSettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The localized App Store category of an app, used to name new folders ("Productivity", "Games"…).
    public static func categoryName(for ref: AppRef) -> String? {
        guard let raw = Bundle(url: ref.url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
              let last = raw.split(separator: ".").last
        else { return nil }
        let words = last.split(separator: "-").map { $0.capitalized }
        return words.joined(separator: " ")
    }

    public static func folderName(for apps: [AppRef]) -> String {
        let categories = apps.compactMap(categoryName(for:))
        if let first = categories.first, categories.allSatisfy({ $0 == first }) { return first }
        return categories.first ?? "Folder"
    }
}
