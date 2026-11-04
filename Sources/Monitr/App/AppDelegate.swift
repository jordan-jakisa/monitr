import AppKit
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: StatusItemController?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        // One Monitr at a time: a second launch (say, from the build folder) hands over and quits.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .first(where: { $0.processIdentifier != me.processIdentifier }) {
            if let url = other.bundleURL { NSWorkspace.shared.open(url) }  // shows its window
            NSApp.terminate(nil)
            return
        }
        Engine.shared.start()
        statusItem = StatusItemController { [weak self] in self?.showWindow() }
        installMainMenu()
        if !launchedAsLoginItem() { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
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

    func showWindow() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.title = "Monitr"
            w.isReleasedWhenClosed = false
            // A real toolbar lets SwiftUI place the title, sidebar button, filters and search in
            // it, and gives the native Liquid Glass bar and floating sidebar instead of a plain
            // title bar with a hard divider.
            let toolbar = NSToolbar(identifier: "MonitrMain")
            toolbar.displayMode = .iconOnly
            w.toolbar = toolbar
            w.toolbarStyle = .unified
            w.titlebarSeparatorStyle = .none
            let host = NSHostingController(rootView: MainView().environment(Store.shared))
            host.sizingOptions = [.minSize]
            w.contentViewController = host
            w.setContentSize(NSSize(width: 1120, height: 700))
            w.delegate = self
            w.setFrameAutosaveName("MonitrMain")
            if !w.setFrameUsingName("MonitrMain") { w.center() }
            window = w
            Engine.shared.setViewer("window", active: true)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Fully covered or minimised windows need no per-process data; sampling pauses until
    /// the window shows again.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let w = window else { return }
        Engine.shared.setViewer("window", active: w.occlusionState.contains(.visible), keepData: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Store.shared.windowKey = true
        Store.shared.publishNow()
    }

    func windowDidResignKey(_ notification: Notification) { Store.shared.windowKey = false }

    func windowWillClose(_ notification: Notification) {
        Store.shared.windowKey = false
        Engine.shared.setViewer("window", active: false)
        // Drop the whole view tree; it is rebuilt on next open. Keeps idle memory small.
        window?.contentViewController = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Monitr", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Monitr", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Monitr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Find", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = win
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
}
