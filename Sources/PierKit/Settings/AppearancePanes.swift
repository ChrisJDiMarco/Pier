import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppearancePane: View {
    @EnvironmentObject var store: PierStore

    var body: some View {
        Form {
            Section {
                ThemePreview(theme: store.theme).frame(height: 96)
            }

            Section("Background") {
                Picker("Style", selection: $store.theme.background) {
                    ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
                }
                ColorPicker("Tint", selection: $store.theme.tint.color, supportsOpacity: false)
                LabeledSlider(title: "Tint strength", value: $store.theme.tintOpacity, range: 0...1, format: percent)
                LabeledSlider(title: "Roundness", value: $store.theme.cornerRadius, range: 0...0.5,
                              format: { String(format: "%.0f%%", $0 * 200) })
                ColorPicker("Border", selection: $store.theme.borderColor.color, supportsOpacity: false)
                LabeledSlider(title: "Border opacity", value: $store.theme.borderOpacity, range: 0...1, format: percent)
                LabeledSlider(title: "Border width", value: $store.theme.borderWidth, range: 0...4,
                              format: { String(format: "%.1fpt", $0) })
                LabeledSlider(title: "Shadow", value: $store.theme.shadowOpacity, range: 0...1, format: percent)
                LabeledSlider(title: "Shadow softness", value: $store.theme.shadowRadius, range: 0...50)
            }

            Section("Size") {
                LabeledSlider(title: "Icon size", value: $store.theme.iconSize, range: 28...112,
                              format: { "\(Int($0))pt" })
                LabeledSlider(title: "Icon spacing", value: $store.theme.iconSpacing, range: 0...30,
                              format: { "\(Int($0))pt" })
                LabeledSlider(title: "Padding", value: $store.theme.padding, range: 2...24,
                              format: { "\(Int($0))pt" })
                LabeledSlider(title: "Distance from edge", value: $store.theme.edgeMargin, range: 0...60,
                              format: { "\(Int($0))pt" })
            }

            Section("Details") {
                Picker("Running indicator", selection: $store.theme.indicator) {
                    ForEach(IndicatorStyle.allCases) { Text($0.title).tag($0) }
                }
                ColorPicker("Indicator color", selection: $store.theme.indicatorColor.color, supportsOpacity: false)
                Toggle("Text follows light/dark mode", isOn: Binding(
                    get: { store.theme.textColor.lowercased() == "auto" },
                    set: { store.theme.textColor = $0 ? "auto" : "#1D1D1F" }
                ))
                if store.theme.textColor.lowercased() != "auto" {
                    ColorPicker("Text color", selection: $store.theme.textColor.color, supportsOpacity: false)
                }
                ColorPicker("Widget & folder fill", selection: $store.theme.widgetFill.color, supportsOpacity: false)
                LabeledSlider(title: "Widget fill strength", value: $store.theme.widgetFillOpacity, range: 0...1,
                              format: percent)
                ColorPicker("Badge color", selection: $store.theme.badgeColor.color, supportsOpacity: false)
            }

            Section {
                HStack {
                    Button("Save as Theme…") { saveTheme() }
                    Button("Export…") { exportTheme(store.theme) }
                    Spacer()
                    Button("Reset to Liquid") { store.apply(.liquid) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var percent: (Double) -> String { { String(format: "%.0f%%", $0 * 100) } }

    private func saveTheme() {
        guard let name = DockMenus.prompt(title: "Name your theme", value: store.theme.name + " Copy") else { return }
        do { try store.saveCurrentTheme(named: name) } catch { NSAlert(error: error).runModal() }
    }

    func exportTheme(_ theme: Theme) {
        ThemeFiles.export(theme, store: store)
    }
}

@MainActor
enum ThemeFiles {
    static func export(_ theme: Theme, store: PierStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pierTheme]
        panel.nameFieldStringValue = "\(theme.name).piertheme"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export(theme, to: url) } catch { NSAlert(error: error).runModal() }
    }

    static func importTheme(store: PierStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pierTheme, .json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { _ = try store.importTheme(from: url) } catch {
                let alert = NSAlert()
                alert.messageText = "“\(url.lastPathComponent)” isn’t a Pier theme."
                alert.runModal()
            }
        }
    }
}

struct ThemesPane: View {
    @EnvironmentObject var store: PierStore
    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Built-in").font(.headline)
                grid(Theme.builtIns, deletable: false)
                if !store.userThemes.isEmpty {
                    Text("Your Themes").font(.headline)
                    grid(store.userThemes, deletable: true)
                }
                HStack {
                    Button("Import Theme…") { ThemeFiles.importTheme(store: store) }
                    Button("Open Themes Folder") { NSWorkspace.shared.open(PierPaths.themes) }
                    Spacer()
                }
                Text("Themes are small .piertheme files. Share them with anyone — double-click or import one to try it, or drop files into the Themes folder.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .onAppear { store.reloadUserThemes() }
    }

    private func grid(_ themes: [Theme], deletable: Bool) -> some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(themes) { theme in
                VStack(alignment: .leading, spacing: 6) {
                    ThemePreview(theme: theme)
                        .frame(height: 78)
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, lineWidth: store.theme.id == theme.id ? 3 : 0))
                    HStack {
                        Text(theme.name).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(theme.author).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { store.apply(theme) }
                .contextMenu {
                    Button("Apply") { store.apply(theme) }
                    Button("Export…") { ThemeFiles.export(theme, store: store) }
                    if deletable {
                        Divider()
                        Button("Delete Theme", role: .destructive) { store.deleteUserTheme(theme) }
                    }
                }
            }
        }
    }
}

/// A miniature dock rendered with a theme, over a wallpaper-like gradient.
struct ThemePreview: View {
    let theme: Theme
    private let apps = ["/System/Library/CoreServices/Finder.app", "/Applications/Safari.app",
                        "/System/Applications/Mail.app", "/System/Applications/Messages.app",
                        "/System/Applications/Music.app"]

    var body: some View {
        GeometryReader { proxy in
            let icon = min(30, proxy.size.height * 0.36)
            let pad = icon * CGFloat(theme.padding / max(theme.iconSize, 1))
            let spacing = icon * CGFloat(theme.iconSpacing / max(theme.iconSize, 1))
            let thickness = icon + pad * 2
            ZStack {
                LinearGradient(colors: [Color(hex: "#7FA7C9"), Color(hex: "#C98B5E"), Color(hex: "#8E4B2E")],
                               startPoint: .top, endPoint: .bottom)
                HStack(spacing: spacing) {
                    ForEach(apps, id: \.self) { path in
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: icon, height: icon)
                    }
                    RoundedRectangle(cornerRadius: icon * 0.26)
                        .fill(theme.color(theme.widgetFill, theme.widgetFillOpacity))
                        .frame(width: icon * 1.55, height: icon)
                        .overlay(Text("9:41").font(.system(size: icon * 0.34, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.text))
                }
                .padding(pad)
                .background(DockBackground(theme: theme, radius: thickness * CGFloat(theme.cornerRadius)))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
