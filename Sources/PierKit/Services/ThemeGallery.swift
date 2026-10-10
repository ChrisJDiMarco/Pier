import AppKit
import Combine

/// Community themes: the ones bundled with the app, plus whatever is in the repo's `themes/` folder.
/// The gallery URL comes from Info.plist (`PierThemeGalleryURL`) so forks can point at their own repo.
@MainActor
public final class ThemeGallery: ObservableObject {
    public static let shared = ThemeGallery()

    public enum Status: Equatable {
        case idle, loading, online, offline
    }

    @Published public private(set) var themes: [Theme] = []
    @Published public private(set) var status: Status = .idle

    private let maxIndexBytes = 256 * 1024
    private let maxThemeBytes = 64 * 1024
    private let maxThemes = 300

    private init() {}

    var baseURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "PierThemeGalleryURL") as? String).flatMap(URL.init(string:))
    }

    public func load() async {
        guard status != .loading else { return }
        status = .loading
        var byID: [String: Theme] = [:]
        var order: [String] = []
        func add(_ theme: Theme) {
            if byID[theme.id] == nil { order.append(theme.id) }
            byID[theme.id] = theme
        }
        bundled().forEach(add)
        themes = order.compactMap { byID[$0] }

        guard let base = baseURL, let remote = await fetchRemote(base) else {
            status = .offline
            return
        }
        remote.forEach(add)
        themes = order.compactMap { byID[$0] }
        status = .online
    }

    private func bundled() -> [Theme] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Themes"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "piertheme" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? JSONDecoder().decode(Theme.self, from: Data(contentsOf: $0)) }
    }

    private struct Index: Decodable {
        struct Entry: Decodable { let file: String }
        let themes: [Entry]
    }

    private func fetchRemote(_ base: URL) async -> [Theme]? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        guard let indexData = await fetch(base.appendingPathComponent("index.json"), session: session,
                                          limit: maxIndexBytes),
              let index = try? JSONDecoder().decode(Index.self, from: indexData)
        else { return nil }
        var result: [Theme] = []
        for entry in index.themes.prefix(maxThemes) {
            // Only plain file names inside the themes folder.
            guard entry.file.hasSuffix(".piertheme"), !entry.file.contains("/"), !entry.file.contains("..") else { continue }
            if let data = await fetch(base.appendingPathComponent(entry.file), session: session, limit: maxThemeBytes),
               let theme = try? JSONDecoder().decode(Theme.self, from: data) {
                result.append(theme)
            }
        }
        return result
    }

    private func fetch(_ url: URL, session: URLSession, limit: Int) async -> Data? {
        guard url.scheme == "https",
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= limit
        else { return nil }
        return data
    }
}
