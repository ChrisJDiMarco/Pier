import AppKit
import SwiftUI

struct AppTileView: View {
    let ref: AppRef
    let size: CGFloat
    @EnvironmentObject var icons: IconService
    @EnvironmentObject var badges: BadgeService
    @EnvironmentObject var running: RunningAppsService
    @EnvironmentObject var store: PierStore

    var body: some View {
        let _ = icons.revision
        let bouncing = store.settings.launchBounce && running.launching.contains(ref.key)
        BounceContainer(active: bouncing, amplitude: size * 0.38, position: store.settings.position) {
            Image(nsImage: icons.icon(for: ref))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
        .overlay(alignment: .topTrailing) {
            if store.settings.showBadges, let badge = badges.badge(for: ref) {
                BadgeView(text: badge, size: size, color: store.theme.color(store.theme.badgeColor))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(ref.name)
    }
}

/// Bounces its content away from the screen edge while `active`, like a launching app.
struct BounceContainer<Content: View>: View {
    let active: Bool
    let amplitude: CGFloat
    let position: DockPosition
    @ViewBuilder let content: () -> Content

    var body: some View {
        if active {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let h = abs(sin(t * .pi * 1.6)) * amplitude
                content().offset(offset(h))
            }
        } else {
            content()
        }
    }

    private func offset(_ h: CGFloat) -> CGSize {
        switch position {
        case .bottom: return CGSize(width: 0, height: -h)
        case .left: return CGSize(width: h, height: 0)
        case .right: return CGSize(width: -h, height: 0)
        }
    }
}

struct BadgeView: View {
    let text: String
    let size: CGFloat
    let color: Color

    var body: some View {
        let height = max(15, size * 0.4)
        let ring = max(1.5, height * 0.09)
        Text(text == "•" || text.isEmpty ? " " : text)
            .font(.system(size: height * 0.56, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, height * 0.24)
            .frame(minWidth: height, minHeight: height)
            .background(Capsule().fill(color))
            .overlay(Capsule().strokeBorder(.white, lineWidth: ring))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .offset(x: height * 0.3, y: -height * 0.3)
            .fixedSize()
            .transition(.scale.combined(with: .opacity))
    }
}

struct FolderTileView: View {
    let folder: AppFolder
    let size: CGFloat
    @EnvironmentObject var icons: IconService
    @EnvironmentObject var badges: BadgeService
    @EnvironmentObject var store: PierStore

    var body: some View {
        let _ = icons.revision
        let theme = store.theme
        // The folder well is drawn slightly larger than an app icon, matching widget wells.
        let well = size * 1.13
        let inset = well * 0.13
        let gap = well * 0.07
        let cell = (well - inset * 2 - gap) / 2
        ZStack {
            WellBackground(theme: theme, radius: well * 0.26)
            LazyVGrid(columns: [GridItem(.fixed(cell), spacing: gap), GridItem(.fixed(cell))], spacing: gap) {
                ForEach(Array(folder.apps.prefix(4).enumerated()), id: \.offset) { _, app in
                    Image(nsImage: icons.icon(for: app))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: cell, height: cell)
                }
            }
            .padding(inset)
        }
        .frame(width: well, height: well)
        .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if store.settings.showBadges, let total = combinedBadge {
                    BadgeView(text: total, size: size, color: theme.color(theme.badgeColor))
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(folder.name) folder")
    }

    private var combinedBadge: String? {
        let values = folder.apps.compactMap { badges.badge(for: $0) }
        guard !values.isEmpty else { return nil }
        let numbers = values.compactMap { Int($0) }
        return numbers.count == values.count ? String(numbers.reduce(0, +)) : "•"
    }
}

struct StackTileView: View {
    let path: String
    let size: CGFloat
    @EnvironmentObject var icons: IconService

    var body: some View {
        Image(nsImage: icons.icon(forPath: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel(FileManager.default.displayName(atPath: path))
    }
}

struct TrashTileView: View {
    let size: CGFloat
    @EnvironmentObject var icons: IconService
    @State private var isFull = false

    var body: some View {
        Image(nsImage: icons.trashIcon(full: isFull))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("Trash")
            .task {
                while !Task.isCancelled {
                    isFull = await Task.detached(priority: .background) { Self.trashHasItems() }.value
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }

    /// Reading ~/.Trash needs Full Disk Access on recent macOS; without it we simply show the empty can.
    nonisolated static func trashHasItems() -> Bool {
        let url = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)[0]
        // Stop at the first real item instead of listing a possibly huge Trash.
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                   options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
        return items?.nextObject() != nil
    }
}
