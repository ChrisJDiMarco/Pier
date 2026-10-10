import AppKit
import Combine

public struct RunningApp: Hashable, Identifiable {
    public let pid: pid_t
    public let ref: AppRef
    public let isActive: Bool
    public let isHidden: Bool
    public let launchDate: Date?
    public var id: pid_t { pid }
}

/// Mirrors `NSWorkspace.runningApplications` (regular apps only) as a published, ordered list.
@MainActor
public final class RunningAppsService: ObservableObject {
    public static let shared = RunningAppsService()

    @Published public private(set) var apps: [RunningApp] = []
    /// Apps the user just asked to launch, keyed by `AppRef.key`; drives the launch bounce.
    @Published public private(set) var launching: Set<String> = []

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didLaunchApplicationNotification || name == NSWorkspace.didActivateApplicationNotification,
                       let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                       let ref = app.bundleURL.flatMap(AppRef.init(url:)) {
                        self?.finishLaunching(ref)
                    }
                    self?.refresh()
                }
            })
        }
        refresh()
    }

    public func refresh() {
        let next = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app -> RunningApp? in
                guard let url = app.bundleURL, var ref = AppRef(url: url) else { return nil }
                if let name = app.localizedName { ref.name = name }
                return RunningApp(pid: app.processIdentifier, ref: ref, isActive: app.isActive,
                                  isHidden: app.isHidden, launchDate: app.launchDate)
            }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        if next != apps { apps = next }
    }

    public func running(_ ref: AppRef) -> RunningApp? {
        apps.first { $0.ref.matches(ref) }
    }

    public func nsApp(_ ref: AppRef) -> NSRunningApplication? {
        guard let pid = running(ref)?.pid else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    public func markLaunching(_ ref: AppRef) {
        launching.insert(ref.key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.finishLaunching(ref) }
    }

    private func finishLaunching(_ ref: AppRef) {
        if launching.contains(ref.key) { launching.remove(ref.key) }
    }
}
