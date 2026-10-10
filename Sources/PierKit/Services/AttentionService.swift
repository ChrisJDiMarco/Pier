import AppKit
import Combine
import os

enum AttentionLog {
    static let log = Logger(subsystem: "com.logicoutloud.Pier", category: "attention")
}

public struct AgentBadge: Equatable {
    public var text: String
    public var color: String?
    public var sticky: Bool
}

/// Holds bounce / badge / message / flash requests made through `pier://` URLs, keyed by `AppRef.key`.
/// Everything clears when the user opens the app (badges can opt out with `sticky`).
@MainActor
public final class AttentionService: ObservableObject {
    public static let shared = AttentionService()

    @Published public private(set) var bouncing: Set<String> = []
    @Published public private(set) var flashing: Set<String> = []
    @Published public private(set) var badges: [String: AgentBadge] = [:]
    @Published public private(set) var messages: [String: String] = [:]

    /// One bounce of `BounceContainer` (sin(t·π·1.6)) lasts 0.625 s.
    static let bounceDuration: TimeInterval = 0.625
    private let messageDuration: TimeInterval = 6
    private let flashDuration: TimeInterval = 2.4
    private let untilOpenedLimit: TimeInterval = 300
    /// When each effect should end, keyed "slot:appKey". A newer request extends it; clearing removes it.
    private var deadlines: [String: Date] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let ref = app.bundleURL.flatMap(AppRef.init(url:)) else { return }
            MainActor.assumeIsolated { self?.userOpened(ref.key) }
        }
    }

    public func handle(_ url: URL) {
        guard let command = AttentionCommand.parse(url) else {
            AttentionLog.log.error("ignored invalid attention URL")
            return
        }
        apply(command)
    }

    public func apply(_ command: AttentionCommand) {
        if command.action == .clear && command.app.lowercased() == "all" {
            for key in Set(bouncing).union(flashing).union(badges.keys).union(messages.keys) { clear(key) }
            return
        }
        guard let key = resolve(command.app) else {
            AttentionLog.log.notice("no dock app matches \(command.app, privacy: .public)")
            return
        }
        AttentionLog.log.notice("\(command.action.rawValue, privacy: .public) \(key, privacy: .public)")
        if command.action == .clear { return clear(key) }

        if let bounces = command.bounces {
            bouncing.insert(key)
            let seconds = bounces == AttentionCommand.untilOpened
                ? untilOpenedLimit : Double(bounces) * Self.bounceDuration
            extend("bounce", key, by: seconds) { [weak self] in self?.bouncing.remove(key) }
        }
        if let text = command.badge {
            badges[key] = AgentBadge(text: text, color: command.color, sticky: command.sticky)
        }
        if let message = command.message {
            messages[key] = message
            extend("message", key, by: messageDuration) { [weak self] in self?.messages.removeValue(forKey: key) }
        }
        if command.flash {
            flashing.insert(key)
            extend("flash", key, by: flashDuration) { [weak self] in self?.flashing.remove(key) }
        }
    }

    public func badge(for ref: AppRef) -> AgentBadge? { badges[ref.key] }

    // MARK: Private

    /// Matches a bundle id, app name or path against apps in the dock (pinned, in folders, or running),
    /// then against installed apps.
    private func resolve(_ query: String) -> String? {
        let q = query.lowercased()
        let candidates = PierStore.shared.layout.pinnedApps + RunningAppsService.shared.apps.map(\.ref)
        if let hit = candidates.first(where: {
            $0.bundleID?.lowercased() == q || $0.name.lowercased() == q || $0.path.lowercased() == q
        }) {
            return hit.key
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query), let ref = AppRef(url: url) {
            return ref.key
        }
        return nil
    }

    private func userOpened(_ key: String) {
        for slot in ["bounce", "message", "flash"] { deadlines.removeValue(forKey: "\(slot):\(key)") }
        bouncing.remove(key)
        flashing.remove(key)
        messages.removeValue(forKey: key)
        if badges[key]?.sticky != true { badges.removeValue(forKey: key) }
    }

    private func clear(_ key: String) {
        for slot in ["bounce", "message", "flash"] { deadlines.removeValue(forKey: "\(slot):\(key)") }
        bouncing.remove(key)
        flashing.remove(key)
        badges.removeValue(forKey: key)
        messages.removeValue(forKey: key)
    }

    private func extend(_ slot: String, _ key: String, by seconds: TimeInterval, end: @escaping () -> Void) {
        let id = "\(slot):\(key)"
        let until = Date().addingTimeInterval(seconds)
        deadlines[id] = max(deadlines[id] ?? .distantPast, until)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, let deadline = self.deadlines[id], Date() >= deadline.addingTimeInterval(-0.05) else { return }
            self.deadlines.removeValue(forKey: id)
            end()
        }
    }
}
