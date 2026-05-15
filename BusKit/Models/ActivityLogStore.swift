import Foundation
import SwiftUI

// MARK: - ActionKind

enum ActionKind: String, CaseIterable {
    case delete      = "Delete"
    case save        = "Save"
    case resubmit    = "Resubmit"
    case repair      = "Repair"
    case editRule    = "Edit Rule"
    case deleteRule  = "Delete Rule"
    case updateTtl   = "Update TTL"
    case createQueue = "Create Queue"
    case deleteQueue = "Delete Queue"
    case createTopic = "Create Topic"
    case deleteTopic = "Delete Topic"

    var systemImage: String {
        switch self {
        case .delete:      return "trash"
        case .save:        return "square.and.arrow.down"
        case .resubmit:    return "arrow.uturn.right"
        case .repair:      return "wrench.and.screwdriver"
        case .editRule:    return "pencil"
        case .deleteRule:  return "line.3.horizontal.decrease.circle.fill"
        case .updateTtl:   return "clock.arrow.2.circlepath"
        case .createQueue: return "tray.and.arrow.down"
        case .deleteQueue: return "tray.xmark"
        case .createTopic: return "bubble.left.and.bubble.right"
        case .deleteTopic: return "bubble.left.and.bubble.right.fill"
        }
    }
}

// MARK: - ActionResult

enum ActionResult {
    case success(String)
    case warning(String)
    case failure(String)

    var label: String {
        switch self {
        case .success(let m): return m
        case .warning(let m): return m
        case .failure(let m): return m
        }
    }

    var isError:   Bool { if case .failure = self { return true }; return false }
    var isWarning: Bool { if case .warning = self { return true }; return false }
    var isSuccess: Bool { if case .success = self { return true }; return false }
}

// MARK: - ActivityLogEntry

struct ActivityLogEntry: Identifiable {
    let id        = UUID()
    let timestamp : Date
    let action    : ActionKind
    let target    : String   // message ID (or other target identifier)
    let result    : ActionResult
    let hint      : String?  // optional diagnostic hint shown under error rows

    init(action: ActionKind, target: String, result: ActionResult, hint: String? = nil) {
        self.timestamp = Date()
        self.action    = action
        self.target    = target
        self.result    = result
        self.hint      = hint
    }
}

// MARK: - ToastItem

struct ToastItem: Identifiable {
    let id        = UUID()
    let action    : String
    let messageId : String
    let timestamp : Date
    let result    : ActionResult
    let details   : String?

    init(action: String, messageId: String, result: ActionResult, details: String? = nil) {
        self.action    = action
        self.messageId = messageId
        self.timestamp = Date()
        self.result    = result
        self.details   = details
    }
}

// MARK: - ActivityLogStore

@available(macOS 15.0, *)
@Observable
final class ActivityLogStore {

    // MARK: State

    var entries     : [ActivityLogEntry] = []
    var toasts      : [ToastItem]        = []
    var isLogVisible: Bool               = false

    // MARK: Computed

    var errorCount  : Int { entries.filter { $0.result.isError   }.count }
    var warningCount: Int { entries.filter { $0.result.isWarning }.count }

    // MARK: - Public API

    /// Records a user action in the log and surfaces a toast notification.
    @MainActor
    func log(action: ActionKind, messageId: String, result: ActionResult, hint: String? = nil) {
        let entry = ActivityLogEntry(action: action, target: messageId, result: result, hint: hint)
        entries.insert(entry, at: 0)

        let toast = ToastItem(action: action.rawValue, messageId: messageId, result: result, details: hint)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            toasts.append(toast)
        }

        // Auto-dismiss success toasts after 3 s; errors stay until manually closed.
        if result.isSuccess {
            let toastId = toast.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.dismissToast(id: toastId)
            }
        }

        // Auto-open the log panel whenever a new error is recorded.
        if result.isError {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isLogVisible = true
            }
        }
    }

    @MainActor
    func dismissToast(id: UUID) {
        withAnimation(.easeOut(duration: 0.25)) {
            toasts.removeAll { $0.id == id }
        }
    }

    func clearLog() {
        entries.removeAll()
    }

    func toggleLog() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isLogVisible.toggle()
        }
    }
}
