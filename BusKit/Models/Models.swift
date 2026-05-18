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

// MARK: - RBAC Access Tier (5-tier model)

/// Granular 5-tier classification of a user's effective RBAC permissions on a
/// Service Bus namespace. Mirrors the `AccessTier` proto enum.
enum AccessTier: Int32, Equatable, Comparable, CaseIterable {
    case noAccess        = 0
    case readOnly        = 1
    case messageReader   = 2
    case messageOperator = 3
    case fullAccess      = 4

    static func < (lhs: AccessTier, rhs: AccessTier) -> Bool { lhs.rawValue < rhs.rawValue }

    var displayName: String {
        switch self {
        case .noAccess:        return "No Access"
        case .readOnly:        return "Read-Only Observer"
        case .messageReader:   return "Message Reader"
        case .messageOperator: return "Message Operator"
        case .fullAccess:      return "Full Access"
        }
    }

    var shortDescription: String {
        switch self {
        case .noAccess:        return "You have no permissions on this namespace."
        case .readOnly:        return "Browse entities and view properties only."
        case .messageReader:   return "Browse entities, view properties, and peek messages."
        case .messageOperator: return "Inspect, purge, and resubmit messages. Cannot create resources."
        case .fullAccess:      return "Full access to all features."
        }
    }

    var badgeColor: String {
        switch self {
        case .noAccess:        return "red"
        case .readOnly:        return "gray"
        case .messageReader:   return "blue"
        case .messageOperator: return "orange"
        case .fullAccess:      return "green"
        }
    }

    var badgeSystemImage: String {
        switch self {
        case .noAccess:        return "xmark.shield.fill"
        case .readOnly:        return "eye.fill"
        case .messageReader:   return "tray.fill"
        case .messageOperator: return "gearshape.2.fill"
        case .fullAccess:      return "checkmark.shield.fill"
        }
    }

    init(from grpcTier: Buskit_AccessTier) {
        self = AccessTier(rawValue: Int32(grpcTier.rawValue)) ?? .noAccess
    }
}

// MARK: - Capability Map

/// Per-action permission flags derived from the server-side tier evaluation.
/// Drives dynamic enable/disable of all action buttons in the UI.
struct CapabilityMap: Equatable {
    let browseEntities:  Bool
    let viewProperties:  Bool
    let peekFetch:       Bool
    let purge:           Bool
    let resubmitDlq:     Bool
    let createResources: Bool
    let manageFilters:   Bool

    static let none = CapabilityMap(
        browseEntities: false, viewProperties: false, peekFetch: false,
        purge: false, resubmitDlq: false, createResources: false, manageFilters: false)

    static let all = CapabilityMap(
        browseEntities: true, viewProperties: true, peekFetch: true,
        purge: true, resubmitDlq: true, createResources: true, manageFilters: true)

    init(browseEntities: Bool, viewProperties: Bool, peekFetch: Bool,
         purge: Bool, resubmitDlq: Bool, createResources: Bool, manageFilters: Bool) {
        self.browseEntities  = browseEntities
        self.viewProperties  = viewProperties
        self.peekFetch       = peekFetch
        self.purge           = purge
        self.resubmitDlq     = resubmitDlq
        self.createResources = createResources
        self.manageFilters   = manageFilters
    }

    init(from reply: Buskit_CheckRbacPermissionsReply) {
        self.browseEntities  = reply.canBrowseEntities
        self.viewProperties  = reply.canViewProperties
        self.peekFetch       = reply.canPeekFetch
        self.purge           = reply.canPurge
        self.resubmitDlq     = reply.canResubmitDlq
        self.createResources = reply.canCreateResources
        self.manageFilters   = reply.canManageFilters
    }

    /// Returns a tooltip string explaining why a capability is unavailable.
    func disabledReason(for capability: Capability) -> String? {
        guard !self[capability] else { return nil }
        return capability.requiredPermission
    }

    subscript(capability: Capability) -> Bool {
        switch capability {
        case .browseEntities:  return browseEntities
        case .viewProperties:  return viewProperties
        case .peekFetch:       return peekFetch
        case .purge:           return purge
        case .resubmitDlq:     return resubmitDlq
        case .createResources: return createResources
        case .manageFilters:   return manageFilters
        }
    }

    enum Capability: CaseIterable {
        case browseEntities
        case viewProperties
        case peekFetch
        case purge
        case resubmitDlq
        case createResources
        case manageFilters

        var displayName: String {
            switch self {
            case .browseEntities:  return "Browse Queues, Topics & Subscriptions"
            case .viewProperties:  return "View Entity Properties"
            case .peekFetch:       return "Peek & Fetch Messages"
            case .purge:           return "Purge Messages"
            case .resubmitDlq:     return "Resubmit Dead-Letter Messages"
            case .createResources: return "Create Queues, Topics & Subscriptions"
            case .manageFilters:   return "Manage Subscription Filter Rules"
            }
        }

        var requiredPermission: String {
            switch self {
            case .browseEntities:  return "Requires: Reader role (control plane read)"
            case .viewProperties:  return "Requires: Reader role (control plane read)"
            case .peekFetch:       return "Requires: Azure Service Bus Data Receiver role"
            case .purge:           return "Requires: Azure Service Bus Data Sender role (+ Receiver)"
            case .resubmitDlq:     return "Requires: Azure Service Bus Data Sender + Receiver roles"
            case .createResources: return "Requires: Contributor role (control plane write)"
            case .manageFilters:   return "Requires: Contributor role (subscriptions/rules/write)"
            }
        }
    }
}

// MARK: - Upgrade Recommendation

struct UpgradeRecommendation: Equatable {
    let roleName:         String
    let roleDefinitionId: String
    let targetTier:       AccessTier
    let description:      String

    init?(from reply: Buskit_CheckRbacPermissionsReply) {
        guard !reply.recommendedRoleName.isEmpty else { return nil }
        self.roleName         = reply.recommendedRoleName
        self.roleDefinitionId = reply.recommendedRoleID
        self.targetTier       = AccessTier(from: reply.recommendedTargetTier)
        self.description      = reply.recommendedRoleDescription
    }
}

// MARK: - RBAC Access Level (legacy — kept for existing dialog compatibility)

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
    case rulesGroup(SubscriptionItem)
    case rule(RuleItem, SubscriptionItem)
}

// MARK: - Queue models

struct QueueItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let messageCount: Int64
    let deadLetterCount: Int64
    let status: String
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
    let id = UUID()
    let messageId: String
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
