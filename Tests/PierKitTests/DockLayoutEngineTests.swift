import XCTest
@testable import PierKit

final class DockLayoutEngineTests: XCTestCase {
    private let container = CGSize(width: 1000, height: 200)

    private func metrics(magnification: CGFloat = 1) -> DockMetrics {
        DockMetrics(theme: Theme(id: "t", name: "t", iconSize: 50, iconSpacing: 10, padding: 10, edgeMargin: 8),
                    magnification: magnification)
    }

    private func icons(_ n: Int) -> [LayoutElement] {
        (0..<n).map { LayoutElement(id: "i\($0)", kind: .icon) }
    }

    func testRestingDockIsCenteredAndSizedFromIcons() {
        let geo = DockLayoutEngine.layout(elements: icons(3), metrics: metrics(), position: .bottom,
                                          container: container, pointer: nil)
        // 3 icons * 50 + 2 gaps * 10 + 2 * padding 10 = 190
        XCTAssertEqual(geo.background.width, 190, accuracy: 0.001)
        XCTAssertEqual(geo.background.midX, 500, accuracy: 0.001)
        XCTAssertEqual(geo.background.maxY, 200 - 8, accuracy: 0.001, "sits edgeMargin above the bottom")
        XCTAssertEqual(geo.elements[0].rect.size, CGSize(width: 50, height: 50))
    }

    func testMagnificationPeaksUnderPointerAndFallsOff() {
        let m = metrics(magnification: 2)
        let rest = DockLayoutEngine.layout(elements: icons(7), metrics: m, position: .bottom,
                                           container: container, pointer: nil)
        let center = rest.elements[3].rect
        let geo = DockLayoutEngine.layout(elements: icons(7), metrics: m, position: .bottom, container: container,
                                          pointer: CGPoint(x: center.midX, y: center.midY))
        let scales = geo.elements.map(\.scale)
        XCTAssertEqual(scales[3], 2, accuracy: 0.001)
        XCTAssertGreaterThan(scales[2], scales[1])
        XCTAssertEqual(scales[2], scales[4], accuracy: 0.001, "symmetric falloff")
        XCTAssertEqual(scales[0], 1, accuracy: 0.05)
    }

    func testIconUnderPointerStaysUnderPointer() {
        let m = metrics(magnification: 1.8)
        let rest = DockLayoutEngine.layout(elements: icons(9), metrics: m, position: .bottom,
                                           container: container, pointer: nil)
        let target = rest.elements[2].rect
        let pointer = CGPoint(x: target.midX + 7, y: target.midY)
        let geo = DockLayoutEngine.layout(elements: icons(9), metrics: m, position: .bottom,
                                          container: container, pointer: pointer)
        XCTAssertTrue(geo.elements[2].rect.minX <= pointer.x && pointer.x <= geo.elements[2].rect.maxX)
    }

    func testWidgetsAreWiderAndDoNotMagnify() {
        let elements = [LayoutElement(id: "a", kind: .icon), LayoutElement(id: "w", kind: .widget(.nowPlaying))]
        let geo = DockLayoutEngine.layout(elements: elements, metrics: metrics(magnification: 2), position: .bottom,
                                          container: container, pointer: CGPoint(x: 520, y: 170))
        let widget = geo.element("w")!
        XCTAssertEqual(widget.scale, 1)
        XCTAssertEqual(widget.rect.width, (50 * WidgetKind.nowPlaying.widthFactor).rounded(), accuracy: 0.001)
    }

    func testLeftDockStacksVertically() {
        let geo = DockLayoutEngine.layout(elements: icons(2), metrics: metrics(), position: .left,
                                          container: CGSize(width: 200, height: 800), pointer: nil)
        XCTAssertEqual(geo.elements[0].rect.minX, 8 + 10, accuracy: 0.001)
        XCTAssertLessThan(geo.elements[0].rect.maxY, geo.elements[1].rect.minY)
    }

    func testHitTestingIncludesGapsAndPadding() {
        let geo = DockLayoutEngine.layout(elements: icons(3), metrics: metrics(), position: .bottom,
                                          container: container, pointer: nil)
        let first = geo.elements[0].rect
        XCTAssertEqual(geo.hit(CGPoint(x: first.maxX + 4, y: first.midY), spacing: 10)?.id, "i0")
        XCTAssertEqual(geo.hit(CGPoint(x: first.midX, y: geo.background.maxY - 2), spacing: 10)?.id, "i0")
        XCTAssertNil(geo.hit(CGPoint(x: 10, y: 10), spacing: 10))
    }

    func testDropTargetsDistinguishOntoAndBetween() {
        let geo = DockLayoutEngine.layout(elements: icons(3), metrics: metrics(), position: .bottom,
                                          container: container, pointer: nil)
        let second = geo.elements[1].rect
        XCTAssertEqual(geo.dropTarget(at: CGPoint(x: second.midX, y: second.midY)) { _ in true }, .onto("i1"))
        XCTAssertEqual(geo.dropTarget(at: CGPoint(x: second.minX + 3, y: second.midY)) { _ in true },
                       .insert(before: "i1"))
        XCTAssertEqual(geo.dropTarget(at: CGPoint(x: 990, y: second.midY)) { _ in true }, .insert(before: nil))
        XCTAssertEqual(geo.dropTarget(at: CGPoint(x: second.midX, y: second.midY)) { _ in false },
                       .insert(before: "i2"), "past the midpoint inserts after when onto isn't allowed")
    }

    func testCrowdedDockShrinksToFitScreen() {
        let geo = DockLayoutEngine.layout(elements: icons(40), metrics: metrics(), position: .bottom,
                                          container: container, pointer: nil)
        XCTAssertGreaterThanOrEqual(geo.background.minX, 7.5)
        XCTAssertLessThanOrEqual(geo.background.maxX, 1000 - 7.5)
        XCTAssertLessThan(geo.elements[0].rect.width, 50)
        XCTAssertEqual(geo.background.maxY, 200 - 8, accuracy: 0.001, "still anchored to the edge")
    }

    func testMagnificationNeverPushesAFullDockOffScreen() {
        let m = metrics(magnification: 2)
        let rest = DockLayoutEngine.layout(elements: icons(18), metrics: m, position: .bottom,
                                           container: container, pointer: nil)
        let p = CGPoint(x: rest.elements[2].rect.midX, y: rest.elements[2].rect.midY)
        let geo = DockLayoutEngine.layout(elements: icons(18), metrics: m, position: .bottom,
                                          container: container, pointer: p)
        XCTAssertGreaterThanOrEqual(geo.background.minX, -0.5)
        XCTAssertLessThanOrEqual(geo.background.maxX, 1000.5)
        XCTAssertGreaterThan(geo.elements[2].scale, 1, "still magnifies a little")
    }
}
