import Foundation

/// Shared observable used to signal the detail view to receive or refresh messages.
@Observable
final class EntityActionStore {

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

    // MARK: - Entity key helpers

    static func queueKey(_ name: String) -> String { "q:\(name)" }
    static func subscriptionKey(topic: String, sub: String) -> String { "s:\(topic)/\(sub)" }
}
