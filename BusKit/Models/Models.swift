import Foundation

enum MessageBusType: String, CaseIterable {
    case azureServiceBus = "Azure Service Bus"
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var displayName: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected"
        case .error(let e): return "Error: \(e)"
        }
    }

    var color: String {
        switch self {
        case .disconnected: return "gray"
        case .connecting:   return "orange"
        case .connected:    return "green"
        case .error:        return "red"
        }
    }
}

// MARK: - RBAC Access Level

/// Describes the level of access a user has on the connected Service Bus namespace
/// after verifying Azure role assignments.
enum RbacAccessLevel: Equatable {
    /// Auth via Connection String — RBAC check is not applicable.
    case notApplicable
    /// RBAC check is currently in progress.
    case checking
    /// User holds both Data Owner and Contributor (or Owner). Full access.
    case full
    /// User has Data Owner only. Message operations work; management-plane changes are restricted.
    case dataOnly
    /// User has Contributor only. Properties/management works; message operations are restricted.
    case managementOnly
    /// User has neither required role. Access denied.
    case denied
    /// The role-assignment API call failed or timed out.
    case checkFailed(String)

    /// Whether the user can perform data-plane operations (peek, receive, purge, resubmit).
    var hasDataAccess: Bool {
        switch self {
        case .full, .dataOnly, .notApplicable: return true
        default: return false
        }
    }

    /// Whether the user can perform management-plane operations (update TTL, entity properties).
    var hasManagementAccess: Bool {
        switch self {
        case .full, .managementOnly, .notApplicable: return true
        default: return false
        }
    }
}

// MARK: - Sidebar selection

enum SidebarSelection: Hashable {
    case queue(QueueItem)
    case subscription(SubscriptionItem)
}

// MARK: - Queue models

struct QueueItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let messageCount: Int64
    let deadLetterCount: Int64
}

struct QueueDetailsItem {
    let name: String
    let maxSizeMb: Int64
    let defaultMessageTtlSeconds: Int64
    let lockDurationSeconds: Int64
    let requiresDuplicateDetection: Bool
    let requiresSession: Bool
    let maxDeliveryCount: Int32
    let deadLetteringOnExpiration: Bool
    let status: String
    let createdAt: Date
    let updatedAt: Date
    let activeMessageCount: Int64
    let deadLetterCount: Int64
    let sizeBytes: Int64
    let forwardTo: String
    let autoDeleteOnIdleSeconds: Int64
}

// MARK: - Subscription models

struct SubscriptionDetailsItem {
    let topicName: String
    let name: String
    let defaultMessageTtlSeconds: Int64
    let lockDurationSeconds: Int64
    let maxDeliveryCount: Int32
    let deadLetteringOnExpiration: Bool
    let deadLetteringOnFilterEvaluation: Bool
    let status: String
    let createdAt: Date
    let updatedAt: Date
    let activeMessageCount: Int64
    let deadLetterCount: Int64
    let forwardTo: String
    let autoDeleteOnIdleSeconds: Int64
}

struct TopicItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
}

struct SubscriptionItem: Identifiable, Hashable {
    let id = UUID()
    let topicName: String
    let name: String
    let activeMessageCount: Int64
    let deadLetterCount: Int64
}

struct RuleItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let filter: String
}

struct MessageItem: Identifiable {
    let id: String          // messageId
    let body: String
    let contentType: String
    let enqueuedTime: Date
    let properties: [String: String]
    // System properties
    let sequenceNumber: Int64
    let deliveryCount: Int32
    let expiresAt: Date
    let subject: String
    let correlationId: String
    let replyTo: String
    let toAddress: String
    let sessionId: String
    let partitionKey: String
}
