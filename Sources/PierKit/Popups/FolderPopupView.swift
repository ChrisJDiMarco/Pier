import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FolderPopupView: View {
    let folderID: UUID
    /// Launchpad presentation: bigger icons and more columns.
    var large = false
    @EnvironmentObject var store: PierStore
    @EnvironmentObject var running: RunningAppsService
    @EnvironmentObject var icons: IconService
    @EnvironmentObject var badges: BadgeService
    @State private var name = ""
    @State private var editingName = false
    @State private var query = ""
    @State private var selection: Int?
    @State private var dragging: AppRef?
    @FocusState private var nameFocused: Bool
    @FocusState private var gridFocused: Bool

    private var cellSize: CGFloat { large ? 124 : 86 }
    private var iconSize: CGFloat { large ? 92 : 60 }

    var body: some View {
        let _ = icons.revision
        if let folder {
            let apps = FolderNavigator.filter(folder.apps, query: query)
            let columns = min(max(1, store.settings.folderColumns + (large ? 2 : 0)), max(1, folder.apps.count))
            VStack(spacing: large ? 22 : 14) {
                header(folder, width: max(160, CGFloat(columns) * cellSize - 20))

                if apps.isEmpty {
                    Text("No apps match “\(query)”")
                        .font(.system(size: 13))
                        .foregroundStyle(store.theme.secondaryText)
                        .frame(width: CGFloat(columns) * cellSize, height: cellSize)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellSize), spacing: 6), count: columns),
                              spacing: large ? 18 : 10) {
                        ForEach(Array(apps.enumerated()), id: \.element.key) { index, app in
                            cell(app, folder: folder)
                                .background(selectionHighlight(index == selection))
                                .onHover { if $0 { selection = index } }
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: query)
                }

                Text("Arrow keys to move · Return to open · type to search")
                    .font(.system(size: 10.5))
                    .foregroundStyle(store.theme.secondaryText.opacity(0.8))
            }
            .focusable()
            .focused($gridFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in handleKey(press, apps: apps, columns: columns) }
            .onAppear {
                name = folder.name
                DispatchQueue.main.async { gridFocused = true }
            }
            // Commit a rename that was still being typed when the popup closed.
            .onDisappear(perform: commitName)
            // A drag released anywhere in the popup ends the reorder.
            .onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return true }
        } else {
            Color.clear.frame(width: 1, height: 1).onAppear { PopupController.shared.dismiss() }
        }
    }

    private var folder: AppFolder? {
        store.layout.allItems.first { $0.id == folderID }?.folder
    }

    @ViewBuilder private func header(_ folder: AppFolder, width: CGFloat) -> some View {
        let font = Font.system(size: large ? 26 : 17, weight: .semibold)
        if editingName {
            TextField("Folder Name", text: $name)
                .textFieldStyle(.plain)
                .font(font)
                .multilineTextAlignment(.center)
                .foregroundStyle(store.theme.text)
                .focused($nameFocused)
                .onSubmit(finishEditing)
                .onChange(of: nameFocused) { _, focused in if !focused { finishEditing() } }
                .frame(width: width)
        } else if !query.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text(query)
            }
            .font(font)
            .foregroundStyle(store.theme.text)
            .frame(width: width)
        } else {
            Text(folder.name)
                .font(font)
                .foregroundStyle(store.theme.text)
                .lineLimit(1)
                .frame(width: width)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard !store.settings.lockLayout else { return }
                    name = folder.name
                    editingName = true
                    DispatchQueue.main.async { nameFocused = true }
                }
                .help("Double-click to rename")
        }
    }

    private func selectionHighlight(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.accentColor.opacity(selected ? 0.2 : 0))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(selected ? 0.55 : 0), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: selected)
    }

    private func handleKey(_ press: KeyPress, apps: [AppRef], columns: Int) -> KeyPress.Result {
        guard !editingName else { return .ignored }
        switch press.key {
        case .leftArrow: selection = FolderNavigator.move(selection, by: -1, count: apps.count)
        case .rightArrow: selection = FolderNavigator.move(selection, by: 1, count: apps.count)
        case .upArrow: selection = FolderNavigator.move(selection, by: -columns, count: apps.count)
        case .downArrow: selection = FolderNavigator.move(selection, by: columns, count: apps.count)
        case .return:
            guard let index = selection ?? (apps.isEmpty ? nil : 0), apps.indices.contains(index) else { break }
            PopupController.shared.dismiss()
            AppActions.open(apps[index])
        case .delete:
            guard !query.isEmpty else { return .handled }
            query.removeLast()
            selection = query.isEmpty ? nil : 0
        default:
            guard let c = press.characters.first, press.characters.count == 1,
                  c.isLetter || c.isNumber || (c == " " && !query.isEmpty),
                  !press.modifiers.contains(.command)
            else { return .ignored }
            query.append(c)
            selection = 0
        }
        return .handled
    }

    private func finishEditing() {
        guard editingName else { return }
        commitName()
        editingName = false
        gridFocused = true
    }

    private func cell(_ app: AppRef, folder: AppFolder) -> some View {
        let isRunning = running.running(app) != nil
        return VStack(spacing: 5) {
            Image(nsImage: icons.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .overlay(alignment: .topTrailing) {
                    if store.settings.showBadges, let badge = badges.badge(for: app) {
                        BadgeView(text: badge, size: iconSize, color: store.theme.color(store.theme.badgeColor))
                    }
                }
            Text(app.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(store.theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Circle().fill(store.theme.color(store.theme.indicatorColor)).frame(width: 4, height: 4)
                .opacity(isRunning ? 1 : 0)
        }
        .frame(width: cellSize)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(dragging?.matches(app) == true ? 0.35 : 1)
        .onTapGesture {
            PopupController.shared.dismiss()
            AppActions.open(app)
        }
        .onDrag {
            dragging = app
            return NSItemProvider(object: app.path as NSString)
        }
        .onDrop(of: [.text], delegate: ReorderDelegate(target: app, folderID: folderID, dragging: $dragging, store: store))
        .contextMenu {
            Button("Open") { PopupController.shared.dismiss(); AppActions.open(app) }
            if isRunning {
                Button("Quit") { AppActions.quit(app) }
            }
            Divider()
            Button("Move to Dock") {
                store.update { $0.removingApp(app, fromFolder: folderID, placeOutside: true) }
            }
            .disabled(store.settings.lockLayout)
            Button("Remove from Folder") {
                store.update { $0.removingApp(app, fromFolder: folderID, placeOutside: false) }
            }
            .disabled(store.settings.lockLayout)
            Divider()
            Button("Choose Custom Icon…") { IconService.shared.chooseCustomIcon(for: app) }
            Button("Show in Finder") { AppActions.reveal(app.url) }
        }
        .help(app.name)
    }

    private func commitName() {
        guard let folder, name != folder.name else { return }
        store.update { $0.renamingFolder(folderID, to: name) }
    }
}

/// Live reordering inside a folder: the dragged app slides into the hovered app's slot.
private struct ReorderDelegate: DropDelegate {
    let target: AppRef
    let folderID: UUID
    @Binding var dragging: AppRef?
    let store: PierStore

    func dropEntered(info: DropInfo) {
        guard let dragging, !dragging.matches(target), !store.settings.lockLayout,
              let folder = store.layout.allItems.first(where: { $0.id == folderID })?.folder,
              let from = folder.apps.firstIndex(where: { $0.matches(dragging) }),
              let to = folder.apps.firstIndex(where: { $0.matches(target) })
        else { return }
        var apps = folder.apps
        apps.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            store.update { $0.reorderingFolder(folderID, apps: apps) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
