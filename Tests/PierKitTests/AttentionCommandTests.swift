import XCTest
@testable import PierKit

final class AttentionCommandTests: XCTestCase {
    private func parse(_ s: String) -> AttentionCommand? { AttentionCommand.parse(URL(string: s)!) }

    func testNotifyDefaultsToOneBounceGlowAndMessage() throws {
        let c = try XCTUnwrap(parse("pier://notify?app=com.apple.Terminal&message=Build%20done&text=%E2%9C%93"))
        XCTAssertEqual(c.action, .notify)
        XCTAssertEqual(c.app, "com.apple.Terminal")
        XCTAssertEqual(c.bounces, 1)
        XCTAssertTrue(c.flash)
        XCTAssertEqual(c.message, "Build done")
        XCTAssertEqual(c.badge, "✓")
    }

    func testBounceCountsAreClampedAndUntilOpenedIsSupported() throws {
        XCTAssertEqual(try XCTUnwrap(parse("pier://bounce?app=X")).bounces, 3)
        XCTAssertEqual(try XCTUnwrap(parse("pier://bounce?app=X&times=999")).bounces, 20)
        XCTAssertEqual(try XCTUnwrap(parse("pier://bounce?app=X&until=opened")).bounces, AttentionCommand.untilOpened)
        XCTAssertNil(try XCTUnwrap(parse("pier://badge?app=X&text=1")).bounces, "badges don't bounce by default")
    }

    func testRejectsBadInput() {
        XCTAssertNil(parse("https://bounce?app=X"), "wrong scheme")
        XCTAssertNil(parse("pier://explode?app=X"), "unknown action")
        XCTAssertNil(parse("pier://bounce"), "missing app")
        XCTAssertNil(parse("pier://badge?app=X"), "badge needs text")
    }

    func testSanitizesTextAndColor() throws {
        let long = String(repeating: "m", count: 500)
        let c = try XCTUnwrap(parse("pier://badge?app=X&text=12345678&color=red&message=\(long)"))
        XCTAssertEqual(c.badge, "1234", "badges are capped at 4 characters")
        XCTAssertNil(c.color, "only hex colors are accepted")
        XCTAssertEqual(c.message?.count, 140)
        let control = try XCTUnwrap(parse("pier://notify?app=X&message=hi%0A%07there"))
        XCTAssertEqual(control.message, "hithere", "control characters are stripped")
    }

    func testClearDropsBadgeAndMessage() throws {
        let c = try XCTUnwrap(parse("pier://clear?app=all&text=9&message=x"))
        XCTAssertEqual(c.action, .clear)
        XCTAssertNil(c.badge)
        XCTAssertNil(c.message)
    }
}
