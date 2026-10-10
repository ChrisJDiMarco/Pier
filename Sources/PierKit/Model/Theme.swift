import AppKit
import SwiftUI

public enum BackgroundStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case liquidGlass, clearGlass, blur, solid, none
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .clearGlass: return "Clear Glass"
        case .blur: return "Frosted Blur"
        case .solid: return "Solid"
        case .none: return "None"
        }
    }
}

public enum IndicatorStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case dot, line, glow, none
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// Everything about how the dock looks. Themes are plain JSON so people can share them as `.piertheme` files.
public struct Theme: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var author: String

    public var background: BackgroundStyle
    public var tint: String          // hex, e.g. "#FFFFFF"
    public var tintOpacity: Double   // 0...1
    public var cornerRadius: Double  // fraction of dock thickness, 0...0.5
    public var borderColor: String
    public var borderOpacity: Double
    public var borderWidth: Double
    public var shadowOpacity: Double
    public var shadowRadius: Double

    public var iconSize: Double      // points
    public var iconSpacing: Double
    public var padding: Double
    public var edgeMargin: Double    // distance from the screen edge

    public var indicator: IndicatorStyle
    public var indicatorColor: String
    public var widgetFill: String
    public var widgetFillOpacity: Double
    public var textColor: String
    public var badgeColor: String

    public init(
        id: String, name: String, author: String = "Pier",
        background: BackgroundStyle = .liquidGlass, tint: String = "#FFFFFF", tintOpacity: Double = 0.12,
        cornerRadius: Double = 0.32, borderColor: String = "#FFFFFF", borderOpacity: Double = 0.35,
        borderWidth: Double = 0.75, shadowOpacity: Double = 0.28, shadowRadius: Double = 18,
        iconSize: Double = 54, iconSpacing: Double = 8, padding: Double = 9, edgeMargin: Double = 8,
        indicator: IndicatorStyle = .dot, indicatorColor: String = "#FFFFFF",
        widgetFill: String = "#FFFFFF", widgetFillOpacity: Double = 0.16,
        textColor: String = "auto", badgeColor: String = "#FF3B30"
    ) {
        self.id = id; self.name = name; self.author = author
        self.background = background; self.tint = tint; self.tintOpacity = tintOpacity
        self.cornerRadius = cornerRadius; self.borderColor = borderColor; self.borderOpacity = borderOpacity
        self.borderWidth = borderWidth; self.shadowOpacity = shadowOpacity; self.shadowRadius = shadowRadius
        self.iconSize = iconSize; self.iconSpacing = iconSpacing; self.padding = padding; self.edgeMargin = edgeMargin
        self.indicator = indicator; self.indicatorColor = indicatorColor
        self.widgetFill = widgetFill; self.widgetFillOpacity = widgetFillOpacity
        self.textColor = textColor; self.badgeColor = badgeColor
    }

    /// Tolerant decoding: a theme written by an older or newer Pier still loads, missing keys fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Theme(id: "default", name: "Default")
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        id = v(.id, UUID().uuidString)
        name = v(.name, "Untitled Theme")
        author = v(.author, "Unknown")
        background = v(.background, d.background)
        tint = v(.tint, d.tint)
        tintOpacity = v(.tintOpacity, d.tintOpacity).clamped(0, 1)
        cornerRadius = v(.cornerRadius, d.cornerRadius).clamped(0, 0.5)
        borderColor = v(.borderColor, d.borderColor)
        borderOpacity = v(.borderOpacity, d.borderOpacity).clamped(0, 1)
        borderWidth = v(.borderWidth, d.borderWidth).clamped(0, 6)
        shadowOpacity = v(.shadowOpacity, d.shadowOpacity).clamped(0, 1)
        shadowRadius = v(.shadowRadius, d.shadowRadius).clamped(0, 60)
        iconSize = v(.iconSize, d.iconSize).clamped(24, 128)
        iconSpacing = v(.iconSpacing, d.iconSpacing).clamped(0, 40)
        padding = v(.padding, d.padding).clamped(0, 40)
        edgeMargin = v(.edgeMargin, d.edgeMargin).clamped(0, 80)
        indicator = v(.indicator, d.indicator)
        indicatorColor = v(.indicatorColor, d.indicatorColor)
        widgetFill = v(.widgetFill, d.widgetFill)
        widgetFillOpacity = v(.widgetFillOpacity, d.widgetFillOpacity).clamped(0, 1)
        textColor = v(.textColor, d.textColor)
        badgeColor = v(.badgeColor, d.badgeColor)
    }

    public var thickness: CGFloat { CGFloat(iconSize + padding * 2) }

    /// Whether the theme reads as dark (light text) or light (dark text); nil follows the system ("auto"
    /// or a mid-tone color). Drives the appearance of the dock and its popups so glass and system text
    /// get the right contrast.
    public var prefersDarkAppearance: Bool? {
        guard textColor.lowercased() != "auto",
              let c = NSColor(hex: textColor)?.usingColorSpace(.sRGB) else { return nil }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        if luminance > 0.6 { return true }
        if luminance < 0.4 { return false }
        return nil
    }

    public var appearance: NSAppearance? {
        prefersDarkAppearance.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
    }
}

public extension Theme {
    /// The default: milky white glass, dark text, roomy padding and widget wells.
    static let meadow = Theme(
        id: "pier.meadow", name: "Meadow", background: .liquidGlass, tint: "#FFFFFF", tintOpacity: 0.34,
        cornerRadius: 0.24, borderColor: "#FFFFFF", borderOpacity: 0.72, borderWidth: 1.2,
        shadowOpacity: 0.22, shadowRadius: 22, iconSize: 56, iconSpacing: 16, padding: 14, edgeMargin: 8,
        indicator: .dot, indicatorColor: "#3A3A3C", widgetFill: "#FFFFFF", widgetFillOpacity: 0.3,
        textColor: "#2C2C2E", badgeColor: "#FF3B30"
    )

    static let liquid = Theme(id: "pier.liquid", name: "Liquid")

    /// Clear glass with white text. Wells are smoky dark so the text stays readable over bright windows.
    static let clear = Theme(
        id: "pier.clear", name: "Crystal", background: .clearGlass, tintOpacity: 0.04,
        borderOpacity: 0.5, shadowOpacity: 0.18, widgetFill: "#000000", widgetFillOpacity: 0.24,
        textColor: "#FFFFFF"
    )

    static let prairie = Theme(
        id: "pier.prairie", name: "Prairie", background: .liquidGlass, tint: "#F4E7DA", tintOpacity: 0.32,
        cornerRadius: 0.3, borderColor: "#FFF6EC", borderOpacity: 0.55, indicatorColor: "#5A3A2A",
        widgetFill: "#FFFFFF", widgetFillOpacity: 0.22, textColor: "#3B2A20", badgeColor: "#E5483B"
    )

    static let graphite = Theme(
        id: "pier.graphite", name: "Graphite", background: .blur, tint: "#1C1C1E", tintOpacity: 0.55,
        cornerRadius: 0.26, borderColor: "#FFFFFF", borderOpacity: 0.12, shadowOpacity: 0.45,
        indicator: .line, indicatorColor: "#E5E5EA", widgetFill: "#FFFFFF", widgetFillOpacity: 0.08,
        textColor: "#F2F2F7"
    )

    static let midnight = Theme(
        id: "pier.midnight", name: "Midnight", background: .solid, tint: "#0B1026", tintOpacity: 0.92,
        cornerRadius: 0.5, borderColor: "#7D8CFF", borderOpacity: 0.35, borderWidth: 1, shadowOpacity: 0.5,
        shadowRadius: 26, indicator: .glow, indicatorColor: "#8EA2FF", widgetFill: "#7D8CFF",
        widgetFillOpacity: 0.14, textColor: "#E6E9FF", badgeColor: "#FF5577"
    )

    static let paper = Theme(
        id: "pier.paper", name: "Paper", background: .solid, tint: "#FAF8F3", tintOpacity: 0.97,
        cornerRadius: 0.22, borderColor: "#000000", borderOpacity: 0.08, shadowOpacity: 0.2, shadowRadius: 12,
        indicator: .line, indicatorColor: "#1D1D1F", widgetFill: "#000000", widgetFillOpacity: 0.05,
        textColor: "#1D1D1F"
    )

    static let compact = Theme(
        id: "pier.compact", name: "Compact", background: .liquidGlass, tintOpacity: 0.1, cornerRadius: 0.28,
        iconSize: 40, iconSpacing: 5, padding: 6, edgeMargin: 4
    )

    static let builtIns: [Theme] = [.meadow, .liquid, .clear, .prairie, .graphite, .midnight, .paper, .compact]
}

// MARK: - Colors

public extension Color {
    init(hex: String, opacity: Double = 1) {
        self.init(nsColor: NSColor(hex: hex) ?? .white)
        self = self.opacity(opacity)
    }
}

public extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}

extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), hi) }
}
