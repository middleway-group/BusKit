import SwiftUI

@available(macOS 15.0, *)
struct ContentView: View {
    @Environment(GRPCManager.self) var grpc
    @Environment(EntityActionStore.self) var actionStore
    @State private var connectionString: String = ""
    @State private var selection: SidebarSelection?
    @State private var appStatus   = AppStatusModel()
    @State private var activityLog = ActivityLogStore()

    // RBAC dialog: track which access level is currently shown so the sheet
    // is not re-triggered if the user has already dismissed it for this session.
    @State private var shownRbacLevel: RbacAccessLevel?
    @State private var showRbacDialog = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300)
        } detail: {
            // ZStack lets the toast overlay float in the top-right corner of
            // the detail area without affecting layout of the content beneath.
            ZStack(alignment: .topTrailing) {
                Group {
                    switch selection {
                    case .queue(let queue):
                        QueueDetailView(queue: queue)
                    case .topic(let topic):
                        TopicDetailView(topic: topic)
                    case .subscription(let sub):
                        SubscriptionDetailView(subscription: sub)
                            .id(sub.id)
                    case .rulesGroup(let sub), .rule(_, let sub):
                        SubscriptionDetailView(subscription: sub)
                            .id(sub.id)
                    case nil:
                        Text("Select a queue or subscription")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // ── Toast notification overlay ───────────────────
                ToastOverlay()
            }
        }
        // Propagate the shared models to all child views, including
        // the safeAreaInset StatusBarView (must wrap the inset, not precede it).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // ── Collapsible Activity Log (slides up above the status bar)
                if activityLog.isLogVisible {
                    ActivityLogPanel()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // ── Status bar (always visible) ──────────────────
                StatusBarView()
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: activityLog.isLogVisible)
        }
        .environment(appStatus)
        .environment(activityLog)
        .navigationTitle("BusKit")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ConnectionToolbar(connectionString: $connectionString)
            }
        }
        .onChange(of: selection) { _, newSelection in
            // When a rules group or a specific rule is selected, focus the Rules tab.
            let sub: SubscriptionItem?
            switch newSelection {
            case .rulesGroup(let s): sub = s
            case .rule(_, let s):   sub = s
            default:                sub = nil
            }
            if let sub {
                let key = EntityActionStore.subscriptionKey(topic: sub.topicName, sub: sub.name)
                actionStore.focusRules(entityKey: key)
            }
        }
        .onChange(of: grpc.connectionState) { _, newState in
            if newState != .connected {
                selection = nil
                showRbacDialog = false
                shownRbacLevel = nil
                appStatus.lastRefreshTime = nil
                appStatus.visibleMessageCount = 0
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
