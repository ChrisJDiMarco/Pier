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
        let height = max(15, size * 0.34)
        Text(text == "•" || text.isEmpty ? " " : text)
            .font(.system(size: height * 0.62, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, height * 0.3)
            .frame(minWidth: height, minHeight: height)
            .background(Capsule().fill(color))
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            .offset(x: height * 0.28, y: -height * 0.22)
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
        let inset = size * 0.1
        let cell = (size - inset * 2 - size * 0.06) / 2
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(theme.color(theme.widgetFill, max(0.14, theme.widgetFillOpacity + 0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), lineWidth: 0.6)
            )
            .overlay {
                LazyVGrid(columns: [GridItem(.fixed(cell), spacing: size * 0.06), GridItem(.fixed(cell))],
                          spacing: size * 0.06) {
                    ForEach(Array(folder.apps.prefix(4).enumerated()), id: \.offset) { _, app in
                        Image(nsImage: icons.icon(for: app))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: cell, height: cell)
                    }
                }
                .padding(inset)
            }
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
