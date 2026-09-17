import SwiftUI
import AppKit
import Sparkle

// MARK: - MainWindowGuard

/// Prevents the main window from being resized larger than the current
/// screen (or left stuck off-screen/oversized from a previous session).
final class MainWindowGuard: NSObject, NSWindowDelegate {
    static let shared = MainWindowGuard()
    private weak var attachedWindow: NSWindow?

    func attach(to window: NSWindow) {
        guard attachedWindow !== window else { return }
        attachedWindow = window
        window.delegate = self
        clampFrame(of: window)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let screen = sender.screen ?? NSScreen.main else { return frameSize }
        let visible = screen.visibleFrame
        return NSSize(
            width: min(frameSize.width, visible.width),
            height: min(frameSize.height, visible.height)
        )
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        clampFrame(of: window)
    }

    /// Shrinks/repositions the window so it fully fits the visible area of
    /// its screen. Fixes windows that were left too wide/tall (or off-screen)
    /// by a prior session, since macOS otherwise restores that stale frame
    /// on every launch.
    private func clampFrame(of window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        var changed = false

        if frame.width > visible.width {
            frame.size.width = visible.width
            changed = true
        }
        if frame.height > visible.height {
            frame.size.height = visible.height
            changed = true
        }
        if frame.maxX > visible.maxX {
            frame.origin.x = visible.maxX - frame.width
            changed = true
        }
        if frame.minX < visible.minX {
            frame.origin.x = visible.minX
            changed = true
        }
        if frame.maxY > visible.maxY {
            frame.origin.y = visible.maxY - frame.height
            changed = true
        }
        if frame.minY < visible.minY {
            frame.origin.y = visible.minY
            changed = true
        }

        if changed {
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var aboutWindow: NSWindow?
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/middleway-group/BusKit/main/releases/appcast.xml"
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController.updater.checkForUpdatesInBackground()
        attachMainWindowGuard()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func mainWindowDidBecomeKey(_ notification: Notification) {
        attachMainWindowGuard()
    }

    /// Attaches the guard to the app's main content window (excluding the
    /// About panel), so a previously oversized/off-screen frame is corrected
    /// and future resizes are kept within the screen bounds.
    private func attachMainWindowGuard() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0 !== aboutWindow }) else { return }
        MainWindowGuard.shared.attach(to: window)
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
