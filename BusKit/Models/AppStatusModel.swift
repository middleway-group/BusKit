import Foundation

// MARK: - AppStatusModel

@available(macOS 15.0, *)
@Observable
final class AppStatusModel {
    /// Time the currently-visible message list was last loaded.
    var lastRefreshTime: Date? = nil
    /// Number of messages currently displayed in the active Messages/Deadletter tab.
    var visibleMessageCount: Int = 0
    /// Total number of messages reported for the active queue/subscription tab.
    /// Nil means the total is currently unknown, so the status bar should fall
    /// back to only showing the visible count.
    var totalMessageCount: Int64? = nil

    var messageCountStatusText: String? {
        guard visibleMessageCount > 0 else { return nil }

        let visibleCount = visibleMessageCount.formatted()
        if let totalMessageCount, totalMessageCount >= Int64(visibleMessageCount) {
            return "\(visibleCount) of \(totalMessageCount.formatted()) message\(totalMessageCount == 1 ? "" : "s") loaded"
        }

        return "\(visibleCount) message\(visibleMessageCount == 1 ? "" : "s")"
    }

    func clearMessageCount() {
        visibleMessageCount = 0
        totalMessageCount = nil
    }
}
