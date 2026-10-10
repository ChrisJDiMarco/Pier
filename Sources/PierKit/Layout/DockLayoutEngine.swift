import CoreGraphics
import Foundation

public enum ElementKind: Equatable, Sendable {
    case icon
    case widget(WidgetKind)
    case divider
    case gap

    var magnifies: Bool { self == .icon || self == .gap }
}

public struct LayoutElement: Equatable, Sendable {
    public let id: String
    public let kind: ElementKind
    public init(id: String, kind: ElementKind) { self.id = id; self.kind = kind }
}

public struct PlacedElement: Equatable, Sendable {
    public let id: String
    public let kind: ElementKind
    /// Frame in the dock container's coordinate space (origin top-left, y grows downward).
    public let rect: CGRect
    public let scale: CGFloat
}

public struct DockGeometry: Equatable, Sendable {
    public let elements: [PlacedElement]
    public let background: CGRect
    public let position: DockPosition
    public let container: CGSize

    public static let empty = DockGeometry(elements: [], background: .zero, position: .bottom, container: .zero)

    public func element(_ id: String) -> PlacedElement? { elements.first { $0.id == id } }

    /// Position along the dock's main axis.
    public func along(_ p: CGPoint) -> CGFloat { position.isVertical ? p.y : p.x }
}

public struct DockMetrics: Equatable, Sendable {
    public var iconSize: CGFloat
    public var spacing: CGFloat
    public var padding: CGFloat
    public var edgeMargin: CGFloat
    public var magnification: CGFloat   // 1 = off
    public var influence: CGFloat       // how many icons the magnification wave spans on each side

    public init(theme: Theme, magnification: CGFloat) {
        iconSize = CGFloat(theme.iconSize)
        spacing = CGFloat(theme.iconSpacing)
        padding = CGFloat(theme.padding)
        edgeMargin = CGFloat(theme.edgeMargin)
        self.magnification = max(1, magnification)
        influence = 2.6
    }

    public var thickness: CGFloat { iconSize + padding * 2 }
    /// Distance from the dock's edge to a widget well.
    public var wellInset: CGFloat { padding * 0.7 }
    public var dividerLength: CGFloat { 7 }

    /// Space the window needs perpendicular to the screen edge (magnified icons + label + margin).
    public var windowDepth: CGFloat { edgeMargin + padding * 2 + iconSize * magnification + 44 }
}

/// Pure geometry: given the dock's elements, metrics and pointer, compute where everything goes.
public enum DockLayoutEngine {

    public static func baseLength(_ kind: ElementKind, metrics m: DockMetrics, vertical: Bool) -> CGFloat {
        switch kind {
        case .icon, .gap: return m.iconSize
        case .divider: return m.dividerLength
        case .widget(let w): return vertical ? m.iconSize : (m.iconSize * w.widthFactor).rounded()
        }
    }

    /// Magnification factor for an icon whose base center is `distance` points from the pointer.
    public static func scale(distance: CGFloat, metrics m: DockMetrics) -> CGFloat {
        guard m.magnification > 1 else { return 1 }
        let radius = m.iconSize * m.influence
        let t = min(abs(distance) / radius, 1)
        return 1 + (m.magnification - 1) * (cos(.pi * t) + 1) / 2
    }

    public static func layout(
        elements: [LayoutElement], metrics: DockMetrics, position: DockPosition,
        container: CGSize, pointer: CGPoint?
    ) -> DockGeometry {
        let m = fitted(metrics, elements: elements, position: position, container: container)
        let vertical = position.isVertical
        let available = vertical ? container.height : container.width
        let base = elements.map { baseLength($0.kind, metrics: m, vertical: vertical) }

        // Base (unmagnified) starts, measured from the dock's leading edge.
        var baseStarts: [CGFloat] = []
        var cursor = m.padding
        for (i, length) in base.enumerated() {
            baseStarts.append(cursor)
            cursor += length + (i < base.count - 1 ? m.spacing : 0)
        }
        let baseTotal = cursor + m.padding
        let baseOrigin = (available - baseTotal) / 2

        // Magnified lengths.
        let pointerAlong = pointer.map { vertical ? $0.y : $0.x }
        let u = pointerAlong.map { $0 - baseOrigin }
        var scales: [CGFloat] = elements.enumerated().map { i, el in
            guard el.kind.magnifies, let u else { return 1 }
            return scale(distance: u - (baseStarts[i] + base[i] / 2), metrics: m)
        }
        // Growth is linear in (scale - 1), so if magnifying would push the dock off screen,
        // shrink every icon's extra size by the same factor (the macOS Dock does this when it's full).
        let growth = zip(base, scales).reduce(CGFloat(0)) { $0 + $1.0 * ($1.1 - 1) }
        let room = available - baseTotal
        if growth > 0, growth > room {
            let factor = max(0, room) / growth
            scales = scales.map { 1 + ($0 - 1) * factor }
        }
        let lengths = zip(base, scales).enumerated().map { i, pair in
            elements[i].kind.magnifies ? pair.0 * pair.1 : pair.0
        }
        var starts: [CGFloat] = []
        cursor = m.padding
        for (i, length) in lengths.enumerated() {
            starts.append(cursor)
            cursor += length + (i < lengths.count - 1 ? m.spacing : 0)
        }
        let total = cursor + m.padding

        // Keep the point under the cursor fixed while the dock grows around it (what the macOS Dock does).
        var origin = baseOrigin
        if let u, let pointerAlong {
            origin = pointerAlong - mapToMagnified(u, baseStarts: baseStarts, base: base, starts: starts,
                                                   lengths: lengths, baseTotal: baseTotal, total: total)
            if total <= available { origin = origin.clamped(0, available - total) }
        }

        let crossStart = m.edgeMargin + m.padding
        let placed: [PlacedElement] = elements.enumerated().map { i, el in
            let along = origin + starts[i]
            let length = lengths[i]
            let (cross, depth): (CGFloat, CGFloat)
            switch el.kind {
            case .icon, .gap: (cross, depth) = (crossStart, m.iconSize * scales[i])
            // Widget "wells" are a little taller than icons, inset evenly from the dock's edges.
            case .widget: (cross, depth) = (m.edgeMargin + m.wellInset, m.thickness - m.wellInset * 2)
            case .divider: (cross, depth) = (crossStart + m.iconSize * 0.2, m.iconSize * 0.6)
            }
            return PlacedElement(id: el.id, kind: el.kind,
                                 rect: rect(along: along, length: length, cross: cross, depth: depth,
                                            position: position, container: container),
                                 scale: scales[i])
        }
        let background = rect(along: origin, length: total, cross: m.edgeMargin, depth: m.thickness,
                              position: position, container: container)
        return DockGeometry(elements: placed, background: background, position: position, container: container)
    }

    /// Unmagnified length of the whole dock along its edge.
    public static func restingLength(_ elements: [LayoutElement], metrics m: DockMetrics, vertical: Bool) -> CGFloat {
        let lengths = elements.map { baseLength($0.kind, metrics: m, vertical: vertical) }
        return lengths.reduce(0, +) + m.spacing * CGFloat(max(0, lengths.count - 1)) + m.padding * 2
    }

    /// Shrinks icons, spacing and padding (never below a floor) so a crowded dock still fits on screen,
    /// the way the macOS Dock does.
    public static func fitted(_ m: DockMetrics, elements: [LayoutElement], position: DockPosition,
                              container: CGSize) -> DockMetrics {
        let vertical = position.isVertical
        let available = (vertical ? container.height : container.width) - 2 * max(m.edgeMargin, 8)
        guard available > 0, !elements.isEmpty else { return m }
        var fit = m
        for _ in 0..<4 {
            let length = restingLength(elements, metrics: fit, vertical: vertical)
            guard length > available + 0.5 else { break }
            let factor = available / length
            fit.iconSize = max(16, fit.iconSize * factor)
            fit.spacing = max(1, fit.spacing * factor)
            fit.padding = max(3, fit.padding * factor)
        }
        return fit
    }

    /// Converts dock-space (along the edge, cross = distance from the screen edge) into container coordinates.
    public static func rect(along: CGFloat, length: CGFloat, cross: CGFloat, depth: CGFloat,
                            position: DockPosition, container: CGSize) -> CGRect {
        switch position {
        case .bottom: return CGRect(x: along, y: container.height - cross - depth, width: length, height: depth)
        case .left: return CGRect(x: cross, y: along, width: depth, height: length)
        case .right: return CGRect(x: container.width - cross - depth, y: along, width: depth, height: length)
        }
    }

    private static func mapToMagnified(_ u: CGFloat, baseStarts: [CGFloat], base: [CGFloat], starts: [CGFloat],
                                       lengths: [CGFloat], baseTotal: CGFloat, total: CGFloat) -> CGFloat {
        guard let first = baseStarts.first, u >= first else { return u }
        for i in baseStarts.indices {
            let bEnd = baseStarts[i] + base[i]
            if u <= bEnd {
                let t = base[i] > 0 ? (u - baseStarts[i]) / base[i] : 0
                return starts[i] + t * lengths[i]
            }
            let nextStart = i + 1 < baseStarts.count ? baseStarts[i + 1] : baseTotal
            if u < nextStart { return starts[i] + lengths[i] + (u - bEnd) }
        }
        return total - (baseTotal - u)
    }
}

// MARK: - Hit testing

public enum DropTarget: Equatable, Sendable {
    case onto(String)
    case insert(before: String?)   // nil = at the end
}

public extension DockGeometry {

    /// The element under `p`, with forgiving edges: gaps between icons and the dock's padding count as hits.
    func hit(_ p: CGPoint, spacing: CGFloat) -> PlacedElement? {
        let probe = alongCrossRect(expandAlong: spacing / 2 + 0.5)
        return elements.first { el in
            el.kind != .divider && el.kind != .gap && probe(el.rect).contains(p)
        }
    }

    func isInsideDock(_ p: CGPoint, slop: CGFloat = 0) -> Bool {
        if background.insetBy(dx: -slop, dy: -slop).contains(p) { return true }
        return elements.contains { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }
    }

    /// Where a drop at `p` would land: onto an icon's center, or between elements.
    func dropTarget(at p: CGPoint, allowOnto: (PlacedElement) -> Bool) -> DropTarget {
        let a = along(p)
        for el in elements where el.kind != .gap {
            let r = el.rect
            let start = position.isVertical ? r.minY : r.minX
            let length = position.isVertical ? r.height : r.width
            if el.kind == .icon, allowOnto(el), a > start + length * 0.22, a < start + length * 0.78 {
                return .onto(el.id)
            }
            if a < start + length / 2 { return .insert(before: el.id) }
        }
        return .insert(before: nil)
    }

    private func alongCrossRect(expandAlong: CGFloat) -> (CGRect) -> CGRect {
        let bg = background
        return { r in
            switch position {
            case .bottom:
                return CGRect(x: r.minX - expandAlong, y: min(r.minY, bg.minY), width: r.width + expandAlong * 2,
                              height: max(r.maxY, bg.maxY) - min(r.minY, bg.minY))
            case .left, .right:
                return CGRect(x: min(r.minX, bg.minX), y: r.minY - expandAlong,
                              width: max(r.maxX, bg.maxX) - min(r.minX, bg.minX), height: r.height + expandAlong * 2)
            }
        }
    }
}
