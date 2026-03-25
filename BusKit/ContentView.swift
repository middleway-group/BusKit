import SwiftUI

@available(macOS 15.0, *)
struct ContentView: View {
    @Environment(GRPCManager.self) var grpc
    @State private var connectionString: String = ""
    @State private var isConnectionPopoverPresented = false
    @State private var selection: SidebarSelection?

    // RBAC dialog: track which access level is currently shown so the sheet
    // is not re-triggered if the user has already dismissed it for this session.
    @State private var shownRbacLevel: RbacAccessLevel?
    @State private var showRbacDialog = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300)
        } detail: {
            switch selection {
            case .queue(let queue):
                QueueDetailView(queue: queue)
            case .subscription(let sub):
                SubscriptionDetailView(subscription: sub)
            case nil:
                Text("Select a queue or subscription")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("BusKit")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ConnectionToolbar(connectionString: $connectionString, isPopoverPresented: $isConnectionPopoverPresented)
            }
        }
        .onChange(of: grpc.connectionState) { _, newState in
            if newState != .connected {
                selection = nil
                showRbacDialog = false
                shownRbacLevel = nil
            }
        }
        .onChange(of: grpc.rbacAccessLevel) { _, newLevel in
            let needsDialog: Bool
            switch newLevel {
            case .dataOnly, .managementOnly, .denied, .checkFailed:
                // Only show once per level change (avoids re-triggering after dismiss).
                needsDialog = newLevel != shownRbacLevel
            default:
                needsDialog = false
            }
            if needsDialog {
                shownRbacLevel = newLevel
                showRbacDialog = true
            }
        }
        .sheet(isPresented: $showRbacDialog) {
            RbacPermissionDialog(
                accessLevel: grpc.rbacAccessLevel,
                onDismiss: { showRbacDialog = false },
                onRetry: {
                    showRbacDialog = false
                    shownRbacLevel = nil
                    grpc.refreshRbacPermissions()
                },
                onSwitchToConnectionString: {
                    showRbacDialog = false
                    Task {
                        try? await grpc.disconnect()
                        grpc.resetAzureLoginState()
                    }
                }
            )
            .environment(grpc)
            // Prevent dismissal by clicking outside for the access-denied case.
            .interactiveDismissDisabled(grpc.rbacAccessLevel == .denied)
        }
    }
}
