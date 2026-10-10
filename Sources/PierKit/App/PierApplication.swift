import AppKit
import Combine

public enum PierApplication {
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let appDelegate = AppDelegate()
        delegate = appDelegate
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var dockWindow: DockWindow?
    private var statusItem: StatusItemController?
    private var bag = Set<AnyCancellable>()
    private var signalSources: [DispatchSourceSignal] = []
    private var isDuplicate = false
    private let store = PierStore.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfAlreadyRunning() { return }
        installSignalHandlers()

        let controller = DockController.shared
        let window = DockWindow(controller: controller)
        controller.window = window
        controller.start()
        window.reposition()
        window.orderFrontRegardless()
        dockWindow = window

        statusItem = StatusItemController(dockWindow: window)
        if AXIsProcessTrusted() { BadgeService.shared.start() }

        store.$settings
            .map(\.hideSystemDock)
            .removeDuplicates()
            .sink { hide in
                if hide { SystemDockManager.hide() } else { SystemDockManager.restore() }
            }
            .store(in: &bag)

        if !store.settings.didOnboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { OnboardingWindowController.shared.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A duplicate launch must not touch the running copy's state or the macOS Dock.
        guard !isDuplicate else { return }
        store.flush()
        if store.settings.hideSystemDock && store.settings.restoreSystemDockOnQuit {
            SystemDockManager.restore()
        }
    }

    /// Double-clicking a .piertheme file imports and applies it.
    func application(_ application: NSApplication, open urls: [URL]) {
        // pier://bounce?app=… from scripts and agents (see `pier help`).
        for url in urls where url.scheme?.lowercased() == "pier" {
            AttentionService.shared.handle(url)
        }
        var imported = 0
        for url in urls where url.isFileURL && ["piertheme", "json"].contains(url.pathExtension.lowercased()) {
            if (try? store.importTheme(from: url)) != nil { imported += 1 }
        }
        if imported > 0 { SettingsWindowController.shared.show(pane: .themes) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(pane: .general)
        return true
    }

    /// Opening Pier a second time brings up Settings in the running copy instead of a second dock.
    private func terminateIfAlreadyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != getpid() }
        guard let other = others.first else { return false }
        isDuplicate = true
        other.activate()
        NSApp.terminate(nil)
        return true
    }

    /// `kill`, Ctrl-C and logout send signals that skip `applicationWillTerminate`; route them through it
    /// so the macOS Dock is never left hidden.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var dockWindow: DockWindow?
    private let store = PierStore.shared

    init(dockWindow: DockWindow) {
        self.dockWindow = dockWindow
        super.init()
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Pier")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.addHeader("Pier")
        let visible = dockWindow?.isVisible ?? false
        menu.add(visible ? "Hide Pier Dock" : "Show Pier Dock") { [weak self] in
            guard let window = self?.dockWindow else { return }
            if window.isVisible { window.orderOut(nil) } else { window.orderFrontRegardless() }
        }
        menu.add("Hide macOS Dock", state: store.settings.hideSystemDock) { [store] in
            store.settings.hideSystemDock.toggle()
        }
        menu.add("Lock Layout", state: store.settings.lockLayout) { [store] in store.settings.lockLayout.toggle() }
        menu.addItem(.separator())
        menu.add("Settings…") { SettingsWindowController.shared.show(pane: .general) }
        menu.add("Permissions…") { SettingsWindowController.shared.show(pane: .permissions) }
        menu.add("About Pier") { SettingsWindowController.shared.show(pane: .about) }
        menu.addItem(.separator())
        menu.add("Quit Pier") { NSApp.terminate(nil) }
    }
}
