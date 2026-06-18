import SwiftUI
import AppKit
import Sparkle

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var aboutWindow: NSWindow?
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/pka-fr/BusKit/main/releases/appcast.xml"
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        guard !others.isEmpty else { return }

        others.first?.activate(options: [])

        let alert = NSAlert()
        alert.messageText = "BusKit is already running"
        alert.informativeText = "Only one instance of BusKit can run at a time. The existing window has been brought to the front."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()

        NSApp.terminate(nil)
    }

    @objc func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc func showAboutWindow() {
        let parent = NSApp.mainWindow ?? NSApp.keyWindow
        if aboutWindow == nil {
            let controller = NSHostingController(rootView: AboutView())
            let window = NSWindow(contentViewController: controller)
            window.title = "About BusKit"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            aboutWindow = window
        }
        // Hide until positioned so the window doesn't flash in the wrong place.
        aboutWindow?.alphaValue = 0
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Wait for the NavigationSplitView sidebar animation (~250 ms on first
        // launch) to finish so we read the parent's settled frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let window = self?.aboutWindow else { return }
            if let pf = parent?.frame {
                let wf = window.frame
                window.setFrameOrigin(NSPoint(
                    x: pf.midX - wf.width / 2,
                    y: pf.midY - wf.height / 2
                ))
            }
            window.alphaValue = 1
        }
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
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About BusKit") {
                    NSApp.sendAction(#selector(AppDelegate.showAboutWindow), to: nil, from: nil)
                }
                Button("Check for Updates...") {
                    NSApp.sendAction(#selector(AppDelegate.checkForUpdates), to: nil, from: nil)
                }
            }
        }
    }
}
