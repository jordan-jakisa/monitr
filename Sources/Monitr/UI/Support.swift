import AppKit
import SwiftUI

enum Fmt {
    static func bytes(_ b: UInt64) -> String { bytes(Double(b)) }

    static func bytes(_ v: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var x = v, i = 0
        while x >= 1000 && i < units.count - 1 { x /= 1024; i += 1 }
        if i == 0 { return "\(Int(x)) B" }
        return x >= 100 ? "\(Int(x.rounded())) \(units[i])" : String(format: "%.1f %@", x, units[i])
    }

    static func rate(_ v: Double) -> String { v < 1 ? "0 KB/s" : bytes(v) + "/s" }

    /// Very short form for the menu bar: "1.2M", "340K".
    static func shortRate(_ v: Double) -> String {
        let units = ["K", "M", "G"]
        var x = v / 1024, i = 0
        while x >= 1000 && i < units.count - 1 { x /= 1024; i += 1 }
        return x >= 10 ? "\(Int(x.rounded()))\(units[i])" : String(format: "%.1f%@", x, units[i])
    }

    static func percent(_ v: Double) -> String {
        v < 10 && v > 0 ? String(format: "%.1f%%", v) : "\(Int(v.rounded()))%"
    }

    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(max(m, 1))m" }
        let h = m / 60
        return h < 24 ? "\(h)h \(m % 60)m" : "\(h / 24)d \(h % 24)h"
    }

    static func watts(_ w: Double) -> String {
        if w < 1 { return "\(Int((w * 1000).rounded())) mW" }
        return w < 10 ? String(format: "%.1f W", w) : "\(Int(w.rounded())) W"
    }

    static func temp(_ t: Double) -> String { "\(Int(t.rounded()))°C" }
}

/// App icons, loaded once per bundle and scaled down so they stay cheap.
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for key: String) -> NSImage {
        if let i = cache[key] { return i }
        let img: NSImage
        if key.hasSuffix(".app") {
            img = NSWorkspace.shared.icon(forFile: key)
        } else if key == "system" {
            img = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "macOS") ?? NSImage()
        } else {
            img = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Command-line process") ?? NSImage()
        }
        img.size = NSSize(width: 32, height: 32)
        cache[key] = img
        return img
    }
}

struct AppIcon: View {
    let key: String
    var size: CGFloat = 18
    var body: some View {
        Image(nsImage: Icons.icon(for: key))
            .renderingMode(key.hasSuffix(".app") ? .original : .template)
            .resizable()
            .interpolation(.high)
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A light line-and-fill chart drawn in one Canvas pass.
struct Sparkline: View {
    let values: [Double]
    var ceiling: Double? = nil
    var tint: Color = .accentColor

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let top = max(ceiling ?? 0, values.max() ?? 0, 0.0001)
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height - CGFloat(v / top) * (size.height - 2) - 1)
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.22), tint.opacity(0.02)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Short status label for a process or app ("Idle 12m", "Not used 45m").
struct TagLabel: View {
    let text: String
    let tone: Tone
    enum Tone { case neutral, attention, system }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tone == .attention ? Color.orange : .secondary)
            .lineLimit(1)
    }
}

extension ProcInfo {
    var statusText: (String, TagLabel.Tone)? {
        if tags.contains(.system) { return ("System", .system) }
        if tags.contains(.idle) { return ("Idle \(Fmt.duration(idleSeconds))", .attention) }
        if tags.contains(.background) { return ("Background", .neutral) }
        return nil
    }
}

extension AppGroup {
    var statusText: (String, TagLabel.Tone)? {
        if isSystem { return ("System", .system) }
        if let u = unusedFor { return ("Not used \(Fmt.duration(u))", .attention) }
        if let i = idleFor { return ("Idle \(Fmt.duration(i))", .attention) }
        return nil
    }
}
