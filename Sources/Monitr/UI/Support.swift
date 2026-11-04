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

    /// "↓1.2 MB/s ↑40 KB/s", leaving out a direction that is idle; "–" when both are.
    static func traffic(down: Double, up: Double) -> String {
        var parts: [String] = []
        if down >= 1 { parts.append("↓" + rate(down)) }
        if up >= 1 { parts.append("↑" + rate(up)) }
        return parts.isEmpty ? "–" : parts.joined(separator: "  ")
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

/// App icons, rasterised once into a small bitmap per bundle. Drawing a ready bitmap is far
/// cheaper than letting each redraw pick and scale a representation from a 1024 px icon.
@MainActor
enum Icons {
    private static var cache: [String: CGImage] = [:]
    static let pixels = 72  // 36 pt at 2x, the largest size we show

    static func bitmap(for key: String) -> CGImage? {
        if let i = cache[key] { return i }
        guard key.hasSuffix(".app") else { return nil }
        let src = NSWorkspace.shared.icon(forFile: key)
        var rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let out = ctx.makeImage()
        cache[key] = out
        return out
    }
}

struct AppIcon: View {
    let key: String
    var size: CGFloat = 18
    var body: some View {
        Group {
            if let cg = Icons.bitmap(for: key) {
                Image(decorative: cg, scale: 2).resizable()
            } else {
                Image(systemName: key == "system" ? "apple.logo" : "terminal")
                    .resizable().scaledToFit().padding(size * 0.12)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A history chart that glides left as each new value arrives.
///
/// The path is drawn once per value; the glide is a single offset animation, which the
/// compositor handles without redrawing, so it stays cheap at any frame rate.
struct Sparkline: View {
    let ring: Ring
    var ceiling: Double? = nil
    var tint: Color = .accentColor

    @State private var shift: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let values = ring.ordered
            // Until the history is full it stretches to the width. Once full, one extra slot lets the
            // oldest point slide out past the left edge while the new one enters.
            let full = ring.count >= ring.capacity
            let step = geo.size.width / CGFloat(max((full ? ring.capacity - 1 : ring.count) - 1, 1))
            let top = ceiling ?? Self.niceCeiling(values.max() ?? 0)
            Canvas { ctx, size in
                guard values.count > 1 else { return }
                let pts = values.enumerated().map { i, v in
                    CGPoint(x: size.width - CGFloat(values.count - 1 - i) * step,
                            y: size.height - CGFloat(min(v / top, 1)) * (size.height - 2) - 1)
                }
                let line = Self.smoothPath(pts)
                var fill = line
                fill.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
                fill.addLine(to: CGPoint(x: pts[0].x, y: size.height))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.20), tint.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .offset(x: shift * step)
        }
        .clipped()
        .onChange(of: ring.pushes) {
            guard !reduceMotion, ring.count >= ring.capacity else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { shift = 1 }
            DispatchQueue.main.async { withAnimation(Motion.data) { shift = 0 } }
        }
        .accessibilityHidden(true)
    }

    /// Quadratic curves through the midpoints: smooth, and never overshoots the data.
    static func smoothPath(_ p: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: p[0])
        guard p.count > 2 else { path.addLine(to: p[p.count - 1]); return path }
        for i in 1..<p.count {
            let mid = CGPoint(x: (p[i - 1].x + p[i].x) / 2, y: (p[i - 1].y + p[i].y) / 2)
            path.addQuadCurve(to: mid, control: p[i - 1])
        }
        path.addLine(to: p[p.count - 1])
        return path
    }

    /// Rounds the scale up to 1, 2 or 5 times a power of ten, so it rarely jumps.
    static func niceCeiling(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let mag = pow(10, floor(log10(v)))
        for m in [1.0, 2, 5, 10] where v <= m * mag { return m * mag }
        return 10 * mag
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

/// A short message about something that did not go as asked, with the next step.
struct NoticeBar: View {
    @Environment(Store.self) private var store
    let notice: Notice

    private var forceTitle: String {
        if case .app = notice.target { return "Force Quit" }
        return "Force Stop"
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            Image(systemName: notice.kind == .error ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                .font(.title3)
                .foregroundStyle(notice.kind == .error ? Color.red : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(notice.title).font(.headline)
                Text(notice.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.m)
            if let pid = notice.revealPid {
                Button("Show") {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                    store.dismissNotice()
                }
            }
            if notice.target != nil {
                Button(forceTitle, role: .destructive) { store.forceFromNotice() }
            }
            Button { store.dismissNotice() } label: {
                Image(systemName: "xmark").font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(Space.m)
        .frame(maxWidth: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.notice, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.notice, style: .continuous).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
    }
}
