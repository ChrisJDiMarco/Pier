import AppKit

/// NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, state: NSControl.StateValue = .off, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.state = state
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

extension NSMenu {
    func add(_ title: String, state: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) {
        addItem(ActionMenuItem(title, state: state ? .on : .off, enabled: enabled, handler: handler))
    }

    func addSubmenu(_ title: String, build: (NSMenu) -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        build(sub)
        item.submenu = sub
        addItem(item)
    }

    func addHeader(_ title: String) {
        if #available(macOS 14.0, *) {
            addItem(NSMenuItem.sectionHeader(title: title))
        } else {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            addItem(item)
        }
    }
}

@MainActor
enum DockMenus {

    static func menu(for entry: DisplayEntry, controller: DockController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch entry.kind {
        case .running(let app):
            buildAppMenu(menu, ref: app.ref, itemID: nil, controller: controller)
        case .item(let item):
            switch item.content {
            case .app(let ref): buildAppMenu(menu, ref: ref, itemID: item.id, controller: controller)
            case .folder(let folder): buildFolderMenu(menu, folder: folder, id: item.id, controller: controller)
            case .stack(let path): buildStackMenu(menu, path: path, id: item.id, controller: controller)
            case .trash: buildTrashMenu(menu)
            case .widget(let kind): buildWidgetMenu(menu, kind: kind, id: item.id, controller: controller)
            case .separator:
                menu.add("Remove Separator", enabled: !controller.settings.lockLayout) {
                    controller.store.update { $0.removing(item.id) }
                }
            }
        case .minimized(let w):
            menu.addHeader(w.app.name)
            menu.add("Restore “\(w.title)”") { WindowService.shared.focus(w.window) }
            menu.add("Close Window") { WindowService.shared.close(w.window) }
            menu.addItem(.separator())
            menu.add("Show All \(w.app.name) Windows") { AppActions.appExpose(w.app) }
        default:
            return dockMenu(controller: controller)
        }
        return menu
    }

    // MARK: Apps

    private static func buildAppMenu(_ menu: NSMenu, ref: AppRef, itemID: UUID?, controller: DockController) {
        let store = controller.store
        let app = controller.running.running(ref)
        let locked = store.settings.lockLayout

        if let app {
            let windows = WindowService.shared.windows(for: app.pid)
            if !windows.isEmpty {
                menu.addHeader("Windows")
                for window in windows.prefix(12) {
                    let title = window.title.isEmpty ? ref.name : window.title
                    menu.add(window.isMinimized ? "\(title) (minimized)" : title) { WindowService.shared.focus(window) }
                }
                menu.addItem(.separator())
            }
        }

        menu.addSubmenu("Options") { sub in
            let pinned = store.layout.isPinned(ref)
            sub.add("Keep in Dock", state: pinned, enabled: !locked) {
                if pinned { store.update { $0.unpinning(ref) } } else { store.update { $0.pinning(ref) } }
            }
            if let itemID, !locked {
                let folders = store.layout.allItems.filter { $0.folder != nil }
                sub.addSubmenu("Add to Folder") { folderMenu in
                    for folder in folders {
                        folderMenu.add(folder.displayName) { store.update { $0.addingApp(ref, toFolder: folder.id) } }
                    }
                    if !folders.isEmpty { folderMenu.addItem(.separator()) }
                    folderMenu.add("New Folder…") {
                        let suggested = AppActions.folderName(for: [ref])
                        guard let name = prompt(title: "New Folder", value: suggested) else { return }
                        let folder = AppFolder(name: name.isEmpty ? suggested : name, apps: [ref])
                        store.update { $0.replacing(itemID, with: .folder(folder)) }
                    }
                }
            }
            sub.addItem(.separator())
            sub.add("Choose Custom Icon…") { IconService.shared.chooseCustomIcon(for: ref) }
            if IconService.shared.hasCustomIcon(ref) {
                sub.add("Reset Icon") { IconService.shared.resetCustomIcon(ref) }
            }
            sub.addItem(.separator())
            sub.add("Show in Finder") { AppActions.reveal(ref.url) }
        }
        menu.addItem(.separator())

        if let app {
            menu.add("Show All Windows") { AppActions.appExpose(ref) }
            menu.add(app.isHidden ? "Show" : "Hide") {
                if app.isHidden { AppActions.open(ref) } else { AppActions.hide(ref) }
            }
            let quit = ActionMenuItem("Quit") { AppActions.quit(ref) }
            let force = ActionMenuItem("Force Quit") { AppActions.forceQuit(ref) }
            force.isAlternate = true
            force.keyEquivalentModifierMask = .option
            menu.addItem(quit)
            menu.addItem(force)
        } else {
            menu.add("Open") { AppActions.open(ref) }
            if itemID != nil {
                menu.add("Remove from Dock", enabled: !locked) { store.update { $0.unpinning(ref) } }
            }
        }
    }

    // MARK: Folders, stacks, trash, widgets

    private static func buildFolderMenu(_ menu: NSMenu, folder: AppFolder, id: UUID, controller: DockController) {
        let store = controller.store
        let locked = store.settings.lockLayout
        menu.addHeader(folder.name)
        for app in folder.apps {
            menu.add(app.name) { AppActions.open(app) }
        }
        menu.addItem(.separator())
        menu.add("Open Folder") { controller.openFolder(id) }
        menu.add("Rename Folder…", enabled: !locked) {
            if let name = prompt(title: "Rename Folder", value: folder.name) {
                store.update { $0.renamingFolder(id, to: name) }
            }
        }
        menu.add("Ungroup", enabled: !locked) {
            store.update { layout in
                guard let loc = layout.locate(id) else { return layout }
                let apps = folder.apps.map { DockItem(.app($0)) }
                return apps.reversed().reduce(layout.removing(id)) { $0.inserting($1, in: loc.section, at: loc.index) }
            }
        }
        menu.add("Remove from Dock", enabled: !locked) { store.update { $0.removing(id) } }
    }

    private static func buildStackMenu(_ menu: NSMenu, path: String, id: UUID, controller: DockController) {
        menu.add("Open “\(FileManager.default.displayName(atPath: path))”") {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        menu.add("Show in Finder") { AppActions.reveal(URL(fileURLWithPath: path)) }
        menu.addItem(.separator())
        menu.add("Remove from Dock", enabled: !controller.settings.lockLayout) {
            controller.store.update { $0.removing(id) }
        }
    }

    private static func buildTrashMenu(_ menu: NSMenu) {
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)[0]
        menu.add("Open") { NSWorkspace.shared.open(trash) }
        menu.add("Empty Trash…") {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Are you sure you want to permanently erase the items in the Trash?"
            alert.informativeText = "You can’t undo this action."
            alert.addButton(withTitle: "Empty Trash")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        }
    }

    private static func buildWidgetMenu(_ menu: NSMenu, kind: WidgetKind, id: UUID, controller: DockController) {
        menu.addHeader(kind.title)
        if kind == .weather {
            menu.add("Refresh Weather") { WeatherService.shared.refresh() }
        }
        menu.add("Widget Settings…") { SettingsWindowController.shared.show(pane: .widgets) }
        menu.addItem(.separator())
        menu.add("Remove Widget", enabled: !controller.settings.lockLayout) {
            controller.store.update { $0.removing(id) }
        }
    }

    // MARK: Dock background

    static func dockMenu(controller: DockController) -> NSMenu {
        let store = controller.store
        let menu = NSMenu()
        menu.autoenablesItems = false
        let locked = store.settings.lockLayout
        let present = Set(store.layout.allItems.compactMap { item -> WidgetKind? in
            if case .widget(let k) = item.content { return k }
            return nil
        })

        menu.addSubmenu("Add Widget") { sub in
            for kind in WidgetKind.allCases {
                sub.add(kind.title, state: present.contains(kind), enabled: !locked && !present.contains(kind)) {
                    store.update { $0.inserting(DockItem(.widget(kind)), in: .main, at: $0.main.count) }
                }
            }
        }
        menu.add("Add Separator", enabled: !locked) {
            store.update { $0.inserting(DockItem(.separator), in: .main, at: $0.main.count) }
        }
        menu.addItem(.separator())
        menu.add("Magnification", state: store.settings.magnification) { store.settings.magnification.toggle() }
        menu.add("Automatically Hide", state: store.settings.autoHide) { store.settings.autoHide.toggle() }
        menu.add("Lock Layout", state: locked) { store.settings.lockLayout.toggle() }
        menu.addSubmenu("Position on Screen") { sub in
            for position in DockPosition.allCases {
                sub.add(position.title, state: store.settings.position == position) { store.settings.position = position }
            }
        }
        menu.addSubmenu("Theme") { sub in
            for theme in store.allThemes {
                sub.add(theme.name, state: store.theme.id == theme.id) { store.apply(theme) }
            }
        }
        menu.addItem(.separator())
        menu.add("Dock Settings…") { SettingsWindowController.shared.show(pane: .general) }
        return menu
    }

    // MARK: Helpers

    static func prompt(title: String, value: String) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
