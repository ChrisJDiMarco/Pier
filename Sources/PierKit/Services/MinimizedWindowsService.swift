import AppKit
import ApplicationServices
import Combine

public struct MinimizedWindow: Identifiable, Hashable {
    public let window: AppWindow
    public let app: AppRef
    public var id: CGWindowID { window.id }
    public var title: String { window.title.isEmpty ? app.name : window.title }
}

/// Tracks every minimized window so the dock can show them (the hidden macOS Dock would otherwise swallow
/// them). Event-driven: each app's Accessibility observer reports minimize/restore; a slow rescan catches
/// windows that close while minimized.
@MainActor
public final class MinimizedWindowsService: ObservableObject {
    public static let shared = MinimizedWindowsService()

    @Published public private(set) var windows: [MinimizedWindow] = []

    private var observers: [pid_t: AXObserver] = [:]
    private var perApp: [pid_t: [MinimizedWindow]] = [:]
    private var firstSeen: [CGWindowID: Date] = [:]
    private var bag = Set<AnyCancellable>()
    private var rescanTimer: Timer?
    private let rescanInterval: TimeInterval = 5

    private init() {}

    public func start() {
        guard AXIsProcessTrusted(), rescanTimer == nil else { return }
        RunningAppsService.shared.$apps
            .receive(on: RunLoop.main)
            .sink { [weak self] apps in self?.sync(with: apps) }
            .store(in: &bag)
        rescanTimer = Timer.scheduledTimer(withTimeInterval: rescanInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescanAll() }
        }
    }

    public func stop() {
        rescanTimer?.invalidate()
        rescanTimer = nil
        bag.removeAll()
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers = [:]
        perApp = [:]
        windows = []
    }

    // MARK: Observers

    private func sync(with apps: [RunningApp]) {
        let pids = Set(apps.map(\.pid))
        for pid in observers.keys where !pids.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            perApp.removeValue(forKey: pid)
        }
        for app in apps where observers[app.pid] == nil {
            observe(app.pid)
            rescan(app.pid, ref: app.ref)
        }
        publish()
    }

    private func observe(_ pid: pid_t) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, _ in
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MinimizedWindowsService.shared.rescan(pid) }
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AX.timeout)
        // Windows closed while minimized are caught by the periodic rescan.
        for name in [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    // MARK: Scanning

    private func rescanAll() {
        for app in RunningAppsService.shared.apps { rescan(app.pid, ref: app.ref) }
    }

    func rescan(_ pid: pid_t, ref: AppRef? = nil) {
        guard let ref = ref ?? RunningAppsService.shared.apps.first(where: { $0.pid == pid })?.ref else { return }
        Task.detached(priority: .utility) {
            let found = Self.readMinimized(pid: pid)
            await MainActor.run {
                let windows = found.map { MinimizedWindow(window: $0, app: ref) }
                if self.perApp[pid] != windows {
                    self.perApp[pid] = windows
                    self.publish()
                }
            }
        }
    }

    private func publish() {
        let now = Date()
        let all = perApp.values.flatMap { $0 }
        for w in all where firstSeen[w.id] == nil { firstSeen[w.id] = now }
        let live = Set(all.map(\.id))
        firstSeen = firstSeen.filter { live.contains($0.key) }
        // Oldest first, so newly minimized windows appear at the end like in the macOS Dock.
        let ordered = all.sorted { (firstSeen[$0.id] ?? now) < (firstSeen[$1.id] ?? now) }
        if ordered != windows { windows = ordered }
    }

    nonisolated static func readMinimized(pid: pid_t) -> [AppWindow] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AX.timeout)
        let elements = (AX.value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return elements.compactMap { element in
            guard AX.bool(element, kAXMinimizedAttribute) == true else { return nil }
            var wid: CGWindowID = 0
            _AXUIElementGetWindow(element, &wid)
            guard wid != 0 else { return nil }
            let origin = AX.point(element, kAXPositionAttribute) ?? .zero
            let size = AX.size(element, kAXSizeAttribute) ?? .zero
            return AppWindow(id: wid, pid: pid, title: AX.string(element, kAXTitleAttribute) ?? "",
                             frame: CGRect(origin: origin, size: size), isMinimized: true)
        }
    }
}
