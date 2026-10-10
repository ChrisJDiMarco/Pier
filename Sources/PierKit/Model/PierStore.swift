import AppKit
import Combine
import UniformTypeIdentifiers

public enum PierPaths {
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pier", isDirectory: true)
    }
    public static var layout: URL { support.appendingPathComponent("layout.json") }
    public static var settings: URL { support.appendingPathComponent("settings.json") }
    public static var theme: URL { support.appendingPathComponent("theme.json") }
    public static var themes: URL { support.appendingPathComponent("Themes", isDirectory: true) }
    public static var icons: URL { support.appendingPathComponent("Icons", isDirectory: true) }

    static func ensure() {
        for dir in [support, themes, icons] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

public extension UTType {
    static let pierTheme = UTType(exportedAs: "com.logicoutloud.pier.theme", conformingTo: .json)
}

/// The single source of truth for everything the user can change. Writes are debounced to disk.
@MainActor
public final class PierStore: ObservableObject {
    public static let shared = PierStore()

    @Published public var layout: DockLayout { didSet { scheduleSave() } }
    @Published public var settings: PierSettings { didSet { scheduleSave() } }
    @Published public var theme: Theme { didSet { scheduleSave() } }
    @Published public private(set) var userThemes: [Theme] = []

    private var saveWork: DispatchWorkItem?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private init() {
        PierPaths.ensure()
        layout = (Self.load(DockLayout.self, from: PierPaths.layout)?.sanitized())
            ?? (SystemDockImporter.importLayout() ?? SystemDockImporter.fallbackLayout()).sanitized()
        settings = Self.load(PierSettings.self, from: PierPaths.settings) ?? PierSettings()
        theme = Self.load(Theme.self, from: PierPaths.theme) ?? .meadow
        reloadUserThemes()
    }

    public var allThemes: [Theme] { Theme.builtIns + userThemes }

    /// Loads a state file. A file that exists but can't be decoded is moved aside to `<name>.bak`
    /// (never silently overwritten) before falling back to defaults.
    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let value = try? JSONDecoder().decode(type, from: data) { return value }
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        NSLog("Pier: \(url.lastPathComponent) was unreadable; kept a copy at \(backup.path)")
        return nil
    }

    public func update(_ transform: (DockLayout) -> DockLayout) {
        layout = transform(layout).sanitized()
    }

    // MARK: Themes

    public func apply(_ newTheme: Theme) {
        theme = newTheme
    }

    public func reloadUserThemes() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: PierPaths.themes, includingPropertiesForKeys: nil)) ?? []
        userThemes = urls
            .filter { ["piertheme", "json"].contains($0.pathExtension) }
            .compactMap { try? JSONDecoder().decode(Theme.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func saveCurrentTheme(named name: String) throws -> Theme {
        var copy = theme
        copy.id = "user.\(UUID().uuidString)"
        copy.name = name
        copy.author = NSFullUserName()
        try write(copy, to: PierPaths.themes.appendingPathComponent(fileName(for: copy)))
        reloadUserThemes()
        theme = copy
        return copy
    }

    public func importTheme(from url: URL) throws -> Theme {
        var imported = try JSONDecoder().decode(Theme.self, from: Data(contentsOf: url))
        if Theme.builtIns.contains(where: { $0.id == imported.id }) || imported.id.isEmpty {
            imported.id = "user.\(UUID().uuidString)"
        }
        try write(imported, to: PierPaths.themes.appendingPathComponent(fileName(for: imported)))
        reloadUserThemes()
        theme = imported
        return imported
    }

    public func export(_ theme: Theme, to url: URL) throws {
        try write(theme, to: url)
    }

    public func deleteUserTheme(_ theme: Theme) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: PierPaths.themes, includingPropertiesForKeys: nil)) ?? []
        for url in urls {
            if let t = try? JSONDecoder().decode(Theme.self, from: Data(contentsOf: url)), t.id == theme.id {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        reloadUserThemes()
    }

    // MARK: Persistence

    public func resetLayoutToSystemDock() {
        layout = (SystemDockImporter.importLayout() ?? SystemDockImporter.fallbackLayout()).sanitized()
    }

    public func flush() {
        saveWork?.cancel()
        saveNow()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveNow() {
        do {
            try write(layout, to: PierPaths.layout)
            try write(settings, to: PierPaths.settings)
            try write(theme, to: PierPaths.theme)
        } catch {
            NSLog("Pier: failed to save state: \(error.localizedDescription)")
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func fileName(for theme: Theme) -> String {
        let safe = theme.name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "-")
        return "\(safe.isEmpty ? "theme" : safe)-\(theme.id.suffix(6)).piertheme"
    }
}
