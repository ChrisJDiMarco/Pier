import XCTest
@testable import PierKit

final class MagnificationMotionTests: XCTestCase {

    private func run(_ motion: inout MagnificationMotion, seconds: CGFloat, hz: CGFloat, pointer: CGFloat?) -> [CGFloat] {
        var amounts: [CGFloat] = []
        for _ in 0..<Int(seconds * hz) {
            motion.step(dt: 1 / hz, pointer: pointer)
            amounts.append(motion.amount)
        }
        return amounts
    }

    func testEasesInWithoutOvershootAndSettles() {
        var m = MagnificationMotion()
        let amounts = run(&m, seconds: 0.6, hz: 120, pointer: 300)
        XCTAssertLessThanOrEqual(amounts.max() ?? 0, 1.0001, "critically damped: never overshoots")
        XCTAssertEqual(zip(amounts, amounts.dropFirst()).filter { $1 < $0 - 0.0001 }.count, 0, "monotonic ease-in")
        XCTAssertTrue(m.isSettled)
        XCTAssertEqual(m.amount, 1)
    }

    func testEasesOutAndForgetsPointer() {
        var m = MagnificationMotion()
        _ = run(&m, seconds: 0.6, hz: 120, pointer: 300)
        _ = run(&m, seconds: 0.6, hz: 120, pointer: nil)
        XCTAssertEqual(m.amount, 0)
        XCTAssertNil(m.along)
        XCTAssertTrue(m.isSettled)
    }

    func testFrameRateIndependent() {
        var at60 = MagnificationMotion(), at120 = MagnificationMotion()
        _ = run(&at60, seconds: 0.1, hz: 60, pointer: 300)
        _ = run(&at120, seconds: 0.1, hz: 120, pointer: 300)
        XCTAssertEqual(at60.amount, at120.amount, accuracy: 0.01)
    }

    func testWaveStartsAtEntryPointThenGlides() {
        var m = MagnificationMotion()
        m.step(dt: 1 / 120, pointer: 300)
        XCTAssertEqual(m.along, 300, "no slide-in from a stale position")
        _ = run(&m, seconds: 0.3, hz: 120, pointer: 300)
        m.step(dt: 1 / 120, pointer: 400)
        let after = m.along ?? 0
        XCTAssertGreaterThan(after, 300)
        XCTAssertLessThan(after, 400, "follows smoothly instead of jumping")
        _ = run(&m, seconds: 0.3, hz: 120, pointer: 400)
        XCTAssertEqual(m.along ?? 0, 400, accuracy: 0.5)
    }
}
