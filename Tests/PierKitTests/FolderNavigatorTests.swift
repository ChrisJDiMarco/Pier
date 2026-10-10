import XCTest
@testable import PierKit

final class FolderNavigatorTests: XCTestCase {
    private func app(_ name: String) -> AppRef { AppRef(bundleID: "x.\(name)", path: "/Applications/\(name).app", name: name) }

    func testArrowMovesStartAtFirstAndStopAtEdges() {
        XCTAssertEqual(FolderNavigator.move(nil, by: 1, count: 6), 0)
        XCTAssertEqual(FolderNavigator.move(0, by: -1, count: 6), 0, "no wrap at the start")
        XCTAssertEqual(FolderNavigator.move(5, by: 1, count: 6), 5, "no wrap at the end")
        XCTAssertEqual(FolderNavigator.move(1, by: 4, count: 6), 5, "down a row")
        XCTAssertEqual(FolderNavigator.move(3, by: 4, count: 6), 3, "no row below: stay")
        XCTAssertNil(FolderNavigator.move(nil, by: 1, count: 0))
    }

    func testFilterRanksPrefixThenWordStartThenContains() {
        let apps = [app("Visual Studio Code"), app("Codex"), app("Xcode"), app("Safari")]
        XCTAssertEqual(FolderNavigator.filter(apps, query: "code").map(\.name), ["Codex", "Visual Studio Code", "Xcode"])
        XCTAssertEqual(FolderNavigator.filter(apps, query: "").count, 4)
        XCTAssertTrue(FolderNavigator.filter(apps, query: "zzz").isEmpty)
    }
}
