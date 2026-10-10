import AppKit
import ApplicationServices
import Combine

/// Mirrors notification badges by reading `AXStatusLabel` from the system Dock's accessibility tree.
/// The macOS Dock keeps running (auto-hidden) while Pier is active, so its badges stay current.
@MainActor
public final class BadgeService: ObservableObject {
    public static let shared = BadgeService()

    /// Badge text keyed by normalized app path, and by app title as a fallback.
    @Published public private(set) var badges: [String: String] = [:]

    private var timer: Timer?
    private var isPolling = false
    private let interval: TimeInterval = 2.0

    private init() {}

    public func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        badges = [:]
    }

    public func badge(for ref: AppRef) -> String? {
        badges[ref.path] ?? badges["title:\(ref.name)"]
    }

    private func poll() {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else {
            if !badges.isEmpty { badges = [:] }
            return
        }
        guard !isPolling else { return }
        isPolling = true
        let pid = dock.processIdentifier
        Task.detached(priority: .utility) {
            let next = Self.readBadges(dockPID: pid)
            await MainActor.run {
                self.isPolling = false
                if next != self.badges { self.badges = next }
            }
        }
    }

    nonisolated static func readBadges(dockPID: pid_t) -> [String: String] {
        let root = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(root, AX.timeout)
        var result: [String: String] = [:]
        for list in AX.children(of: root) where AX.string(list, kAXRoleAttribute) == "AXList" {
            for item in AX.children(of: list) {
                guard let label = AX.string(item, "AXStatusLabel"), !label.isEmpty else { continue }
                if let url = AX.url(item, kAXURLAttribute) {
                    result[AppRef.normalize(url.path)] = label
                }
                if let title = AX.string(item, kAXTitleAttribute) {
                    result["title:\(title)"] = label
                }
            }
        }
        return result
    }
}

/// Tiny typed helpers over the Accessibility C API.
enum AX {
    static let timeout: Float = 0.25

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (value(element, attribute) as? NSNumber)?.boolValue
    }

    static func url(_ element: AXUIElement, _ attribute: String) -> URL? {
        guard let raw = value(element, attribute) else { return nil }
        if CFGetTypeID(raw) == CFURLGetTypeID() { return (raw as! CFURL) as URL }
        return (raw as? String).flatMap(URL.init(string:))
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &s) ? s : nil
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }
}

/// Private but long-stable symbol (used by AltTab, Hammerspoon, etc.) mapping an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
