import XCTest
@testable import BusKit

final class EntityActionStoreTests: XCTestCase {
    func testEntityKeys() {
        XCTAssertEqual(EntityActionStore.queueKey("orders"), "q:orders")
        XCTAssertEqual(EntityActionStore.subscriptionKey(topic: "t", sub: "s"), "s:t/s")
    }

    func testRepeatedReceiveActionsAreDistinct() {
        let store = EntityActionStore()
        store.receive(entityKey: "q:a", isDLQ: false, count: 10)
        let first = store.pendingAction
        store.receive(entityKey: "q:a", isDLQ: false, count: 10)

        XCTAssertNotEqual(first, store.pendingAction)
        XCTAssertEqual(store.pendingAction?.entityKey, "q:a")
        XCTAssertEqual(store.pendingAction?.count, 10)
    }

    func testRefreshAndRulesRequests() {
        let store = EntityActionStore()
        store.requestRefresh(.subscription(topic: "t", sub: "s"))
        XCTAssertEqual(store.pendingRefresh?.target, .subscription(topic: "t", sub: "s"))

        store.requestRulesRefresh(topicName: "t", subscriptionName: "s")
        XCTAssertEqual(store.pendingRulesRefresh?.topicName, "t")
        XCTAssertEqual(store.pendingRulesRefresh?.subscriptionName, "s")

        store.focusRules(entityKey: "s:t/s")
        XCTAssertEqual(store.pendingFocusRules?.entityKey, "s:t/s")
    }
}
