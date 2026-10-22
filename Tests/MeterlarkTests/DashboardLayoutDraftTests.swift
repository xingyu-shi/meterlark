import XCTest
@testable import MeterlarkApp

@MainActor
final class DashboardLayoutDraftTests: XCTestCase {
    private let order = ["builtIn.summary", "builtIn.budget", "builtIn.daily"]

    func testRemovingAndRestoringKeepsPositionAndColumnSettings() {
        let draft = DashboardLayoutDraft(
            layout: DashboardLayout(componentOrder: order, componentColumns: [order[0]: 3]),
            popoverHeight: 800
        )
        draft.setVisible(false, componentID: order[0])
        draft.setVisible(false, componentID: order[0])
        XCTAssertEqual(draft.visibleComponentIDs, Array(order.dropFirst()))
        XCTAssertEqual(draft.layout.hiddenComponentIDs, [order[0]])
        draft.setVisible(true, componentID: order[0])
        XCTAssertEqual(draft.visibleComponentIDs, order)
        XCTAssertEqual(draft.layout.componentColumns[order[0]], 3)
    }

    func testDraggingMovesAcrossMultipleComponentsInBothDirections() {
        let draft = DashboardLayoutDraft(layout: DashboardLayout(componentOrder: order), popoverHeight: 800)
        XCTAssertTrue(draft.move(order[0], to: order[2]))
        XCTAssertEqual(draft.layout.componentOrder, [order[1], order[2], order[0]])
        XCTAssertTrue(draft.move(order[0], to: order[1]))
        XCTAssertEqual(draft.layout.componentOrder, order)
    }

    func testPreviewMovementSkipsHiddenComponents() {
        let draft = DashboardLayoutDraft(
            layout: DashboardLayout(componentOrder: order, hiddenComponentIDs: [order[1]]),
            popoverHeight: 800
        )
        draft.moveVisible(order[0], offset: 1)
        XCTAssertEqual(draft.visibleComponentIDs, [order[2], order[0]])
        XCTAssertEqual(draft.layout.hiddenComponentIDs, [order[1]])
        XCTAssertEqual(Set(draft.layout.componentOrder), Set(order))
        draft.moveVisible(order[0], offset: -1)
        XCTAssertEqual(draft.visibleComponentIDs, [order[0], order[2]])
    }

    func testInvalidAndBoundaryMovesLeaveDraftUnchanged() {
        let layout = DashboardLayout(componentOrder: order)
        let draft = DashboardLayoutDraft(layout: layout, popoverHeight: 800)
        XCTAssertFalse(draft.move("missing", to: order[0]))
        XCTAssertFalse(draft.move(order[0], to: "missing"))
        XCTAssertFalse(draft.move(order[0], to: order[0]))
        draft.moveVisible(order[0], offset: -1)
        draft.moveVisible(order[2], offset: 1)
        draft.setVisible(false, componentID: "missing")
        XCTAssertEqual(draft.layout, layout)
    }

    func testPreviewEditsDoNotChangeSavedLayoutUntilExplicitSave() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DashboardLayoutStore(baseURL: folder)
        let saved = DashboardLayout(componentOrder: order)
        try store.save(saved)
        let draft = DashboardLayoutDraft(layout: store.loadOrDefault(), popoverHeight: 800)
        draft.setVisible(false, componentID: order[1])
        draft.move(order[2], to: order[0])
        XCTAssertEqual(try store.load(), saved)
        XCTAssertNotEqual(draft.layout, saved)
        try store.save(draft.layout)
        XCTAssertEqual(try store.load(), draft.layout)
    }
}
