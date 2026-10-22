import XCTest
@testable import MeterlarkApp

@MainActor
final class DashboardPreviewDragTests: XCTestCase {
    private let order = ["builtIn.summary", "builtIn.budget", "builtIn.daily"]

    private func makeDrag() -> DashboardPreviewDragState {
        let drag = DashboardPreviewDragState()
        drag.frames = [
            order[0]: CGRect(x: 0, y: 0, width: 100, height: 100),
            order[1]: CGRect(x: 0, y: 120, width: 100, height: 200),
            order[2]: CGRect(x: 0, y: 340, width: 100, height: 100)
        ]
        return drag
    }

    func testCrossingComponentMidpointReordersBeforeReleaseAndKeepsCardUnderPointer() {
        let draft = DashboardLayoutDraft(layout: DashboardLayout(componentOrder: order), popoverHeight: 800)
        let drag = makeDrag()
        drag.update(componentID: order[0], start: CGPoint(x: 20, y: 50),
                    location: CGPoint(x: 20, y: 230), draft: draft)
        XCTAssertEqual(draft.layout.componentOrder, [order[1], order[0], order[2]])
        XCTAssertEqual(drag.draggingID, order[0])

        drag.frames[order[0]] = CGRect(x: 0, y: 220, width: 100, height: 100)
        XCTAssertEqual(220 + drag.offset(for: order[0]), 180)
        drag.end(draft: draft)
        XCTAssertNil(drag.draggingID)
        XCTAssertEqual(drag.offset(for: order[0]), 0)
        XCTAssertEqual(draft.layout.componentOrder, [order[1], order[0], order[2]])
    }

    func testShortMovementDoesNotReorderUntilMidpointIsCrossed() {
        let draft = DashboardLayoutDraft(layout: DashboardLayout(componentOrder: order), popoverHeight: 800)
        let drag = makeDrag()
        drag.update(componentID: order[0], start: CGPoint(x: 30, y: 50),
                    location: CGPoint(x: 30, y: 210), draft: draft)
        XCTAssertEqual(draft.layout.componentOrder, order)
    }

    func testFastDragCrossesMultipleComponentsAndCancellationRestoresOrder() {
        let draft = DashboardLayoutDraft(
            layout: DashboardLayout(componentOrder: order, hiddenComponentIDs: [order[1]], componentColumns: [order[0]: 2]),
            popoverHeight: 800
        )
        let drag = makeDrag()
        drag.update(componentID: order[0], start: CGPoint(x: 20, y: 50),
                    location: CGPoint(x: 20, y: 450), draft: draft)
        XCTAssertEqual(draft.visibleComponentIDs, [order[2], order[0]])
        draft.layout.componentOrder.append("plugin.new")
        drag.end(draft: draft, cancelled: true)
        XCTAssertEqual(draft.layout.componentOrder, order + ["plugin.new"])
        XCTAssertEqual(draft.layout.hiddenComponentIDs, [order[1]])
        XCTAssertEqual(draft.layout.componentColumns[order[0]], 2)
    }

    func testUpwardDragReordersLiveAndUnmeasuredComponentsCannotStartDrag() {
        let draft = DashboardLayoutDraft(layout: DashboardLayout(componentOrder: order), popoverHeight: 800)
        let drag = makeDrag()
        drag.update(componentID: "missing", start: .zero, location: .zero, draft: draft)
        XCTAssertNil(drag.draggingID)
        drag.update(componentID: order[2], start: CGPoint(x: 20, y: 390),
                    location: CGPoint(x: 20, y: 20), draft: draft)
        XCTAssertEqual(draft.layout.componentOrder, [order[2], order[0], order[1]])
    }
}
