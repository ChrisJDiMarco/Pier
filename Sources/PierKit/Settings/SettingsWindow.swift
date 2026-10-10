import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, themes, items, widgets, clicks, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .themes: return "Themes"
        case .items: return "Dock Items"
        case .widgets: return "Widgets"
        case .clicks: return "Click Actions"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .themes: return "swatchpalette"
        case .items: return "square.grid.3x1.below.line.grid.1x2"
        case .widgets: return "rectangle.3.group"
        case .clicks: return "cursorarrow.click.2"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsSelection: ObservableObject {
    @Published var pane: SettingsPane = .general
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private let selection = SettingsSelection()

    func show(pane: SettingsPane) {
        PopupController.shared.dismiss()
        selection.pane = pane
        if window == nil {
            let root = SettingsRootView()
                .environmentObject(selection)
                .environmentObject(PierStore.shared)
                .environmentObject(Permissions.shared)
                .environmentObject(IconService.shared)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Pier Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(CGSize(width: 780, height: 560))
            window.minSize = CGSize(width: 680, height: 460)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        if window?.isVisible != true { Permissions.shared.beginWatching() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Permissions.shared.endWatching()
    }
}

struct SettingsRootView: View {
    @EnvironmentObject var selection: SettingsSelection

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(
                get: { selection.pane },
                set: { if let p = $0 { selection.pane = p } }
            )) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            Group {
                switch selection.pane {
                case .general: GeneralPane()
                case .appearance: AppearancePane()
                case .themes: ThemesPane()
                case .items: ItemsPane()
                case .widgets: WidgetsPane()
                case .clicks: ClickActionsPane()
                case .permissions: PermissionsPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle(selection.pane.title)
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @EnvironmentObject var store: PierStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Placement") {
                Picker("Position on screen", selection: $store.settings.position) {
                    ForEach(DockPosition.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Show on", selection: $store.settings.screenMode) {
                    ForEach(ScreenMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Automatically hide and show the dock", isOn: $store.settings.autoHide)
                if store.settings.autoHide {
                    LabeledSlider(title: "Hide delay", value: $store.settings.autoHideDelay, range: 0...2,
                                  format: { String(format: "%.2fs", $0) })
                }
            }

            Section("Motion") {
                Toggle("Magnification", isOn: $store.settings.magnification)
                if store.settings.magnification {
                    LabeledSlider(title: "Magnification amount", value: $store.settings.magnificationScale,
                                  range: 1.1...2.4, format: { String(format: "%.0f%%", ($0 - 1) * 100) })
                }
                Toggle("Bounce apps while they open", isOn: $store.settings.launchBounce)
                Toggle("Animate changes", isOn: $store.settings.animationsEnabled)
            }

            Section("Content") {
                Toggle("Show running apps that aren’t kept in the dock", isOn: $store.settings.showRunningApps)
                Toggle("Show app names on hover", isOn: $store.settings.showLabels)
                Toggle("Show notification badges", isOn: $store.settings.showBadges)
                Picker("Window previews", selection: $store.settings.windowPreviews) {
                    ForEach(PreviewTrigger.allCases) { Text($0.title).tag($0) }
                }
                if store.settings.windowPreviews == .hover {
                    LabeledSlider(title: "Preview delay", value: $store.settings.previewDelay, range: 0.1...1.5,
                                  format: { String(format: "%.2fs", $0) })
                }
                Stepper("Folder grid columns: \(store.settings.folderColumns)",
                        value: $store.settings.folderColumns, in: 2...8)
                Toggle("Lock layout (prevent dragging and removing)", isOn: $store.settings.lockLayout)
            }

            Section {
                Toggle("Hide the macOS Dock while Pier is running", isOn: $store.settings.hideSystemDock)
                Toggle("Bring the macOS Dock back when Pier quits", isOn: $store.settings.restoreSystemDockOnQuit)
                    .disabled(!store.settings.hideSystemDock)
                Toggle("Open Pier at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in LaunchAtLogin.set(value) }
            } header: {
                Text("System")
            } footer: {
                Text("Pier hides the macOS Dock by turning on its auto-hide with a very long delay. Turning this off restores your original setting.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Button("Reset Dock to Match the macOS Dock…") {
                    let alert = NSAlert()
                    alert.messageText = "Replace Pier’s layout with your macOS Dock’s apps?"
                    alert.informativeText = "Folders and widgets will be removed."
                    alert.addButton(withTitle: "Reset")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn { store.resetLayoutToSystemDock() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f", $0) }

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range)
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }
}

/// Bridges a hex string in the theme to SwiftUI's ColorPicker.
extension Binding where Value == String {
    var color: Binding<Color> {
        Binding<Color>(
            get: { Color(nsColor: NSColor(hex: wrappedValue) ?? .white) },
            set: { wrappedValue = NSColor($0).hexString }
        )
    }
}
