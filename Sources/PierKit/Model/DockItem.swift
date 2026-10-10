import Foundation

/// A reference to an application bundle on disk.
public struct AppRef: Codable, Hashable, Sendable {
    public var bundleID: String?
    public var path: String
    public var name: String

    public init(bundleID: String?, path: String, name: String) {
        self.bundleID = bundleID
        self.path = AppRef.normalize(path)
        self.name = name
    }

    public init?(url: URL) {
        guard url.pathExtension == "app" else { return nil }
        let bundle = Bundle(url: url)
        let display = FileManager.default.displayName(atPath: url.path)
        let name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        self.init(bundleID: bundle?.bundleIdentifier, path: url.path, name: name)
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// Stable identity used to match running apps and badges.
    public var key: String { bundleID ?? path }

    public static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public func matches(_ other: AppRef) -> Bool {
        if let a = bundleID, let b = other.bundleID { return a == b }
        return path == other.path
    }
}

/// A user-made group of apps shown as a single tile.
public struct AppFolder: Codable, Hashable, Sendable {
    public var name: String
    public var apps: [AppRef]

    public init(name: String, apps: [AppRef]) {
        self.name = name
        self.apps = apps
    }
}

public enum WidgetKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case clock, nowPlaying, weather, battery

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .clock: return "Clock"
        case .nowPlaying: return "Now Playing"
        case .weather: return "Weather"
        case .battery: return "Battery"
        }
    }

    public var symbol: String {
        switch self {
        case .clock: return "clock"
        case .nowPlaying: return "music.note"
        case .weather: return "cloud.sun"
        case .battery: return "battery.75percent"
        }
    }

    /// Width of the widget relative to the dock's icon size.
    public var widthFactor: CGFloat {
        switch self {
        case .clock: return 1.34
        case .nowPlaying: return 3.8
        case .weather: return 2.2
        case .battery: return 1.2
        }
    }
}

public enum DockItemContent: Codable, Hashable, Sendable {
    case app(AppRef)
    case folder(AppFolder)
    case widget(WidgetKind)
    case stack(path: String)
    case separator
    case trash
}

public struct DockItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var content: DockItemContent

    public init(id: UUID = UUID(), _ content: DockItemContent) {
        self.id = id
        self.content = content
    }

    public var appRef: AppRef? {
        if case .app(let ref) = content { return ref }
        return nil
    }

    public var folder: AppFolder? {
        if case .folder(let folder) = content { return folder }
        return nil
    }

    public var displayName: String {
        switch content {
        case .app(let ref): return ref.name
        case .folder(let folder): return folder.name
        case .widget(let kind): return kind.title
        case .stack(let path): return FileManager.default.displayName(atPath: path)
        case .separator: return ""
        case .trash: return "Trash"
        }
    }
}

/// The persisted dock: a user-ordered main section and a trailing section (stacks, trash).
public struct DockLayout: Codable, Hashable, Sendable {
    public var main: [DockItem]
    public var trailing: [DockItem]

    public init(main: [DockItem], trailing: [DockItem]) {
        self.main = main
        self.trailing = trailing
    }

    public static let empty = DockLayout(main: [], trailing: [DockItem(.trash)])

    public enum Section: String, Codable, Sendable { case main, trailing }

    public func items(in section: Section) -> [DockItem] {
        section == .main ? main : trailing
    }

    public var allItems: [DockItem] { main + trailing }

    public func locate(_ id: UUID) -> (section: Section, index: Int)? {
        if let i = main.firstIndex(where: { $0.id == id }) { return (.main, i) }
        if let i = trailing.firstIndex(where: { $0.id == id }) { return (.trailing, i) }
        return nil
    }

    /// Every app pinned anywhere in the dock, including inside folders.
    public var pinnedApps: [AppRef] {
        allItems.flatMap { item -> [AppRef] in
            switch item.content {
            case .app(let ref): return [ref]
            case .folder(let folder): return folder.apps
            default: return []
            }
        }
    }

    public func isPinned(_ app: AppRef) -> Bool {
        pinnedApps.contains { $0.matches(app) }
    }
}
