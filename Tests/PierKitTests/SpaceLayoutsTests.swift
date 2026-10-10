import XCTest
@testable import PierKit

final class SpaceLayoutsTests: XCTestCase {
    private let a = AppRef(bundleID: "a", path: "/Applications/A.app", name: "A")
    private let b = AppRef(bundleID: "b", path: "/Applications/B.app", name: "B")

    func testNewDesktopsShowTheMainDockUntilEdited() {
        let main = DockLayout.empty.pinning(a)
        var state = SpaceLayouts(base: main)
        XCTAssertEqual(state.layout(for: "desk-2"), main)
        state = state.storing(main, for: "desk-2")
        XCTAssertEqual(state.customizedCount, 0, "an untouched copy isn't stored")
        state = state.storing(main.pinning(b), for: "desk-2")
        XCTAssertEqual(state.customizedCount, 1)
        XCTAssertTrue(state.layout(for: "desk-2").isPinned(b))
        XCTAssertFalse(state.layout(for: "desk-3").isPinned(b), "other desktops keep the main dock")
        XCTAssertFalse(state.base.isPinned(b), "editing a desktop never changes the main dock")
    }

    func testTurningOffRestoresMainDockAndResetForgets() {
        let main = DockLayout.empty.pinning(a)
        let state = SpaceLayouts(base: main).storing(main.pinning(b), for: "desk-2")
        XCTAssertEqual(state.layout(for: nil), main)
        XCTAssertEqual(state.resetting("desk-2").layout(for: "desk-2"), main)
    }

    func testParsesCurrentDesktopFromWindowServerDictionary() {
        let display: [String: Any] = [
            "Current Space": ["uuid": "U2", "ManagedSpaceID": 7, "type": 0],
            "Spaces": [["uuid": "U1", "type": 0], ["uuid": "FS", "type": 4], ["uuid": "U2", "type": 0]],
        ]
        XCTAssertEqual(SpaceService.parse(display: display), SpaceInfo(key: "U2", name: "Desktop 2"))
        let fullScreen: [String: Any] = ["Current Space": ["uuid": "FS", "type": 4], "Spaces": []]
        XCTAssertNil(SpaceService.parse(display: fullScreen))
        let noUUID: [String: Any] = [
            "Current Space": ["uuid": "", "ManagedSpaceID": 3, "type": 0],
            "Spaces": [["uuid": "", "ManagedSpaceID": 3, "type": 0]],
        ]
        XCTAssertEqual(SpaceService.parse(display: noUUID)?.key, "desktop-1")
    }
}
