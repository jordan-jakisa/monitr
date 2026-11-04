import AppKit
import SwiftUI

import Observation

/// The menu bar label: the chosen stats drawn into one template bitmap, rebuilt only when the
/// text changes. The menu bar redraws status items for every display on each change, and
/// copying a ready bitmap is far cheaper than laying out text and symbols each time.
@MainActor
@Observable
final class StatusLabel {
    static let shared = StatusLabel()

    private(set) var image = NSImage()
    private(set) var accessibility = "Monitr"
    @ObservationIgnored private var lastTitle = ""
    @ObservationIgnored private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    @ObservationIgnored private var symbols: [MenuStat: NSImage] = [:]

    private init() {
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
        let stats = Store.shared.menuStats
        let parts = stats.compactMap { st in text(st, s).map { (st, $0) } }
        let awake = SleepGuard.shared.isOn
        let key = (awake ? "awake|" : "") + parts.map(\.1).joined(separator: "|")
        if !force && key == lastTitle { return }
        lastTitle = key

        if parts.isEmpty {
            let img = NSImage(systemSymbolName: awake ? "cup.and.saucer.fill" : "dot.radiowaves.left.and.right",
                              accessibilityDescription: nil) ?? NSImage()
            img.isTemplate = true
            image = img
            accessibility = awake ? "Monitr, preventing sleep" : "Monitr"
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
        image = rasterize(out)
        accessibility = (awake ? "Preventing sleep, " : "") + parts.map { "\($0.0.title) \($0.1)" }.joined(separator: ", ")
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
}
