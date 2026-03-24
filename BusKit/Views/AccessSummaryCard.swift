import SwiftUI

// MARK: - AccessSummaryCard

/// Displays the user's current RBAC access tier, a per-capability checklist,
/// an upgrade recommendation, and a re-evaluate button.
///
/// Designed for all 5 standard tiers (0–4) plus the Partial Access variant.
@available(macOS 15.0, *)
struct AccessSummaryCard: View {
    @Environment(GRPCManager.self) var grpc

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TierHeaderSection(
                tier: grpc.accessTier,
                isPartial: grpc.isPartialAccess,
                tierLabel: grpc.accessTier.displayName,
                description: grpc.accessTier.shortDescription
            )

            Divider().padding(.vertical, 12)

            CapabilityChecklistSection(capabilityMap: grpc.capabilityMap)

            if let rec = grpc.upgradeRecommendation {
                Divider().padding(.vertical, 12)
                UpgradeRecommendationSection(recommendation: rec)
            }

            Divider().padding(.vertical, 12)

            MetadataFooter(
                evaluatedAt: grpc.rbacEvaluatedAt,
                onReEvaluate: { grpc.refreshRbacPermissions() }
            )
        }
        .padding(20)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .frame(minWidth: 400, maxWidth: 520)
    }
}

// MARK: - Tier Header

@available(macOS 15.0, *)
private struct TierHeaderSection: View {
    let tier: AccessTier
    let isPartial: Bool
    let tierLabel: String
    let description: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: tier.badgeSystemImage)
                .font(.system(size: 28))
                .foregroundStyle(tierColor)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(tierLabel)
                        .font(.headline)
                    if isPartial {
                        Text("Partial Access")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.85))
                            .clipShape(Capsule())
                    }
                }
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tierColor: Color {
        switch tier {
        case .noAccess:        return .red
        case .readOnly:        return .secondary
        case .messageReader:   return .blue
        case .messageOperator: return .orange
        case .fullAccess:      return .green
        }
    }
}

// MARK: - Capability Checklist

@available(macOS 15.0, *)
private struct CapabilityChecklistSection: View {
    let capabilityMap: CapabilityMap

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Capabilities")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            ForEach(CapabilityMap.Capability.allCases, id: \.self) { cap in
                let allowed = capabilityMap[cap]
                HStack(spacing: 8) {
                    Image(systemName: allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(allowed ? .green : .red)
                        .font(.body)

                    Text(cap.displayName)
                        .font(.callout)
                        .foregroundStyle(allowed ? .primary : .secondary)

                    Spacer()

                    if !allowed {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(cap.requiredPermission)
                    }
                }
            }
        }
    }
}

// MARK: - Upgrade Recommendation

@available(macOS 15.0, *)
private struct UpgradeRecommendationSection: View {
    let recommendation: UpgradeRecommendation
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Want more access?", systemImage: "arrow.up.circle.fill")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Assign:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(recommendation.roleName)
                        .font(.callout)
                        .fontWeight(.medium)
                    Text("→ \(recommendation.targetTier.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(recommendation.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Spacer()
                Button(copied ? "Copied!" : "Copy Role Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recommendation.roleName, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .font(.callout)
                .foregroundStyle(.blue)
                .animation(.default, value: copied)
            }
        }
    }
}

// MARK: - Metadata Footer

@available(macOS 15.0, *)
private struct MetadataFooter: View {
    let evaluatedAt: Date?
    let onReEvaluate: () -> Void

    var body: some View {
        HStack {
            if let date = evaluatedAt {
                Text("Evaluated \(date, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                onReEvaluate()
            } label: {
                Label("Re-evaluate my access", systemImage: "arrow.clockwise")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
        }
    }
}

// MARK: - Popover Variant (for toolbar integration)

/// Compact button that shows the AccessSummaryCard in a popover.
@available(macOS 15.0, *)
struct AccessTierButton: View {
    @Environment(GRPCManager.self) var grpc
    @State private var isShowingCard = false

    var body: some View {
        Button {
            isShowingCard.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: grpc.accessTier.badgeSystemImage)
                Text(grpc.accessTier.displayName)
                    .font(.callout)
            }
            .foregroundStyle(tierButtonColor)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $isShowingCard, arrowEdge: .bottom) {
            AccessSummaryCard()
                .padding(4)
        }
        .help("View your current access tier and capabilities")
    }

    private var tierButtonColor: Color {
        switch grpc.accessTier {
        case .noAccess:        return .red
        case .readOnly:        return .secondary
        case .messageReader:   return .blue
        case .messageOperator: return .orange
        case .fullAccess:      return .green
        }
    }
}

// MARK: - Per-Tier Wireframes (text reference)
//
// Tier 0 — No Access:
//   🛑  No Access
//       You have no permissions on this namespace.
//   ────────────────────────────────
//   ❌ Browse Queues, Topics & Subscriptions
//   ❌ View Entity Properties
//   ❌ Peek & Fetch Messages
//   ❌ Purge Messages
//   ❌ Resubmit Dead-Letter Messages
//   ❌ Create Queues, Topics & Subscriptions
//   ❌ Manage Subscription Filter Rules
//   ────────────────────────────────
//   ↑ Want more access?
//     Assign: Reader → Read-Only Observer
//     "Grants read access to Azure resource metadata..."
//     [Copy Role Name]
//   ────────────────────────────────
//   Evaluated just now     [↺ Re-evaluate my access]
//
// Tier 1 — Read-Only Observer:
//   👁  Read-Only Observer
//       Browse entities and view properties only.
//   ────────────────────────────────
//   ✅ Browse Queues, Topics & Subscriptions
//   ✅ View Entity Properties
//   ❌ Peek & Fetch Messages            🔒
//   ❌ Purge Messages                   🔒
//   ❌ Resubmit Dead-Letter Messages    🔒
//   ❌ Create Queues, Topics & Subs     🔒
//   ❌ Manage Subscription Filter Rules 🔒
//   ────────────────────────────────
//   ↑ Want more access? Assign: Azure Service Bus Data Receiver → Message Reader
//
// Tier 2 — Message Reader:
//   📥  Message Reader
//       Browse entities, view properties, and peek messages.
//   ✅ Browse / View / Peek-Fetch
//   ❌ Purge / Resubmit / Create / Filters
//   ↑ Assign: Azure Service Bus Data Sender → Message Operator
//
// Tier 3 — Message Operator:
//   ⚙️  Message Operator
//       Inspect, purge, and resubmit messages. Cannot create resources.
//   ✅ Browse / View / Peek-Fetch / Purge / Resubmit
//   ❌ Create / Filters
//   ↑ Assign: Azure Service Bus Data Owner → Full Access
//
// Tier 4 — Full Access:
//   ✅  Full Access
//       Full access to all features.
//   ✅ All 7 capabilities
//   (no upgrade section)
//
// Partial Access (example — Tier 2 Partial):
//   📥  Message Reader  [Partial Access badge]
//       Browse entities, view properties, and peek messages.
//   (checklist reflects actual permissions, not the tier template)
