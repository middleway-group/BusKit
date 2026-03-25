import Foundation

/// Shared observable used to signal the detail view to receive or refresh messages.
@Observable
final class EntityActionStore {

    // MARK: - Receive action

    struct ReceiveAction: Equatable {
        /// Unique nonce so observers react even when entity/isDLQ/count repeat.
        let nonce = UUID()
        let entityKey: String
        let isDLQ: Bool
        let count: Int32

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.nonce == rhs.nonce }
    }

    var pendingAction: ReceiveAction?

    func receive(entityKey: String, isDLQ: Bool, count: Int32) {
        pendingAction = ReceiveAction(entityKey: entityKey, isDLQ: isDLQ, count: count)
    }

    // MARK: - Count refresh request

    /// The entity whose sidebar badge counts should be refreshed.
    enum RefreshTarget: Equatable {
        case queue(String)
        case subscription(topic: String, sub: String)
    }

    struct RefreshRequest: Equatable {
        let nonce = UUID()
        let target: RefreshTarget
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.nonce == rhs.nonce }
    }

    var pendingRefresh: RefreshRequest?

    func requestRefresh(_ target: RefreshTarget) {
        pendingRefresh = RefreshRequest(target: target)
    }

    // MARK: - Entity key helpers

    static func queueKey(_ name: String) -> String { "q:\(name)" }
    static func subscriptionKey(topic: String, sub: String) -> String { "s:\(topic)/\(sub)" }
}
