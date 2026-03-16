import SwiftUI

@available(macOS 15.0, *)
@main
struct BusKitApp: App {
    @State private var grpc = GRPCManager()
    @State private var actionStore = EntityActionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(grpc)
                .environment(actionStore)
                .onAppear {
                    grpc.startSidecar()
                }
                .onDisappear {
                    grpc.shutdown()
                }
        }
        .windowStyle(.titleBar)
    }
}
