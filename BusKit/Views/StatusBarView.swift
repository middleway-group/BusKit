import SwiftUI

// MARK: - StatusBarView

/// Native macOS-style bottom status bar showing connection state,
/// last refresh time, and the count of currently-visible messages.
@available(macOS 15.0, *)
struct StatusBarView: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(AppStatusModel.self) var appStatus
    @Environment(ActivityLogStore.self) var activityLog

    @State private var isActivityLogButtonHovering = false

    var body: some View {
        HStack(spacing: 0) {
            // ── Connection indicator ─────────────────────────────
            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(indicatorColor)
                Text(connectionLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)

            statusDivider

            // ── Last refresh ────────────────────────────────────
            if let t = appStatus.lastRefreshTime {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("Refreshed \(t, style: .relative) ago")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

                statusDivider
            }

            // ── Message count ───────────────────────────────────
            if appStatus.visibleMessageCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "envelope")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("\(appStatus.visibleMessageCount) message\(appStatus.visibleMessageCount == 1 ? "" : "s")")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            }

            Spacer()

            // ── Error / warning badge (conditional) ─────────────
            if activityLog.errorCount > 0 || activityLog.warningCount > 0 {
                Button {
                    activityLog.toggleLog()
                } label: {
                    HStack(spacing: 6) {
                        if activityLog.errorCount > 0 {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 6, height: 6)
                                Text("\(activityLog.errorCount) error\(activityLog.errorCount == 1 ? "" : "s")")
                                    .foregroundStyle(.red)
                            }
                        }
                        if activityLog.warningCount > 0 {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 6, height: 6)
                                Text("\(activityLog.warningCount) warning\(activityLog.warningCount == 1 ? "" : "s")")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)

                statusDivider
            }

            // ── Activity Log toggle (always visible) ─────────────
            Button {
                activityLog.toggleLog()
            } label: {
                Image(systemName: activityLog.isLogVisible ? "list.bullet.clipboard.fill" : "list.bullet.clipboard")
                    .font(.system(size: 11))
                    .foregroundStyle(activityLog.isLogVisible ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(isActivityLogButtonHovering ? 0.08 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isActivityLogButtonHovering = hovering
            }
            .padding(.horizontal, 6)
            .help(activityLog.isLogVisible ? "Hide Activity Log" : "Show Activity Log")
        }
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Helpers

    private var statusDivider: some View {
        Divider()
            .frame(height: 16)
            .padding(.vertical, 9)
    }

    private var indicatorColor: Color {
        switch grpc.connectionState {
        case .connected:
            switch grpc.rbacAccessLevel {
            case .checking:       return .orange
            case .dataOnly:       return .yellow
            case .managementOnly: return .yellow
            case .denied:         return .red
            case .checkFailed:    return .orange
            default:              return .green
            }
        case .connecting:   return .orange
        case .error:        return .red
        case .disconnected: return .gray
        }
    }

    private var connectionLabel: String {
        switch grpc.connectionState {
        case .connected:
            if let ns = grpc.namespaceName { return "Connected — \(ns)" }
            return "Connected"
        case .connecting:
            return grpc.isSidecarReady ? "Connecting…" : "Starting sidecar…"
        case .disconnected:
            return grpc.azureLoginPhase == .signingIn ? "Signing in…" : "Disconnected"
        case .error:
            return "Connection Error"
        }
    }
}
