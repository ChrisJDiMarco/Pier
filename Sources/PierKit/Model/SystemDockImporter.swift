import Foundation

/// Reads the macOS Dock's own layout (`com.apple.dock.plist`) so Pier's first launch looks like the user's Dock.
public enum SystemDockImporter {

    public static var dockPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
    }

    public static func importLayout(from url: URL = dockPlistURL) -> DockLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(plistData: data)
    }

    public static func parse(plistData: Data) -> DockLayout? {
        guard let root = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else { return nil }

        let apps = (root["persistent-apps"] as? [[String: Any]] ?? []).compactMap { tile -> DockItem? in
            if (tile["tile-type"] as? String) == "spacer-tile" || (tile["tile-type"] as? String) == "small-spacer-tile" {
                return DockItem(.separator)
            }
            guard let url = fileURL(of: tile), let ref = AppRef(url: url) else { return nil }
            return DockItem(.app(ref))
        }

        let others = (root["persistent-others"] as? [[String: Any]] ?? []).compactMap { tile -> DockItem? in
            guard let url = fileURL(of: tile) else { return nil }
            if url.pathExtension == "app", let ref = AppRef(url: url) { return DockItem(.app(ref)) }
            return DockItem(.stack(path: AppRef.normalize(url.path)))
        }

        guard !apps.isEmpty || !others.isEmpty else { return nil }
        return DockLayout(main: apps, trailing: others + [DockItem(.trash)])
    }

    private static func fileURL(of tile: [String: Any]) -> URL? {
        guard let tileData = tile["tile-data"] as? [String: Any],
              let fileData = tileData["file-data"] as? [String: Any],
              let urlString = fileData["_CFURLString"] as? String
        else { return nil }
        if let url = URL(string: urlString), url.isFileURL { return url }
        return URL(fileURLWithPath: urlString)
    }

    /// A sensible layout when no system Dock plist can be read.
    public static func fallbackLayout() -> DockLayout {
        let candidates = [
            "/System/Library/CoreServices/Finder.app",
            "/Applications/Safari.app",
            "/System/Applications/Mail.app",
            "/System/Applications/Messages.app",
            "/System/Applications/Calendar.app",
            "/System/Applications/Notes.app",
            "/System/Applications/Music.app",
            "/System/Applications/System Settings.app",
        ]
        let apps = candidates
            .filter { FileManager.default.fileExists(atPath: $0) }
            .compactMap { AppRef(url: URL(fileURLWithPath: $0)) }
            .map { DockItem(.app($0)) }
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        return DockLayout(main: apps, trailing: [DockItem(.stack(path: downloads)), DockItem(.trash)])
    }
}
