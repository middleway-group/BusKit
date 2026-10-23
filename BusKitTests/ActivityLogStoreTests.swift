import XCTest
@testable import BusKit

@MainActor
final class ActivityLogStoreTests: XCTestCase {
    func testLogInsertsNewestFirstAndCountsResults() {
        let store = ActivityLogStore()
        store.log(action: .save, messageId: "a", result: .success("ok"), showToast: false)
        store.log(action: .delete, messageId: "b", result: .warning("w"), showToast: false)
        store.log(action: .resubmit, messageId: "c", result: .failure("boom"), showToast: false)

        XCTAssertEqual(store.entries.map(\.target), ["c", "b", "a"])
        XCTAssertEqual(store.errorCount, 1)
        XCTAssertEqual(store.warningCount, 1)
    }

    func testErrorOpensLogPanelButSuccessDoesNot() {
        let store = ActivityLogStore()
        store.log(action: .save, messageId: "a", result: .success("ok"), showToast: false)
        XCTAssertFalse(store.isLogVisible)

        store.log(action: .save, messageId: "b", result: .failure("boom"), showToast: false)
        XCTAssertTrue(store.isLogVisible)
    }

    func testShowToastFlagControlsToastCreation() {
        let store = ActivityLogStore()
        store.log(action: .delete, messageId: "a", result: .failure("x"), showToast: false)
        XCTAssertTrue(store.toasts.isEmpty)

        store.log(action: .delete, messageId: "b", result: .failure("x"))
        XCTAssertEqual(store.toasts.count, 1)
        XCTAssertEqual(store.toasts.first?.entryId, store.entries.first?.id)
    }

    func testDismissToastAndClearLog() {
        let store = ActivityLogStore()
        store.log(action: .delete, messageId: "a", result: .failure("x"))
        store.dismissToast(id: store.toasts[0].id)
        XCTAssertTrue(store.toasts.isEmpty)

        store.clearLog()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testShowInLogFallsBackToLatestError() {
        let store = ActivityLogStore()
        store.log(action: .save, messageId: "a", result: .failure("x"), showToast: false)
        store.log(action: .save, messageId: "b", result: .success("ok"), showToast: false)

        store.showInLog(entryId: nil)
        XCTAssertEqual(store.focusedEntryId, store.entries.last?.id)

        let explicit = store.entries[0].id
        store.showInLog(entryId: explicit)
        XCTAssertEqual(store.focusedEntryId, explicit)
    }
}
