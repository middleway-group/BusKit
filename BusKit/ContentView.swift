import SwiftUI

@available(macOS 15.0, *)
struct ContentView: View {
    @Environment(GRPCManager.self) var grpc
    @State private var connectionString: String = ""
    @State private var selection: SidebarSelection?

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
            ToolbarItem(placement: .automatic) {
                ConnectionToolbar(connectionString: $connectionString)
            }
        }
        .onChange(of: grpc.connectionState) { _, newState in
            // Clear the detail panel whenever we disconnect or start reconnecting
            // to a different namespace, so stale data from the previous
            // connection is never shown.
            if newState != .connected {
                selection = nil
            }
        }
    }
}
