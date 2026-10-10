import Foundation

/// Hides the macOS Dock by turning on auto-hide with a very long reveal delay, and restores the user's
/// original values afterwards. This is the same reversible technique every dock replacement uses.
@MainActor
public enum SystemDockManager {
    private static let domain = "com.apple.dock"
    private static let savedKey = "pier.savedSystemDock"
    private static let hiddenDelay = 1000.0

    public static var isHidden: Bool {
        CFPreferencesAppSynchronize(domain as CFString)
        let delay = CFPreferencesCopyAppValue("autohide-delay" as CFString, domain as CFString) as? Double
        return autohide && (delay ?? 0) >= hiddenDelay - 1
    }

    private static var autohide: Bool {
        (CFPreferencesCopyAppValue("autohide" as CFString, domain as CFString) as? Bool) ?? false
    }

    public static func hide() {
        guard !isHidden else { return }
        let delay = CFPreferencesCopyAppValue("autohide-delay" as CFString, domain as CFString) as? Double
        UserDefaults.standard.set(["autohide": autohide, "delay": delay ?? -1], forKey: savedKey)
        run(["write", domain, "autohide", "-bool", "true"])
        run(["write", domain, "autohide-delay", "-float", String(hiddenDelay)])
        restartDock()
    }

    public static func restore() {
        guard isHidden else { return }
        let saved = UserDefaults.standard.dictionary(forKey: savedKey)
        let wasAutohide = saved?["autohide"] as? Bool ?? false
        let delay = saved?["delay"] as? Double ?? -1
        run(["write", domain, "autohide", "-bool", wasAutohide ? "true" : "false"])
        if delay >= 0 && delay < hiddenDelay - 1 {
            run(["write", domain, "autohide-delay", "-float", String(delay)])
        } else {
            run(["delete", domain, "autohide-delay"])
        }
        UserDefaults.standard.removeObject(forKey: savedKey)
        restartDock()
    }

    private static func restartDock() {
        run(["Dock"], tool: "/usr/bin/killall")
    }

    private static func run(_ args: [String], tool: String = "/usr/bin/defaults") {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Pier: \(tool) \(args.joined(separator: " ")) failed: \(error.localizedDescription)")
        }
    }
}
