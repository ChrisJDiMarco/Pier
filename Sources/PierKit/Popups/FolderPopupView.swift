import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FolderPopupView: View {
    let folderID: UUID
    @EnvironmentObject var store: PierStore
    @EnvironmentObject var running: RunningAppsService
    @EnvironmentObject var icons: IconService
    @EnvironmentObject var badges: BadgeService
    @State private var name = ""
    @State private var dragging: AppRef?
    @FocusState private var nameFocused: Bool

    private let cellSize: CGFloat = 86
    private let iconSize: CGFloat = 60

    var body: some View {
        let _ = icons.revision
        if let folder {
            let columns = min(max(1, store.settings.folderColumns), max(1, folder.apps.count))
            VStack(spacing: 14) {
                TextField("Folder Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(store.theme.text)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                    .frame(width: max(160, CGFloat(columns) * cellSize - 20))
                    .disabled(store.settings.lockLayout)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellSize), spacing: 6), count: columns), spacing: 10) {
                    ForEach(folder.apps, id: \.key) { app in
                        cell(app, folder: folder)
                    }
                }
            }
            .onAppear { name = folder.name }
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
