import AppKit
import QuartzCore

/// The physics behind hover magnification, kept pure so it can be tested and stays frame-rate independent.
///
/// `amount` (0 = flat, 1 = fully magnified) follows a critically damped spring: it eases in and out with
/// no overshoot or wobble. `along` follows the pointer with exponential smoothing, so the wave glides
/// instead of stepping, and it starts exactly where the pointer enters the dock.
public struct MagnificationMotion: Equatable, Sendable {
    public var amount: CGFloat = 0
    public var velocity: CGFloat = 0
    public var along: CGFloat?

    /// Seconds for the spring to settle (period of the undamped oscillator).
    public static let response: CGFloat = 0.28
    /// Time constant for following the pointer; ~95% caught up after 3x this.
    public static let follow: CGFloat = 0.03
    private static let substep: CGFloat = 1.0 / 480

    public init() {}

    public var isSettled: Bool { velocity == 0 && (amount == 0 || amount == 1) }

    /// Advances by `dt` seconds. `pointer` is the pointer's position along the dock, or nil when it's away.
    public mutating func step(dt: CGFloat, pointer: CGFloat?) {
        let goal: CGFloat = pointer == nil ? 0 : 1
        if let pointer {
            if let current = along, amount > 0.02 {
                along = current + (pointer - current) * (1 - exp(-dt / Self.follow))
            } else {
                along = pointer
            }
        }

        // Critically damped spring, integrated in small fixed substeps so any frame rate gives the same curve.
        let omega = 2 * .pi / Self.response
        var remaining = max(0, dt)
        while remaining > 0 {
            let h = min(remaining, Self.substep)
            let accel = omega * omega * (goal - amount) - 2 * omega * velocity
            velocity += accel * h
            amount += velocity * h
            remaining -= h
        }

        if goal == 0, amount < 0.0015, abs(velocity) < 0.02 {
            amount = 0; velocity = 0; along = nil
        } else if goal == 1, abs(1 - amount) < 0.0015, abs(velocity) < 0.02 {
            amount = 1; velocity = 0
        }
    }
}

/// Calls back once per display refresh (120 Hz on ProMotion), paused when nothing is moving.
final class FrameDriver: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private let onFrame: (CGFloat) -> Void

    init(view: NSView, onFrame: @escaping (CGFloat) -> Void) {
        self.onFrame = onFrame
        super.init()
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        self.link = link
    }

    var isRunning: Bool { link?.isPaused == false }

    func resume() {
        guard let link, link.isPaused else { return }
        last = 0
        link.isPaused = false
    }

    func pause() {
        link?.isPaused = true
        last = 0
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        // Clamp dt so a hiccup (or the first frame) never makes the spring jump.
        let dt = last == 0 ? CGFloat(link.targetTimestamp - link.timestamp) : CGFloat(min(now - last, 1.0 / 20))
        last = now
        onFrame(max(dt, 1.0 / 240))
    }
}
