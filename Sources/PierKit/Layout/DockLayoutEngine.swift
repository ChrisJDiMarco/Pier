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

    public static func layout(
        elements: [LayoutElement], metrics: DockMetrics, position: DockPosition,
        container: CGSize, pointer: CGPoint?
    ) -> DockGeometry {
        let m = fitted(metrics, elements: elements, position: position, container: container)
        let vertical = position.isVertical
        let available = vertical ? container.height : container.width
        let base = elements.map { baseLength($0.kind, metrics: m, vertical: vertical) }

        // Base (unmagnified) layout, measured from the dock's leading edge.
        var baseStarts: [CGFloat] = []
        var cursor = m.padding
        for (i, length) in base.enumerated() {
            baseStarts.append(cursor)
            cursor += length + (i < base.count - 1 ? m.spacing : 0)
        }
        let baseTotal = cursor + m.padding
        let baseOrigin = (available - baseTotal) / 2

        // The bulge: scale(x) = 1 + extra * bump(x - u). Total growth is exactly extra * radius wherever the
        // pointer is, so capping `extra` against the free room keeps a full dock on screen without the
        // bulge pulsing as the pointer moves.
        let pointerAlong = pointer.map { vertical ? $0.y : $0.x }
        let radius = m.iconSize * m.influence
        var extra = max(0, m.magnification - 1)
        let room = available - baseTotal
        if extra * radius > room { extra = max(0, room) / radius }
        let bulge = Bulge(center: pointerAlong.map { $0 - baseOrigin } ?? 0, radius: radius,
                          extra: pointerAlong == nil ? 0 : extra)

        // Integrate the scale along the dock. Positions and sizes are integrals of one smooth curve, so they
        // change continuously as the pointer moves: no kinks when crossing from one icon to the next.
        // Widgets keep their size (the curve is flat over them); everything else, gaps included, grows.
        var segments: [Segment] = []
        var x: CGFloat = 0
        func add(to end: CGFloat, magnifies: Bool) {
            if end > x { segments.append(Segment(start: x, end: end, magnifies: magnifies)) }
            x = max(x, end)
        }
        for (i, el) in elements.enumerated() {
            add(to: baseStarts[i], magnifies: true)
            add(to: baseStarts[i] + base[i], magnifies: el.kind.magnifies || el.kind == .divider)
        }
        add(to: baseTotal, magnifies: true)
        func mapped(_ position: CGFloat) -> CGFloat { bulge.mapped(position, segments: segments) }

        let starts = baseStarts.map(mapped)
        let ends = zip(baseStarts, base).map { mapped($0 + $1) }
        let total = mapped(baseTotal)

        // Keep the point under the cursor fixed while the dock grows around it (what the macOS Dock does).
        var origin = baseOrigin
        if let pointerAlong, bulge.extra > 0 {
            origin = pointerAlong - mapped(pointerAlong - baseOrigin)
            if total <= available { origin = origin.clamped(0, available - total) }
        }

        let crossStart = m.edgeMargin + m.padding
        let placed: [PlacedElement] = elements.enumerated().map { i, el in
            let length = ends[i] - starts[i]
            let scale = el.kind.magnifies && base[i] > 0 ? length / base[i] : 1
            let (cross, depth): (CGFloat, CGFloat)
            switch el.kind {
            case .icon, .gap: (cross, depth) = (crossStart, m.iconSize * scale)
            // Widget "wells" are a little taller than icons, inset evenly from the dock's edges.
            case .widget: (cross, depth) = (m.edgeMargin + m.wellInset, m.thickness - m.wellInset * 2)
            case .divider: (cross, depth) = (crossStart + m.iconSize * 0.2, m.iconSize * 0.6)
            }
            return PlacedElement(id: el.id, kind: el.kind,
                                 rect: rect(along: origin + starts[i], length: length, cross: cross, depth: depth,
                                            position: position, container: container),
                                 scale: scale)
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

}

/// A span of the dock in base (unmagnified) coordinates, and whether it grows under the bulge.
struct Segment {
    let start: CGFloat
    let end: CGFloat
    let magnifies: Bool
}

/// The magnification curve: a raised-cosine bump of half-width `radius` centered on the pointer.
/// `area(a, b)` is its exact integral, so mapping base → magnified coordinates has no approximation error.
struct Bulge {
    let center: CGFloat
    let radius: CGFloat
    let extra: CGFloat

    /// Cumulative integral of the unit bump from -infinity to `y` (0 ... radius).
    private func cumulative(_ y: CGFloat) -> CGFloat {
        if y <= -radius { return 0 }
        if y >= radius { return radius }
        return (y + radius) / 2 + radius / (2 * .pi) * sin(.pi * y / radius)
    }

    func area(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        guard extra > 0, radius > 0 else { return 0 }
        return extra * (cumulative(b - center) - cumulative(a - center))
    }

    /// Magnified position of base position `x`: length so far plus the bulge over the growing segments.
    func mapped(_ x: CGFloat, segments: [Segment]) -> CGFloat {
        var result = x
        guard extra > 0 else { return result }
        for segment in segments where segment.magnifies && segment.start < x {
            result += area(segment.start, min(segment.end, x))
        }
        return result
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

    /// Hover test with hysteresis. Entering requires touching the dock or an icon; once hovering, the whole
    /// bulge counts (including the empty space between magnified icons), so it never flickers off mid-glide.
    func isInHoverZone(_ p: CGPoint, alreadyHovering: Bool, slop: CGFloat = 6) -> Bool {
        guard alreadyHovering else { return isInsideDock(p) }
        let icons = elements.filter { $0.kind == .icon }.map(\.rect)
        let bg = background
        let zone: CGRect
        switch position {
        case .bottom:
            let top = icons.map(\.minY).min().map { Swift.min($0, bg.minY) } ?? bg.minY
            zone = CGRect(x: bg.minX, y: top, width: bg.width, height: bg.maxY - top)
        case .left:
            let outer = icons.map(\.maxX).max().map { Swift.max($0, bg.maxX) } ?? bg.maxX
            zone = CGRect(x: bg.minX, y: bg.minY, width: outer - bg.minX, height: bg.height)
        case .right:
            let outer = icons.map(\.minX).min().map { Swift.min($0, bg.minX) } ?? bg.minX
            zone = CGRect(x: outer, y: bg.minY, width: bg.maxX - outer, height: bg.height)
        }
        return zone.insetBy(dx: -slop, dy: -slop).contains(p)
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
