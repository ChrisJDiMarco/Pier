import CoreGraphics

public enum NowPlayingControl: CaseIterable, Sendable {
    case previous, playPause, next
}

/// Geometry of the Now Playing widget's transport buttons. The view draws them here and the dock's
/// interaction layer hit-tests the same rects, so clicks never depend on SwiftUI buttons receiving
/// events in a window that can't become key.
public enum NowPlayingLayout {
    public static func controlWidth(_ size: CGSize) -> CGFloat { size.height * 0.26 }
    public static func controlSpacing(_ size: CGSize) -> CGFloat { size.height * 0.04 }
    public static func trailingPadding(_ size: CGSize) -> CGFloat { size.height * 0.1 }

    /// Rects in the widget's own coordinates (origin top-left), full height so they're easy to hit.
    public static func controlRects(in size: CGSize) -> [(NowPlayingControl, CGRect)] {
        let w = controlWidth(size), sp = controlSpacing(size)
        var x = size.width - trailingPadding(size) - w
        var result: [(NowPlayingControl, CGRect)] = []
        for control in NowPlayingControl.allCases.reversed() {
            result.append((control, CGRect(x: x, y: 0, width: w, height: size.height)))
            x -= w + sp
        }
        return result.reversed()
    }

    public static func control(at point: CGPoint, in size: CGSize) -> NowPlayingControl? {
        controlRects(in: size).first { $0.1.contains(point) }?.0
    }
}
