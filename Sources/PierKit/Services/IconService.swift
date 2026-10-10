import AppKit
import Combine
import UniformTypeIdentifiers

/// Resolves icons for dock items and manages user-chosen custom icons (stored in Application Support/Pier/Icons).
@MainActor
public final class IconService: ObservableObject {
    public static let shared = IconService()

    /// Bumped whenever a custom icon changes so views re-render.
    @Published public private(set) var revision = 0

    private let cache = NSCache<NSString, NSImage>()
    private var overrides: [String: String]
    private var overridesURL: URL { PierPaths.support.appendingPathComponent("icons.json") }

    private init() {
        let url = PierPaths.support.appendingPathComponent("icons.json")
        overrides = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    public func icon(for ref: AppRef) -> NSImage {
        let key = ref.key as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image: NSImage
        if let file = overrides[ref.key], let custom = NSImage(contentsOf: PierPaths.icons.appendingPathComponent(file)) {
            image = custom
        } else {
            image = NSWorkspace.shared.icon(forFile: ref.path)
        }
        cache.setObject(image, forKey: key)
        return image
    }

    public func icon(forPath path: String) -> NSImage {
        let key = "path:\(path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: key)
        return image
    }

    public func trashIcon(full: Bool) -> NSImage {
        NSImage(named: full ? NSImage.trashFullName : NSImage.trashEmptyName)
            ?? NSWorkspace.shared.icon(for: .folder)
    }

    public func hasCustomIcon(_ ref: AppRef) -> Bool { overrides[ref.key] != nil }

    /// Copies the chosen image into Pier's support folder and uses it for the app from now on.
    public func setCustomIcon(_ ref: AppRef, from source: URL) throws {
        guard let image = NSImage(contentsOf: source),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileReadCorruptFile) }
        let file = "\(ref.key.replacingOccurrences(of: "/", with: "_")).png"
        try png.write(to: PierPaths.icons.appendingPathComponent(file), options: .atomic)
        overrides[ref.key] = file
        persist()
    }

    public func resetCustomIcon(_ ref: AppRef) {
        if let file = overrides.removeValue(forKey: ref.key) {
            try? FileManager.default.removeItem(at: PierPaths.icons.appendingPathComponent(file))
        }
        persist()
    }

    /// Lets the user pick an image (PNG, JPEG, HEIC, ICNS…) for an app.
    public func chooseCustomIcon(for ref: AppRef) {
        let panel = NSOpenPanel()
        panel.title = "Choose an icon for \(ref.name)"
        panel.allowedContentTypes = [.image, .icns]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try setCustomIcon(ref, from: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "That image couldn’t be used as an icon."
            alert.runModal()
        }
    }

    private func persist() {
        cache.removeAllObjects()
        if let data = try? JSONEncoder().encode(overrides) { try? data.write(to: overridesURL, options: .atomic) }
        revision += 1
    }
}
