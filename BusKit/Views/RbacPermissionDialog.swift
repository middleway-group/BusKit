import SwiftUI

// MARK: - RbacPermissionDialog

/// Presented after Azure AD connection to inform the user about their RBAC access level.
///
/// - **Partial access** (`.dataOnly` / `.managementOnly`): dismissable warning sheet.
/// - **Access denied** (`.denied`): non-dismissable sheet with Retry / Switch auth / Quit.
/// - **Check failed** (`.checkFailed`): sheet allowing Retry or proceeding at own risk.
@available(macOS 15.0, *)
struct RbacPermissionDialog: View {
    @Environment(GRPCManager.self) var grpc
    let accessLevel: RbacAccessLevel
    let onDismiss: () -> Void
    let onRetry: () -> Void
    let onSwitchToConnectionString: () -> Void

    var body: some View {
        switch accessLevel {
        case .dataOnly:
            PartialAccessSheet(
                presentRole: .dataOwner,
                missingRole: .contributor,
                onDismiss: onDismiss
            )
        case .managementOnly:
            PartialAccessSheet(
                presentRole: .contributor,
                missingRole: .dataOwner,
                onDismiss: onDismiss
            )
        case .denied:
            AccessDeniedSheet(
                onRetry: onRetry,
                onSwitchToConnectionString: onSwitchToConnectionString
            )
        case .checkFailed(let message):
            CheckFailedSheet(
                errorMessage: message,
                onRetry: onRetry,
                onDismiss: onDismiss
            )
        default:
            EmptyView()
        }
    }
}

// MARK: - Role descriptions

private enum RequiredRole {
    case dataOwner
    case contributor

    var displayName: String {
        switch self {
        case .dataOwner:   return "Azure Service Bus Data Owner"
        case .contributor: return "Contributor"
        }
    }

    var roleId: String {
        switch self {
        case .dataOwner:   return "090c5cfd-751d-490a-894a-3ce6f1109419"
        case .contributor: return "b24988ac-6180-42a0-ab88-20f7382dd24c"
        }
    }

    var affectedFeatures: [String] {
        switch self {
        case .dataOwner:
            return [
                "Peeking and receiving messages",
                "Dead-letter queue management",
                "Purging and resubmitting messages",
            ]
        case .contributor:
            return [
                "Changing message TTL",
                "Modifying entity properties",
                "Management-plane configuration",
            ]
        }
    }
}

// MARK: - Partial Access Sheet

@available(macOS 15.0, *)
private struct PartialAccessSheet: View {
    let presentRole: RequiredRole
    let missingRole: RequiredRole
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // Header
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Limited Access")
                        .font(.title3).fontWeight(.semibold)
                    Text("Some features are unavailable due to missing role assignments.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // Role status
            VStack(alignment: .leading, spacing: 8) {
                RoleStatusRow(role: presentRole, isPresent: true)
                RoleStatusRow(role: missingRole, isPresent: false)
            }

            Divider()

            // Disabled features
            VStack(alignment: .leading, spacing: 6) {
                Text("Disabled features:")
                    .font(.subheadline).fontWeight(.medium)
                ForEach(missingRole.affectedFeatures, id: \.self) { feature in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .padding(.top, 2)
                        Text(feature)
                            .font(.callout)
                    }
                }
            }

            Divider()

            // Admin recommendation
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "person.badge.key")
                    .foregroundStyle(.blue)
                    .padding(.top, 1)
                Text("Contact your Azure administrator to assign the **\(missingRole.displayName)** role on this Service Bus namespace.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Actions
            HStack {
                CopyRoleNameButton(role: missingRole)
                Spacer()
                Button("Continue with Limited Access") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

// MARK: - Access Denied Sheet

@available(macOS 15.0, *)
private struct AccessDeniedSheet: View {
    let onRetry: () -> Void
    let onSwitchToConnectionString: () -> Void

    private let allRoles: [RequiredRole] = [.dataOwner, .contributor]
    private let allRoleNames = "Azure Service Bus Data Owner, Contributor"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // Header
            HStack(spacing: 12) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.title)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Access Denied")
                        .font(.title3).fontWeight(.semibold)
                    Text("You do not have the required permissions on this Service Bus namespace.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // Role status
            VStack(alignment: .leading, spacing: 8) {
                ForEach(allRoles, id: \.roleId) { role in
                    RoleStatusRow(role: role, isPresent: false)
                }
            }

            Divider()

            // Required permissions table
            VStack(alignment: .leading, spacing: 6) {
                Text("Required role assignments (at least one of each):")
                    .font(.subheadline).fontWeight(.medium)
                ForEach(allRoles, id: \.roleId) { role in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(role.displayName).font(.callout).fontWeight(.medium)
                        Text("Role ID: \(role.roleId)")
                            .font(.caption2).foregroundStyle(.secondary).monospaced()
                    }
                    .padding(.leading, 8)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "person.badge.key")
                    .foregroundStyle(.blue)
                    .padding(.top, 1)
                Text("Contact your Azure administrator to assign both the **Azure Service Bus Data Owner** and **Contributor** roles on this namespace.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Actions
            HStack(spacing: 10) {
                Button("Copy Role Names") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(allRoleNames, forType: .string)
                }
                .foregroundStyle(.secondary)

                Spacer()

                Button("Use Connection String") {
                    onSwitchToConnectionString()
                }

                Button("Retry") { onRetry() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)

                Button("Quit") {
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

// MARK: - Check Failed Sheet

@available(macOS 15.0, *)
private struct CheckFailedSheet: View {
    let errorMessage: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permission Check Failed")
                        .font(.title3).fontWeight(.semibold)
                    Text("Role assignments could not be verified.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Error details:").font(.subheadline).fontWeight(.medium)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            Divider()

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                Text("If you proceed without verification, access may fail at runtime if the required roles are not assigned.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Proceed at My Own Risk") { onDismiss() }
                    .foregroundStyle(.secondary)
                Button("Retry") { onRetry() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

// MARK: - Shared sub-views

private struct RoleStatusRow: View {
    let role: RequiredRole
    let isPresent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isPresent ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isPresent ? .green : .red)
            VStack(alignment: .leading, spacing: 1) {
                Text(role.displayName).font(.callout)
                Text("Role ID: \(role.roleId)")
                    .font(.caption2).foregroundStyle(.secondary).monospaced()
            }
        }
    }
}

private struct CopyRoleNameButton: View {
    let role: RequiredRole
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied!" : "Copy Missing Role Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(role.displayName, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
        .foregroundStyle(.secondary)
        .animation(.default, value: copied)
    }
}
