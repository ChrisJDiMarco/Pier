import AppKit
import Combine

public struct SpaceInfo: Equatable, Sendable {
    /// Stable identifier (the Space's UUID when macOS provides one).
    public let key: String
    /// "Desktop 2", matching Mission Control's numbering.
    public let name: String
}

/// Which desktop (Space) is active. macOS has no public API for this, so it uses the window server's
/// `CGSCopyManagedDisplaySpaces`, loaded dynamically (as AltTab, yabai and others do). If the symbol ever
/// disappears, `isAvailable` is false and per-Space docks simply stay off.
@MainActor
public final class SpaceService: ObservableObject {
    public static let shared = SpaceService()

    @Published public private(set) var current: SpaceInfo?

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private let connection: ConnectionFn?
    private let copySpaces: CopySpacesFn?
    private var observer: NSObjectProtocol?

    private init() {
        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
            return unsafeBitCast(sym, to: type)
        }
        connection = load("CGSMainConnectionID", as: ConnectionFn.self)
        copySpaces = load("CGSCopyManagedDisplaySpaces", as: CopySpacesFn.self)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        refresh()
    }

    public var isAvailable: Bool { connection != nil && copySpaces != nil }

    public func refresh(screen: NSScreen? = nil) {
        let next = readCurrent(screen: screen ?? NSScreen.screens.first)
        // Full-screen app Spaces report nil; keep the last desktop so the dock doesn't flip there.
        if let next, next != current { current = next }
    }

    private func readCurrent(screen: NSScreen?) -> SpaceInfo? {
        guard let connection, let copySpaces,
              let displays = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]],
              !displays.isEmpty
        else { return nil }
        let wanted = screen.flatMap(Self.displayUUID)
        let display = displays.first { ($0["Display Identifier"] as? String) == wanted } ?? displays[0]
        return Self.parse(display: display)
    }

    /// Picks the current Space out of one display's dictionary. Internal for testing.
    nonisolated static func parse(display: [String: Any]) -> SpaceInfo? {
        guard let current = display["Current Space"] as? [String: Any],
              (current["type"] as? Int ?? 0) == 0      // 0 = desktop, 4 = full-screen app
        else { return nil }
        let desktops = (display["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int ?? 0) == 0 }
        let uuid = current["uuid"] as? String ?? ""
        let managed = current["ManagedSpaceID"] as? Int
        let index = desktops.firstIndex {
            let u = $0["uuid"] as? String ?? ""
            return !uuid.isEmpty ? u == uuid : ($0["ManagedSpaceID"] as? Int) == managed
        } ?? 0
        let key = uuid.isEmpty ? "desktop-\(index + 1)" : uuid
        return SpaceInfo(key: key, name: "Desktop \(index + 1)")
    }

    private static func displayUUID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
