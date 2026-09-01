import Foundation

// MARK: - AppStatusModel

@available(macOS 15.0, *)
@Observable
final class AppStatusModel {
    /// Time the currently-visible message list was last loaded.
    var lastRefreshTime: Date? = nil
}
