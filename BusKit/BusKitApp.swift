import SwiftUI
import AppKit

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        guard !others.isEmpty else { return }

        // Bring the existing instance to the front
        others.first?.activate(options: .activateIgnoringOtherApps)

        let alert = NSAlert()
        alert.messageText = "BusKit is already running"
        alert.informativeText = "Only one instance of BusKit can run at a time. The existing window has been brought to the front."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()

        NSApp.terminate(nil)
    }
}

// MARK: - App

@available(macOS 15.0, *)
@main
struct BusKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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
