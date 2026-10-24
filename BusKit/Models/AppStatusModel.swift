import Foundation

// MARK: - AppStatusModel

@available(macOS 15.0, *)
@Observable
final class AppStatusModel {
    /// Time the currently-visible message list was last loaded.
    var lastRefreshTime: Date? = nil

    /// Changes every time the auto-refresh timer fires; views observe it to reload.
    var autoRefreshTick = UUID()

    private var activeRefreshes = 0
    var isRefreshing: Bool { activeRefreshes > 0 }

    /// Runs `work` while flagging the app as refreshing (drives the status bar label).
    func trackRefresh(_ work: () async -> Void) async {
        activeRefreshes += 1
        defer { activeRefreshes -= 1 }
        await work()
    }
}
