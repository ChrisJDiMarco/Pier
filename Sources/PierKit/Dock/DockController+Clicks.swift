import AppKit
import SwiftUI
import os

enum ClickLog {
    static let log = Logger(subsystem: "com.logicoutloud.Pier", category: "click")
}

extension DockController {

    /// Highlights the Now Playing button under the pointer while the mouse is down.
    func pressBegan(_ entryID: String, at point: CGPoint) {
        pressedControl = nowPlayingControl(entryID, at: point)
    }

    private func nowPlayingControl(_ entryID: String, at point: CGPoint?) -> NowPlayingControl? {
        guard let point, !position.isVertical, let el = geometry.element(entryID),
              el.kind == .widget(.nowPlaying), NowPlayingService.shared.current != nil
        else { return nil }
        let local = CGPoint(x: point.x - el.rect.minX, y: point.y - el.rect.minY)
        return NowPlayingLayout.control(at: local, in: el.rect.size)
    }

    /// Returns true when the trigger wants the context menu instead (handled by the interaction view).
    /// `point` is in dock-container coordinates, used for sub-targets inside widgets.
    func handleClick(_ entryID: String, trigger: ClickTrigger, at point: CGPoint? = nil) -> Bool {
        guard let entry = entry(entryID) else { return false }
        cancelPendingPreview()
        ClickLog.log.notice("click \(entryID, privacy: .public) \(trigger.rawValue, privacy: .public)")

        if let ref = entry.appRef {
            let action = settings.action(for: trigger)
            if action == .contextMenu { return true }
            if PopupController.shared.isShowingWindows, action != .showWindows { PopupController.shared.dismiss() }
            perform(action, on: ref, entry: entry)
            // Launching from an inline folder folds it back up, like closing a folder after picking an app.
            if case .folderApp = entry.kind, trigger == .click { setExpandedFolder(nil) }
            return false
        }

        // Non-app tiles only respond to plain clicks; scroll and modifiers are ignored.
        guard trigger == .click || trigger == .middleClick else { return false }
        if case .minimized(let w) = entry.kind {
            PopupController.shared.dismiss()
            WindowService.shared.focus(w.window)
            return false
        }
        guard case .item(let item) = entry.kind else { return false }
        switch item.content {
        case .folder: toggleFolder(item.id)
        case .stack: toggleStack(item.id)
        case .trash:
            PopupController.shared.dismiss()
            NSWorkspace.shared.open(FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)[0])
        case .widget(let kind):
            if kind == .nowPlaying, let control = nowPlayingControl(entryID, at: point) {
                let player = NowPlayingService.shared
                switch control {
                case .previous: player.previous()
                case .playPause: player.togglePlayPause()
                case .next: player.next()
                }
            } else if kind == .battery {
                openWidgetApp(kind)
            } else {
                toggleWidgetPopup(item.id, kind: kind)
            }
        default: break
        }
        return false
    }

    func toggleWidgetPopup(_ id: UUID, kind: WidgetKind) {
        if PopupController.shared.isShowing(.widget(id)) { return PopupController.shared.dismiss() }
        guard let anchor = screenRect(of: id.uuidString) else { return }
        let view: AnyView
        switch kind {
        case .nowPlaying: view = AnyView(NowPlayingPopupView().environmentObject(store))
        case .clock: view = AnyView(CalendarPopupView().environmentObject(store))
        case .weather: view = AnyView(WeatherPopupView().environmentObject(store))
        case .battery: return openWidgetApp(kind)
        }
        PopupController.shared.show(.widget(id), anchor: anchor, position: settings.position, theme: theme) { view }
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

    func openWidgetApp(_ kind: WidgetKind) {
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
        if expandedFolderID == id { return setExpandedFolder(nil) }
        openFolder(id)
    }

    func folderStyle(_ id: UUID) -> FolderStyle {
        let folder = store.layout.allItems.first { $0.id == id }?.folder
        let style = folder?.style ?? settings.folderStyle
        // The fan only makes sense rising from a bottom dock; side docks get the popover instead.
        return style == .fan && position.isVertical ? .popover : style
    }

    func openFolder(_ id: UUID, as override: FolderStyle? = nil) {
        PopupController.shared.dismiss()
        switch override ?? folderStyle(id) {
        case .inline:
            setExpandedFolder(id)
        case .launchpad:
            setExpandedFolder(nil)
            let view = FolderPopupView(folderID: id, large: true)
                .environmentObject(store)
                .environmentObject(running)
                .environmentObject(IconService.shared)
                .environmentObject(BadgeService.shared)
            PopupController.shared.showCentered(.folder(id), on: window?.targetScreen, theme: theme) { AnyView(view) }
        case .fan:
            setExpandedFolder(nil)
            guard let anchor = screenRect(of: id.uuidString) else { return }
            let view = FanFolderView(folderID: id)
                .environmentObject(store)
                .environmentObject(IconService.shared)
                .environmentObject(BadgeService.shared)
            PopupController.shared.show(.folder(id), anchor: anchor, position: position, theme: theme,
                                        chrome: false) { AnyView(view) }
        case .popover:
            setExpandedFolder(nil)
            guard let anchor = screenRect(of: id.uuidString) else { return }
            let view = FolderPopupView(folderID: id)
                .environmentObject(store)
                .environmentObject(running)
                .environmentObject(IconService.shared)
                .environmentObject(BadgeService.shared)
            PopupController.shared.show(.folder(id), anchor: anchor, position: position, theme: theme) {
                AnyView(view)
            }
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
