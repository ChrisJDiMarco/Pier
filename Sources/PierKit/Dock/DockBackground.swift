import AppKit
import SwiftUI

extension Theme {
    /// Resolves a theme color; the special value "auto" follows the system's light/dark label color.
    func color(_ hex: String, _ opacity: Double = 1) -> Color {
        hex.lowercased() == "auto" ? Color.primary.opacity(opacity) : Color(hex: hex, opacity: opacity)
    }

    var text: Color { color(textColor) }
    var secondaryText: Color { color(textColor, 0.62) }
}

/// The dock's backdrop: Liquid Glass on macOS 26+, frosted blur, or a solid fill — plus border and shadow.
struct DockBackground: View {
    let theme: Theme
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            ShadowView(radius: radius, opacity: theme.shadowOpacity, blur: theme.shadowRadius)
            switch theme.background {
            case .liquidGlass, .clearGlass:
                GlassView(radius: radius, tint: NSColor(hex: theme.tint)?.withAlphaComponent(theme.tintOpacity),
                          clear: theme.background == .clearGlass)
            case .blur:
                BlurView(radius: radius)
                shape.fill(theme.color(theme.tint, theme.tintOpacity))
            case .solid:
                shape.fill(theme.color(theme.tint, theme.tintOpacity))
            case .none:
                EmptyView()
            }
            if theme.borderWidth > 0 && theme.background != .none {
                shape.strokeBorder(theme.color(theme.borderColor, theme.borderOpacity), lineWidth: theme.borderWidth)
            }
        }
        .allowsHitTesting(false)
    }
}

/// NSGlassEffectView where available, falling back to a behind-window visual effect view.
struct GlassView: NSViewRepresentable {
    let radius: CGFloat
    let tint: NSColor?
    let clear: Bool

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            configure(glass)
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        return blur
    }

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            configure(glass)
        } else if let blur = view as? NSVisualEffectView {
            blur.maskImage = .roundedMask(radius: radius)
        }
    }

    @available(macOS 26.0, *)
    private func configure(_ glass: NSGlassEffectView) {
        glass.cornerRadius = radius
        glass.tintColor = tint
        glass.style = clear ? .clear : .regular
    }
}

struct BlurView: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.maskImage = .roundedMask(radius: radius)
    }
}

/// A drop shadow drawn only *outside* the dock shape, so translucent backgrounds aren't darkened from below.
struct ShadowView: NSViewRepresentable {
    let radius: CGFloat
    let opacity: Double
    let blur: Double

    func makeNSView(context: Context) -> ShadowNSView { ShadowNSView() }

    func updateNSView(_ view: ShadowNSView, context: Context) {
        view.cornerRadius = radius
        view.shadowOpacity = Float(opacity)
        view.shadowBlur = blur
        view.needsLayout = true
    }
}

final class ShadowNSView: NSView {
    var cornerRadius: CGFloat = 0
    var shadowOpacity: Float = 0.3
    var shadowBlur: Double = 18
    private let shadowLayer = CALayer()
    private let maskLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOffset = CGSize(width: 0, height: -3)
        layer?.addSublayer(shadowLayer)
        maskLayer.fillRule = .evenOdd
        shadowLayer.mask = maskLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGPath(roundedRect: bounds, cornerWidth: min(cornerRadius, bounds.height / 2),
                          cornerHeight: min(cornerRadius, bounds.height / 2), transform: nil)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = path
        shadowLayer.shadowOpacity = shadowOpacity
        shadowLayer.shadowRadius = shadowBlur / 2
        let outer = CGMutablePath()
        outer.addRect(bounds.insetBy(dx: -120, dy: -120))
        outer.addPath(path)
        maskLayer.frame = bounds
        maskLayer.path = outer
        CATransaction.commit()
    }
}

extension NSImage {
    /// A resizable rounded-rect mask for NSVisualEffectView.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: CGSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
