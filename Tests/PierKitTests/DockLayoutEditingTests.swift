import XCTest
@testable import PierKit

final class DockLayoutEditingTests: XCTestCase {
    private let safari = AppRef(bundleID: "com.apple.Safari", path: "/Applications/Safari.app", name: "Safari")
    private let mail = AppRef(bundleID: "com.apple.mail", path: "/System/Applications/Mail.app", name: "Mail")
    private let notes = AppRef(bundleID: "com.apple.Notes", path: "/System/Applications/Notes.app", name: "Notes")

    private func layout(_ apps: [AppRef]) -> DockLayout {
        DockLayout(main: apps.map { DockItem(.app($0)) }, trailing: [DockItem(.trash)])
    }

    func testPinningIsIdempotent() {
        let base = layout([safari])
        let once = base.pinning(mail)
        let twice = once.pinning(mail)
        XCTAssertEqual(once.main.count, 2)
        XCTAssertEqual(twice, once)
        XCTAssertEqual(base.main.count, 1, "original layout must not be mutated")
    }

    func testMovingReordersWithinSection() {
        let base = layout([safari, mail, notes])
        let moved = base.moving(base.main[2].id, to: .main, at: 0)
        XCTAssertEqual(moved.main.compactMap(\.appRef?.name), ["Notes", "Safari", "Mail"])
    }

    func testDroppingAppOntoAppMakesFolderInTargetSlot() throws {
        let base = layout([safari, mail, notes])
        let (result, folderID) = try XCTUnwrap(base.makingFolder(dropping: base.main[2].id, onto: base.main[0].id,
                                                                  name: "Stuff"))
        XCTAssertEqual(result.main.count, 2)
        XCTAssertEqual(result.main[0].id, folderID)
        XCTAssertEqual(result.main[0].folder?.apps.map(\.name), ["Safari", "Notes"])
        XCTAssertEqual(result.main[1].appRef?.name, "Mail")
    }

    func testCannotMakeFolderFromItself() {
        let base = layout([safari])
        XCTAssertNil(base.makingFolder(dropping: base.main[0].id, onto: base.main[0].id, name: "x"))
    }

    func testAddingRunningAppToFolderUnpinsItElsewhere() throws {
        let base = layout([safari, mail, notes])
        let (withFolder, folderID) = try XCTUnwrap(base.makingFolder(dropping: base.main[1].id,
                                                                      onto: base.main[0].id, name: "F"))
        let result = withFolder.addingApp(notes, toFolder: folderID)
        XCTAssertEqual(result.main.count, 1)
        XCTAssertEqual(result.main[0].folder?.apps.count, 3)
        XCTAssertTrue(result.isPinned(notes))
    }

    func testRemovingLastButOneAppCollapsesFolder() throws {
        let base = layout([safari, mail])
        let (withFolder, folderID) = try XCTUnwrap(base.makingFolder(dropping: base.main[1].id,
                                                                      onto: base.main[0].id, name: "F"))
        let result = withFolder.removingApp(mail, fromFolder: folderID, placeOutside: true)
        XCTAssertEqual(result.main.compactMap(\.appRef?.name), ["Safari", "Mail"])
        XCTAssertNil(result.main[0].folder)
        XCTAssertEqual(result.main[0].id, folderID, "collapsed tile keeps the slot's identity")
    }

    func testUnpinningRemovesFromFolders() throws {
        let base = layout([safari, mail, notes])
        let (withFolder, _) = try XCTUnwrap(base.makingFolder(dropping: base.main[1].id,
                                                               onto: base.main[0].id, name: "F"))
        let result = withFolder.unpinning(mail)
        XCTAssertFalse(result.isPinned(mail))
        XCTAssertEqual(result.main.first?.appRef?.name, "Safari", "one-app folder collapses to an app tile")
    }

    func testRenameIgnoresBlankNames() throws {
        let base = layout([safari, mail])
        let (withFolder, folderID) = try XCTUnwrap(base.makingFolder(dropping: base.main[1].id,
                                                                      onto: base.main[0].id, name: "Web"))
        XCTAssertEqual(withFolder.renamingFolder(folderID, to: "   ").main[0].folder?.name, "Web")
        XCTAssertEqual(withFolder.renamingFolder(folderID, to: " Daily ").main[0].folder?.name, "Daily")
    }

    func testSanitizeKeepsExactlyOneTrashAtEndAndDedupesWidgets() {
        let messy = DockLayout(
            main: [DockItem(.widget(.clock)), DockItem(.trash), DockItem(.widget(.clock)), DockItem(.app(safari))],
            trailing: [DockItem(.trash), DockItem(.stack(path: "/tmp"))])
        let clean = messy.sanitized()
        XCTAssertEqual(clean.main.count, 2)
        XCTAssertEqual(clean.trailing.last?.content, .trash)
        XCTAssertEqual(clean.allItems.filter { $0.content == .trash }.count, 1)
    }

    func testAppRefMatchesByBundleIDThenPath() {
        let moved = AppRef(bundleID: "com.apple.Safari", path: "/Volumes/X/Safari.app", name: "Safari")
        XCTAssertTrue(safari.matches(moved))
        let noID = AppRef(bundleID: nil, path: "/Applications/Safari.app/", name: "Safari")
        XCTAssertEqual(noID.path, "/Applications/Safari.app", "trailing slashes are normalized")
    }
}
