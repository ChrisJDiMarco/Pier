import SwiftUI

struct DockRootView: View {
    @EnvironmentObject var controller: DockController
    @EnvironmentObject var store: PierStore

    var body: some View {
        let geo = controller.geometry
        let theme = store.theme
        let metrics = controller.metrics
        ZStack(alignment: .topLeading) {
            DockBackground(theme: theme, radius: metrics.thickness * CGFloat(theme.cornerRadius))
                .frame(width: max(0, geo.background.width), height: max(0, geo.background.height))
                .position(x: geo.background.midX, y: geo.background.midY)

            ForEach(controller.entries) { entry in
                if let placed = geo.element(entry.id) {
                    EntryView(entry: entry, placed: placed, metrics: metrics)
                        .frame(width: placed.rect.width, height: placed.rect.height)
                        .position(x: placed.rect.midX, y: placed.rect.midY)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }

            RunningIndicators(geometry: geo)

            if store.settings.showLabels, let id = controller.hoveredID, controller.pressedID == nil,
               !PopupController.shared.isShowing, let entry = controller.entry(id), let placed = geo.element(id),
               !entry.title.isEmpty, !isWidget(entry) {
                HoverLabel(text: entry.title, theme: theme, rect: placed.rect, position: geo.position)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: geo.container.width, height: geo.container.height, alignment: .topLeading)
        .offset(hiddenOffset(metrics: metrics))
        .opacity(controller.isRevealed ? 1 : 0)
    }

    private func isWidget(_ entry: DisplayEntry) -> Bool {
        if case .widget = entry.elementKind { return true }
        return false
    }

    private func hiddenOffset(metrics: DockMetrics) -> CGSize {
        guard !controller.isRevealed else { return .zero }
        let d = metrics.edgeMargin + metrics.thickness + 16
        switch store.settings.position {
        case .bottom: return CGSize(width: 0, height: d)
        case .left: return CGSize(width: -d, height: 0)
        case .right: return CGSize(width: d, height: 0)
        }
    }
}

// MARK: - Entry

struct EntryView: View {
    let entry: DisplayEntry
    let placed: PlacedElement
    let metrics: DockMetrics
    @EnvironmentObject var controller: DockController
    @EnvironmentObject var store: PierStore

    var body: some View {
        content
            .scaleEffect(controller.dropOntoID == entry.id ? 1.12 : 1)
            .brightness(controller.pressedID == entry.id ? -0.22 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: controller.dropOntoID)
    }

    @ViewBuilder private var content: some View {
        switch entry.kind {
        case .running(let app):
            AppTileView(ref: app.ref, size: iconSide)
        case .item(let item):
            switch item.content {
            case .app(let ref): AppTileView(ref: ref, size: iconSide)
            case .folder(let folder): FolderTileView(folder: folder, size: iconSide)
            case .stack(let path): StackTileView(path: path, size: iconSide)
            case .trash: TrashTileView(size: iconSide)
            case .widget(let kind):
                WidgetView(kind: kind, size: placed.rect.size, vertical: store.settings.position.isVertical)
            case .separator: DividerView(vertical: store.settings.position.isVertical)
            }
        case .divider:
            DividerView(vertical: store.settings.position.isVertical)
        case .gap:
            Color.clear
        }
    }

    private var iconSide: CGFloat { min(placed.rect.width, placed.rect.height) }
}

struct DividerView: View {
    let vertical: Bool
    @EnvironmentObject var store: PierStore

    var body: some View {
        let color = store.theme.color(store.theme.textColor, 0.16)
        if vertical {
            Capsule().fill(color).frame(height: 1.5)
        } else {
            Capsule().fill(color).frame(width: 1.5)
        }
    }
}

// MARK: - Indicators & labels

struct RunningIndicators: View {
    let geometry: DockGeometry
    @EnvironmentObject var controller: DockController
    @EnvironmentObject var store: PierStore
    @EnvironmentObject var running: RunningAppsService

    var body: some View {
        let theme = store.theme
        ForEach(indicators(), id: \.id) { item in
            IndicatorMark(style: theme.indicator, color: theme.color(theme.indicatorColor), active: item.active)
                .position(item.point)
                .allowsHitTesting(false)
        }
    }

    private struct Mark { let id: String; let point: CGPoint; let active: Bool }

    private func indicators() -> [Mark] {
        controller.entries.compactMap { entry -> Mark? in
            guard let placed = geometry.element(entry.id) else { return nil }
            let refs: [AppRef]
            switch entry.kind {
            case .running(let app): refs = [app.ref]
            case .item(let item):
                if let ref = item.appRef { refs = [ref] } else if let f = item.folder { refs = f.apps } else { return nil }
            default: return nil
            }
            let apps = refs.compactMap { running.running($0) }
            guard !apps.isEmpty else { return nil }
            // Centered in the padding between the icon and the dock's outer edge.
            let r = placed.rect, bg = geometry.background
            let point: CGPoint
            switch geometry.position {
            case .bottom: point = CGPoint(x: r.midX, y: (r.maxY + bg.maxY) / 2)
            case .left: point = CGPoint(x: (bg.minX + r.minX) / 2, y: r.midY)
            case .right: point = CGPoint(x: (r.maxX + bg.maxX) / 2, y: r.midY)
            }
            return Mark(id: entry.id, point: point, active: apps.contains(where: \.isActive))
        }
    }
}

struct IndicatorMark: View {
    let style: IndicatorStyle
    let color: Color
    let active: Bool

    var body: some View {
        switch style {
        case .dot:
            Circle().fill(color.opacity(active ? 1 : 0.7)).frame(width: 4, height: 4)
        case .line:
            Capsule().fill(color.opacity(active ? 1 : 0.6)).frame(width: active ? 14 : 8, height: 3)
        case .glow:
            Circle().fill(color).frame(width: 5, height: 5)
                .shadow(color: color, radius: active ? 5 : 3)
        case .none:
            EmptyView()
        }
    }
}

struct HoverLabel: View {
    let text: String
    let theme: Theme
    let rect: CGRect
    let position: DockPosition

    private let gap: CGFloat = 12
    private let slot: CGFloat = 420

    var body: some View {
        switch position {
        case .bottom:
            bubble.frame(width: slot).position(x: rect.midX, y: rect.minY - gap - 11)
        case .left:
            bubble.frame(width: slot, alignment: .leading).position(x: rect.maxX + gap + slot / 2, y: rect.midY)
        case .right:
            bubble.frame(width: slot, alignment: .trailing).position(x: rect.minX - gap - slot / 2, y: rect.midY)
        }
    }

    private var bubble: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .fixedSize()
    }
}
