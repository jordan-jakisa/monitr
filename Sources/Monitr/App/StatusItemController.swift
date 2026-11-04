import AppKit
import SwiftUI

/// Menu bar item. Its title is a plain attributed string, rebuilt only when the text changes.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var popover: NSPopover?
    private var lastTitle = ""
    private let openWindow: () -> Void
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private var symbols: [MenuStat: NSImage] = [:]

    init(openWindow: @escaping () -> Void) {
        self.openWindow = openWindow
        super.init()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        render(Store.shared.system, force: true)
        Store.shared.onSystemUpdate = { [weak self] s in self?.render(s) }
        Store.shared.onMenuStatsChange = { [weak self] in self?.render(Store.shared.system, force: true) }
        SleepGuard.shared.onChange = { [weak self] in self?.render(Store.shared.system, force: true) }
    }

    private func symbol(_ stat: MenuStat) -> NSImage? {
        if let s = symbols[stat] { return s }
        let name = switch stat {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .temperature: "thermometer.medium"
        case .network: "arrow.up.arrow.down"
        case .power: "bolt.fill"
        case .battery: "battery.75percent"
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: stat.title)?.withSymbolConfiguration(cfg)
        img?.isTemplate = true
        symbols[stat] = img
        return img
    }

    private func text(_ stat: MenuStat, _ s: SystemSnapshot) -> String? {
        switch stat {
        case .cpu: return "\(Int(s.cpu.rounded()))%"
        case .memory: return "\(Int((s.memoryFraction * 100).rounded()))%"
        case .temperature: return s.temperature.map { "\(Int($0.rounded()))°" }
        case .network: return "↓\(Fmt.shortRate(s.netIn)) ↑\(Fmt.shortRate(s.netOut))"
        case .power: return s.power.map { "\(Int($0.rounded()))W" }
        case .battery: return s.battery.map { "\($0)%" }
        }
    }

    private func render(_ s: SystemSnapshot, force: Bool = false) {
        guard let button = item.button else { return }
        let stats = Store.shared.menuStats
        let parts = stats.compactMap { st in text(st, s).map { (st, $0) } }
        let awake = SleepGuard.shared.isOn
        let key = (awake ? "awake|" : "") + parts.map(\.1).joined(separator: "|")
        if !force && key == lastTitle { return }
        lastTitle = key

        if parts.isEmpty {
            button.attributedTitle = NSAttributedString()
            button.image = NSImage(systemSymbolName: awake ? "cup.and.saucer.fill" : "gauge.with.dots.needle.33percent",
                                   accessibilityDescription: awake ? "Monitr, preventing sleep" : "Monitr")
            button.image?.isTemplate = true
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let out = NSMutableAttributedString()
        // While sleep is prevented, a cup leads the label so it is never left on by accident.
        if awake, let cup = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Preventing sleep")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) {
            let att = NSTextAttachment()
            att.image = cup
            att.bounds = CGRect(x: 0, y: -2, width: cup.size.width, height: cup.size.height)
            out.append(NSAttributedString(attachment: att))
            out.append(NSAttributedString(string: "  ", attributes: attrs))
        }
        for (i, (stat, value)) in parts.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "  ", attributes: attrs)) }
            if let img = symbol(stat) {
                let att = NSTextAttachment()
                att.image = img
                att.bounds = CGRect(x: 0, y: -2, width: img.size.width, height: img.size.height)
                out.append(NSAttributedString(attachment: att))
                out.append(NSAttributedString(string: " ", attributes: attrs))
            }
            out.append(NSAttributedString(string: value, attributes: attrs))
        }
        button.attributedTitle = NSAttributedString()
        button.image = rasterize(out)
        button.setAccessibilityLabel((awake ? "Preventing sleep, " : "") + parts.map { "\($0.0.title) \($0.1)" }.joined(separator: ", "))
    }

    /// Draws the label once into a bitmap template image. macOS redraws status items for every
    /// menu bar on every change; copying a bitmap is far cheaper than laying out text and symbols.
    private func rasterize(_ text: NSAttributedString) -> NSImage {
        let size = text.size()
        let scale = max(NSScreen.screens.map(\.backingScaleFactor).max() ?? 2, 1)
        let w = Int(ceil(size.width)), h = Int(ceil(max(size.height, 16)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(CGFloat(w) * scale), pixelsHigh: Int(CGFloat(h) * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return NSImage() }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        text.draw(at: NSPoint(x: 0, y: (CGFloat(h) - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        img.isTemplate = true
        return img
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        if let p = popover, p.isShown { p.performClose(nil); return }
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.delegate = self
        p.contentViewController = NSHostingController(
            rootView: PopoverView(openWindow: { [weak self] in
                self?.popover?.performClose(nil)
                // Open on the next run loop pass, after the panel's close has committed;
                // opening a window inside that commit makes AppKit log a transaction error.
                DispatchQueue.main.async { self?.openWindow() }
            })
            .environment(Store.shared)
        )
        popover = p
        Engine.shared.setViewer("popover", active: true)
        Store.shared.popoverOpen = true
        p.show(relativeTo: item.button!.bounds, of: item.button!, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Monitr", action: #selector(openFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let guardian = SleepGuard.shared
        let sleepItem = NSMenuItem(title: guardian.isOn ? "Preventing Sleep: \(guardian.detail)" : "Prevent Sleep", action: nil, keyEquivalent: "")
        sleepItem.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        let sub = NSMenu()
        for (i, length) in SleepGuard.Length.choices.enumerated() {
            let it = NSMenuItem(title: length.title, action: #selector(preventSleep(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            it.state = guardian.isOn && guardian.lastLength == length ? .on : .off
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let display = NSMenuItem(title: "Keep Display On", action: #selector(toggleDisplay), keyEquivalent: "")
        display.target = self
        display.state = guardian.keepDisplayOn ? .on : .off
        sub.addItem(display)
        if guardian.isOn {
            sub.addItem(.separator())
            let off = NSMenuItem(title: "Allow Sleep", action: #selector(allowSleep), keyEquivalent: "")
            off.target = self
            sub.addItem(off)
        }
        sleepItem.submenu = sub
        menu.addItem(sleepItem)
        let quick = QuickQuit.shared
        if !quick.entries.isEmpty {
            let n = quick.runningCount
            let q = NSMenuItem(title: n == 0 ? "Quick Quit: none running" : "Quick Quit \(n) \(n == 1 ? "App" : "Apps")",
                               action: n == 0 ? nil : #selector(quickQuit), keyEquivalent: "")
            q.target = self
            q.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: nil)
            menu.addItem(q)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Monitr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func preventSleep(_ sender: NSMenuItem) {
        SleepGuard.shared.turnOn(SleepGuard.Length.choices[sender.tag])
    }

    @objc private func toggleDisplay() { SleepGuard.shared.keepDisplayOn.toggle() }

    @objc private func allowSleep() { SleepGuard.shared.turnOff() }

    @objc private func quickQuit() { QuickQuit.shared.quitAll() }

    @objc private func openFromMenu() { DispatchQueue.main.async { [weak self] in self?.openWindow() } }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            Engine.shared.setViewer("popover", active: false)
            Store.shared.popoverOpen = false
            // Free the SwiftUI tree while the panel is closed.
            popover?.contentViewController = nil
            popover = nil
        }
    }
}
