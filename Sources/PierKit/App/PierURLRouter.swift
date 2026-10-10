import AppKit

/// Routes `pier://` URLs: attention requests (see `AttentionCommand`) plus folder control.
///
///     pier://open?folder=Developer%20Tools&style=launchpad    open a folder by name (style optional)
///     pier://close                                            close popups and inline folders
@MainActor
enum PierURLRouter {
    static func handle(_ url: URL) {
        switch url.host?.lowercased() {
        case "open": openFolder(url)
        case "close":
            PopupController.shared.dismiss()
            DockController.shared.setExpandedFolder(nil)
        default: AttentionService.shared.handle(url)
        }
    }

    private static func openFolder(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let name = items.first(where: { $0.name == "folder" })?.value?.lowercased(),
              let folder = PierStore.shared.layout.allItems.first(where: { $0.folder?.name.lowercased() == name })
        else { return }
        let style = items.first(where: { $0.name == "style" })?.value.flatMap(FolderStyle.init(rawValue:))
        DockController.shared.openFolder(folder.id, as: style)
    }
}
