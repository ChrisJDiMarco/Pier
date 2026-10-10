import AppKit
import SwiftUI

struct ItemsPane: View {
    @EnvironmentObject var store: PierStore
    @EnvironmentObject var icons: IconService

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Main") {
                    ForEach(store.layout.main) { item in row(item) }
                        .onMove { from, to in move(.main, from, to) }
                        .onDelete { offsets in delete(.main, offsets) }
                }
                Section("After the divider") {
                    ForEach(store.layout.trailing) { item in row(item) }
                        .onMove { from, to in move(.trailing, from, to) }
                        .onDelete { offsets in delete(.trailing, offsets) }
                }
            }
            Divider()
            HStack {
                Button { addApps() } label: { Label("Add Apps…", systemImage: "plus.app") }
                Button { addStack() } label: { Label("Add Folder Stack…", systemImage: "folder.badge.plus") }
                Menu {
                    ForEach(WidgetKind.allCases) { kind in
                        Button(kind.title) {
                            store.update { $0.inserting(DockItem(.widget(kind)), in: .main, at: $0.main.count) }
                        }
                    }
                } label: { Label("Add Widget", systemImage: "rectangle.3.group") }
                .fixedSize()
                Button { store.update { $0.inserting(DockItem(.separator), in: .main, at: $0.main.count) } } label: {
                    Label("Add Separator", systemImage: "poweron")
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .disabled(store.settings.lockLayout)
    }

    @ViewBuilder private func row(_ item: DockItem) -> some View {
        let _ = icons.revision
        HStack(spacing: 10) {
            rowIcon(item).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(rowTitle(item))
                if let folder = item.folder {
                    Text(folder.apps.map(\.name).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if item.content != .trash {
                Button {
                    store.update { $0.removing(item.id) }
                } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Remove from dock")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func rowIcon(_ item: DockItem) -> some View {
        switch item.content {
        case .app(let ref): Image(nsImage: icons.icon(for: ref)).resizable()
        case .folder: Image(systemName: "square.grid.2x2.fill").font(.system(size: 17)).foregroundStyle(.blue)
        case .stack(let path): Image(nsImage: icons.icon(forPath: path)).resizable()
        case .trash: Image(nsImage: icons.trashIcon(full: false)).resizable()
        case .widget(let kind): Image(systemName: kind.symbol).font(.system(size: 16)).foregroundStyle(.orange)
        case .separator: Image(systemName: "line.diagonal").foregroundStyle(.secondary)
        }
    }

    private func rowTitle(_ item: DockItem) -> String {
        switch item.content {
        case .widget(let kind): return "\(kind.title) widget"
        case .separator: return "Separator"
        case .folder(let folder): return "\(folder.name) (folder)"
        default: return item.displayName
        }
    }

    private func move(_ section: DockLayout.Section, _ from: IndexSet, _ to: Int) {
        store.update { layout in
            var copy = layout
            if section == .main { copy.main.move(fromOffsets: from, toOffset: to) }
            else { copy.trailing.move(fromOffsets: from, toOffset: to) }
            return copy
        }
    }

    private func delete(_ section: DockLayout.Section, _ offsets: IndexSet) {
        let ids = offsets.map { store.layout.items(in: section)[$0].id }
        store.update { layout in ids.reduce(layout) { $0.removing($1) } }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for ref in panel.urls.compactMap(AppRef.init(url:)) { store.update { $0.pinning(ref) } }
    }

    private func addStack() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.update { $0.inserting(DockItem(.stack(path: AppRef.normalize(url.path))), in: .trailing, at: 0) }
    }
}

// MARK: - Widgets

struct WidgetsPane: View {
    @EnvironmentObject var store: PierStore
    @State private var cityDraft = ""

    var body: some View {
        Form {
            Section("In the dock") {
                ForEach(WidgetKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { isPresent(kind) },
                        set: { on in
                            if on {
                                store.update { $0.inserting(DockItem(.widget(kind)), in: .main, at: $0.main.count) }
                            } else if let item = item(for: kind) {
                                store.update { $0.removing(item.id) }
                            }
                        }
                    )) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            }

            Section("Clock") {
                Toggle("24-hour time", isOn: $store.settings.clock24Hour)
                Toggle("Show seconds", isOn: $store.settings.clockShowSeconds)
            }

            Section {
                Toggle("Use this Mac’s location", isOn: $store.settings.weatherUseLocation)
                    .onChange(of: store.settings.weatherUseLocation) { _, _ in WeatherService.shared.refresh() }
                if !store.settings.weatherUseLocation {
                    HStack {
                        TextField("City", text: $cityDraft, prompt: Text("e.g. Chicago"))
                            .onSubmit(applyCity)
                        Button("Set", action: applyCity)
                    }
                }
                Picker("Units", selection: $store.settings.temperatureUnit) {
                    Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
                    Text("Celsius").tag(TemperatureUnit.celsius)
                }
                .pickerStyle(.segmented)
                .onChange(of: store.settings.temperatureUnit) { _, _ in WeatherService.shared.refresh() }
            } header: {
                Text("Weather")
            } footer: {
                Text("Forecasts come from Open-Meteo. No account or API key needed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Text("Now Playing reads Music and Spotify. The first time, macOS asks whether Pier may control them.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Now Playing")
            }
        }
        .formStyle(.grouped)
        .onAppear { cityDraft = store.settings.weatherCity }
    }

    private func applyCity() {
        store.settings.weatherCity = cityDraft.trimmingCharacters(in: .whitespaces)
        WeatherService.shared.refresh()
    }

    private func item(for kind: WidgetKind) -> DockItem? {
        store.layout.allItems.first { $0.content == .widget(kind) }
    }

    private func isPresent(_ kind: WidgetKind) -> Bool { item(for: kind) != nil }
}

// MARK: - Click actions

struct ClickActionsPane: View {
    @EnvironmentObject var store: PierStore

    var body: some View {
        Form {
            Section {
                ForEach(ClickTrigger.allCases) { trigger in
                    Picker(trigger.title, selection: Binding(
                        get: { store.settings.action(for: trigger) },
                        set: { store.settings.clickBindings[trigger] = $0 }
                    )) {
                        ForEach(ClickAction.allCases) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("When you interact with an app in the dock")
            } footer: {
                Text("New Window, Cycle Windows and Minimize need Accessibility access. Right-click always shows the menu.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Defaults") { store.settings.clickBindings = PierSettings.defaultBindings }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions & About

struct PermissionsPane: View {
    @EnvironmentObject var permissions: Permissions

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "Accessibility", symbol: "accessibility",
                              detail: "Notification badges, window lists, focusing windows, and keyboard click actions.",
                              granted: permissions.accessibility) { permissions.requestAccessibility() }
                PermissionRow(title: "Screen Recording", symbol: "rectangle.dashed.badge.record",
                              detail: "Live thumbnails in window previews. Pier never records or saves your screen.",
                              granted: permissions.screenRecording) { permissions.requestScreenRecording() }
            } footer: {
                Text("Everything works without these, just with fewer features. Pier only goes online for weather and Spotify album art.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let title: String
    let symbol: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20)).frame(width: 28).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button("Grant Access…", action: request)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
            Text("Pier").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("A dock for macOS you actually control: folders, widgets, badges, window previews, custom icons and shareable themes.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text("Open source under the MIT License.").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
