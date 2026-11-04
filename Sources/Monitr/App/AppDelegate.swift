import AppKit
import SwiftUI

/// Monitr is a native SwiftUI app: one window (opened on demand) and one menu bar item.
@main
struct MonitrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Monitr", id: WindowOpener.mainID) {
            MainView()
                .environment(Store.shared)
                .background(WindowLifecycle())
        }
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unified)
        // The window opens when the person asks for it, never by itself at login.
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { WindowOpener.open(.settings) }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            PopoverView(openWindow: { WindowOpener.open() })
                .environment(Store.shared)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Lets AppKit code and the menu bar open the window, which SwiftUI only exposes to views.
@MainActor
enum WindowOpener {
    static let mainID = "main"
    static var action: OpenWindowAction?
    static var pendingFirstOpen = false

    static func open(_ pane: Pane? = nil) {
        action?(id: mainID)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let pane { Store.shared.navigateTo = pane }
    }
}

/// The menu bar label. Being always on screen, it is also where the window opener is captured.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @State private var label = StatusLabel.shared

    var body: some View {
        Image(nsImage: label.image)
            .accessibilityLabel(label.accessibility)
            .task {
                WindowOpener.action = openWindow
                if WindowOpener.pendingFirstOpen {
                    WindowOpener.pendingFirstOpen = false
                    WindowOpener.open()
                }
            }
    }
}

/// Ties the SwiftUI window to Monitr's sampling: per-process data only while it is visible,
/// a Dock icon only while it is open.
private struct WindowLifecycle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Tracker() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Tracker: NSView {
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let w = window else { return }
            w.setFrameAutosaveName("MonitrMain")
            Engine.shared.setViewer("window", active: true)
            NSApp.setActivationPolicy(.regular)
            let nc = NotificationCenter.default
            tokens.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // Covered or minimised: pause, keeping the last figures on screen.
                    Engine.shared.setViewer("window", active: w.occlusionState.contains(.visible), keepData: true)
                }
            })
            tokens.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Store.shared.windowKey = true
                    Store.shared.publishNow()
                }
            })
            tokens.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { Store.shared.windowKey = false }
            })
            tokens.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Store.shared.windowKey = false
                    Engine.shared.setViewer("window", active: false)
                    NSApp.setActivationPolicy(.accessory)
                }
            })
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        // One Monitr at a time: a second launch (say, from Finder) hands over and quits.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .first(where: { $0.processIdentifier != me.processIdentifier }) {
            if let url = other.bundleURL { NSWorkspace.shared.open(url) }
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        Engine.shared.start()
        _ = StatusLabel.shared
        // Opened by the person (not at login): show the window as soon as the opener exists.
        if !launchedAsLoginItem() {
            if WindowOpener.action != nil { WindowOpener.open() } else { WindowOpener.pendingFirstOpen = true }
        }
    }

    /// Opening Monitr again from Finder, Spotlight or the Dock brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowOpener.open()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
