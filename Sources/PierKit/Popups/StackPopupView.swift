import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Grid of the most recent items in a folder (Downloads, Documents…). Items can be opened or dragged out.
struct StackPopupView: View {
    let path: String
    @EnvironmentObject var store: PierStore
    @State private var files: [URL] = []
    @State private var loaded = false

    private let limit = 30
    private let columns = 5
    private let cell: CGFloat = 84

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(FileManager.default.displayName(atPath: path))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(store.theme.text)
                Spacer()
                Button("Open in Finder") {
                    PopupController.shared.dismiss()
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
            }
            if files.isEmpty {
                Text(loaded ? "This folder is empty" : "Loading…")
                    .font(.system(size: 13))
                    .foregroundStyle(store.theme.secondaryText)
                    .frame(width: CGFloat(columns) * cell, height: 90)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 4), count: columns), spacing: 8) {
                        ForEach(files, id: \.self) { url in
                            FileCell(url: url, theme: store.theme)
                        }
                    }
                }
                .frame(width: CGFloat(columns) * (cell + 4), height: min(CGFloat((files.count + columns - 1) / columns) * 104, 420))
            }
        }
        .frame(width: CGFloat(columns) * (cell + 4))
        .task { await load() }
    }

    private func load() async {
        let dir = URL(fileURLWithPath: path)
        let max = limit
        // Directory listing and per-file stat run off the main thread; each date is read once.
        files = await Task.detached(priority: .userInitiated) { () -> [URL] in
            let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .contentModificationDateKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys),
                                                                     options: [.skipsHiddenFiles])) ?? []
            let dated = urls.map { url -> (URL, Date) in
                let values = try? url.resourceValues(forKeys: keys)
                return (url, values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast)
            }
            return Array(dated.sorted { $0.1 > $1.1 }.prefix(max).map(\.0))
        }.value
        loaded = true
    }
}

private struct FileCell: View {
    let url: URL
    let theme: Theme
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
            Text(url.lastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(height: 28, alignment: .top)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture {
            PopupController.shared.dismiss()
            NSWorkspace.shared.open(url)
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { AppActions.reveal(url) }
        }
        .help(url.lastPathComponent)
        .task {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 56, height: 56),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                       representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = rep.nsImage
            }
        }
    }
}
