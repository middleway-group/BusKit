import SwiftUI

// MARK: - StatusBarView

/// Native macOS-style bottom status bar showing connection state,
/// last refresh time, and the count of currently-visible messages.
@available(macOS 15.0, *)
struct StatusBarView: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(AppStatusModel.self) var appStatus

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
        }
        .frame(height: 22)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Helpers

    private var statusDivider: some View {
        Divider()
            .frame(height: 12)
            .padding(.vertical, 5)
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
