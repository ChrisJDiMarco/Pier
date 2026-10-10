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

            let placedByID = Dictionary(geo.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            ForEach(controller.entries) { entry in
                if let placed = placedByID[entry.id] {
                    if placed.kind == .icon || placed.kind == .gap {
                        // Draw once at the largest magnified size, then scale on the GPU. The frame stays
                        // constant while hovering, so icons are never re-rasterized mid-animation.
                        let side = renderSide(for: placed, metrics: metrics)
                        // Placed with render transforms (not layout), so sub-pixel motion isn't snapped to
                        // the pixel grid: icons glide instead of stepping in half-point jumps.
                        EntryView(entry: entry, placed: placed, metrics: metrics, renderSide: side)
                            .frame(width: side, height: side)
                            .scaleEffect(placed.rect.width / side)
                            .transformEffect(CGAffineTransform(translationX: placed.rect.midX - side / 2,
                                                               y: placed.rect.midY - side / 2))
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    } else {
                        EntryView(entry: entry, placed: placed, metrics: metrics)
                            .frame(width: placed.rect.width, height: placed.rect.height)
                            .position(x: placed.rect.midX, y: placed.rect.midY)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
            }

            RunningIndicators(geometry: geo)
            AttentionBubbles(geometry: geo, theme: theme)

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

    /// Unmagnified (fitted) icon size times the maximum magnification, rounded so it's stable frame to frame.
    private func renderSide(for placed: PlacedElement, metrics: DockMetrics) -> CGFloat {
        let base = placed.rect.width / max(placed.scale, 0.001)
        return (base * max(1, metrics.magnification)).rounded(.up)
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
    /// When set, the tile is drawn at this fixed size and scaled by its container.
    var renderSide: CGFloat?
    @EnvironmentObject var controller: DockController
    @EnvironmentObject var store: PierStore

    var body: some View {
        let pressed = controller.pressedID == entry.id && controller.pressedControl == nil && !isWidget
        content
            .scaleEffect(controller.dropOntoID == entry.id ? 1.12 : (pressed ? 0.9 : 1))
            .brightness(pressed ? -0.12 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: controller.dropOntoID)
            .animation(.spring(response: 0.2, dampingFraction: 0.62), value: pressed)
    }

    @ViewBuilder private var content: some View {
        switch entry.kind {
        case .running(let app):
            AppTileView(ref: app.ref, size: iconSide)
        case .minimized(let w):
            MinimizedTileView(minimized: w, size: iconSide)
        case .item(let item):
            switch item.content {
            case .app(let ref): AppTileView(ref: ref, size: iconSide)
            case .folder(let folder): FolderTileView(folder: folder, size: iconSide)
            case .stack(let path): StackTileView(path: path, size: iconSide)
            case .trash: TrashTileView(size: iconSide)
            case .widget(let kind):
                WidgetView(kind: kind, size: placed.rect.size, vertical: store.settings.position.isVertical,
                           hovered: controller.hoveredID == entry.id)
            case .separator: DividerView(vertical: store.settings.position.isVertical)
            }
        case .divider:
            DividerView(vertical: store.settings.position.isVertical)
        case .gap:
            Color.clear
        }
    }

    private var iconSide: CGFloat { renderSide ?? min(placed.rect.width, placed.rect.height) }

    private var isWidget: Bool {
        if case .widget = placed.kind { return true }
        return false
    }
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
                .frame(width: 20, height: 10)
                .transformEffect(CGAffineTransform(translationX: item.point.x - 10, y: item.point.y - 5))
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
    var isMessage = false

    private let gap: CGFloat = 12
    private let slot: CGFloat = 420
    private let height: CGFloat = 30

    var body: some View {
        // Centered on `anchor` with a render transform, so it tracks the gliding icon without pixel steps.
        let (anchor, alignment): (CGPoint, Alignment) = {
            switch position {
            case .bottom: return (CGPoint(x: rect.midX, y: rect.minY - gap - 11), .center)
            case .left: return (CGPoint(x: rect.maxX + gap + slot / 2, y: rect.midY), .leading)
            case .right: return (CGPoint(x: rect.minX - gap - slot / 2, y: rect.midY), .trailing)
            }
        }()
        bubble
            .frame(width: slot, height: height, alignment: alignment)
            .transformEffect(CGAffineTransform(translationX: anchor.x - slot / 2, y: anchor.y - height / 2))
    }

    private var bubble: some View {
        HStack(spacing: 6) {
            if isMessage {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(isMessage ? 2 : 1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: isMessage ? 260 : nil, alignment: .leading)
                .fixedSize(horizontal: !isMessage, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .fixedSize()
    }
}

/// Messages sent with `pier notify --message …`, shown as callouts above the icon that asked.
struct AttentionBubbles: View {
    let geometry: DockGeometry
    let theme: Theme
    @EnvironmentObject var controller: DockController
    @ObservedObject private var attention = AttentionService.shared

    var body: some View {
        ForEach(bubbles(), id: \.id) { bubble in
            HoverLabel(text: bubble.text, theme: theme, rect: bubble.rect, position: geometry.position, isMessage: true)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: attention.messages)
    }

    private struct Bubble { let id: String; let text: String; let rect: CGRect }

    private func bubbles() -> [Bubble] {
        guard !attention.messages.isEmpty else { return [] }
        return controller.entries.compactMap { entry in
            guard entry.id != controller.hoveredID, let placed = geometry.element(entry.id) else { return nil }
            let keys: [String]
            switch entry.kind {
            case .running(let app): keys = [app.ref.key]
            case .item(let item): keys = item.appRef.map { [$0.key] } ?? item.folder?.apps.map(\.key) ?? []
            default: return nil
            }
            guard let text = keys.lazy.compactMap({ attention.messages[$0] }).first else { return nil }
            return Bubble(id: entry.id, text: text, rect: placed.rect)
        }
    }
}
