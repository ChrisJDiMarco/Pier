import AppKit
import SwiftUI

extension DockController {

    /// Returns true when the trigger wants the context menu instead (handled by the interaction view).
    func handleClick(_ entryID: String, trigger: ClickTrigger) -> Bool {
        guard let entry = entry(entryID) else { return false }
        cancelPendingPreview()

        if let ref = entry.appRef {
            let action = settings.action(for: trigger)
            if action == .contextMenu { return true }
            if PopupController.shared.isShowingWindows, action != .showWindows { PopupController.shared.dismiss() }
            perform(action, on: ref, entry: entry)
            return false
        }

        // Non-app tiles only respond to plain clicks; scroll and modifiers are ignored.
        guard trigger == .click || trigger == .middleClick else { return false }
        guard case .item(let item) = entry.kind else { return false }
        switch item.content {
        case .folder: toggleFolder(item.id)
        case .stack: toggleStack(item.id)
        case .trash:
            PopupController.shared.dismiss()
            NSWorkspace.shared.open(FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)[0])
        case .widget(let kind): openWidgetApp(kind)
        default: break
        }
        return false
    }

    func perform(_ action: ClickAction, on ref: AppRef, entry: DisplayEntry) {
        let app = running.running(ref)
        switch action {
        case .activate:
            AppActions.open(ref)
        case .activateOrHide:
            if let app, app.isActive { AppActions.hide(ref) } else { AppActions.open(ref) }
        case .showWindows:
            if let app { showWindowPreviews(for: entry, app: app, fromHover: false) } else { AppActions.open(ref) }
        case .cycleWindows:
            if let app { WindowService.shared.cycle(pid: app.pid) } else { AppActions.open(ref) }
        case .newWindow:
            AppActions.newWindow(ref)
        case .hide:
            AppActions.hide(ref)
        case .hideOthers:
            AppActions.open(ref)
            AppActions.hideOthers(except: ref)
        case .minimizeAll:
            if let app { WindowService.shared.minimizeAll(pid: app.pid) }
        case .quit:
            AppActions.quit(ref)
        case .revealInFinder:
            AppActions.reveal(ref.url)
        case .appExpose:
            if app != nil { AppActions.appExpose(ref) } else { AppActions.open(ref) }
        case .contextMenu, .nothing:
            break
        }
    }

    private func openWidgetApp(_ kind: WidgetKind) {
        switch kind {
        case .clock:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        case .weather:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.weather") {
                NSWorkspace.shared.open(url)
            }
        case .battery:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        case .nowPlaying:
            NowPlayingService.shared.openSourceApp()
        }
    }

    // MARK: Popups

    func toggleFolder(_ id: UUID) {
        if PopupController.shared.isShowing(.folder(id)) { return PopupController.shared.dismiss() }
        openFolder(id)
    }

    func openFolder(_ id: UUID) {
        guard let anchor = screenRect(of: id.uuidString) else { return }
        let view = FolderPopupView(folderID: id)
            .environmentObject(store)
            .environmentObject(running)
            .environmentObject(IconService.shared)
            .environmentObject(BadgeService.shared)
        PopupController.shared.show(.folder(id), anchor: anchor, position: settings.position, theme: theme) {
            AnyView(view)
        }
    }

    func toggleStack(_ id: UUID) {
        if PopupController.shared.isShowing(.stack(id)) { return PopupController.shared.dismiss() }
        guard let anchor = screenRect(of: id.uuidString),
              let item = store.layout.allItems.first(where: { $0.id == id }),
              case .stack(let path) = item.content
        else { return }
        let view = StackPopupView(path: path).environmentObject(store)
        PopupController.shared.show(.stack(id), anchor: anchor, position: settings.position, theme: theme) {
            AnyView(view)
        }
    }

    func showWindowPreviews(for entry: DisplayEntry, app: RunningApp, fromHover: Bool) {
        guard let anchor = screenRect(of: entry.id) else { return }
        let windows = WindowService.shared.windows(for: app.pid)
        if fromHover && windows.isEmpty {
            if PopupController.shared.isShowingWindows { PopupController.shared.dismiss() }
            return
        }
        if PopupController.shared.isShowing(.windows(entry.id)) { return }
        let view = WindowPreviewPopupView(app: app, windows: windows).environmentObject(store)
        PopupController.shared.show(.windows(entry.id), anchor: anchor, position: settings.position, theme: theme,
                                    hoverOwned: fromHover) {
            AnyView(view)
        }
    }
}
