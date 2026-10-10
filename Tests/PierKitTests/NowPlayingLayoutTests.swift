import XCTest
@testable import PierKit

final class NowPlayingLayoutTests: XCTestCase {
    private let size = CGSize(width: 240, height: 64)

    func testControlsSitAtTrailingEdgeInOrder() {
        let rects = NowPlayingLayout.controlRects(in: size)
        XCTAssertEqual(rects.map(\.0), [.previous, .playPause, .next])
        XCTAssertEqual(rects[2].1.maxX, size.width - NowPlayingLayout.trailingPadding(size), accuracy: 0.001)
        XCTAssertLessThan(rects[0].1.maxX, rects[1].1.minX)
        XCTAssertLessThan(rects[1].1.maxX, rects[2].1.minX)
    }

    func testHitTestingFindsEachControlAndIgnoresArtwork() {
        for (control, rect) in NowPlayingLayout.controlRects(in: size) {
            XCTAssertEqual(NowPlayingLayout.control(at: CGPoint(x: rect.midX, y: 4), in: size), control)
        }
        XCTAssertNil(NowPlayingLayout.control(at: CGPoint(x: 20, y: 32), in: size))
    }
}
