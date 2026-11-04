@_exported import MonitrCore
import AppKit
import SwiftUI

/// App icons, rasterised once into a small bitmap per bundle. Drawing a ready bitmap is far
/// cheaper than letting each redraw pick and scale a representation from a 1024 px icon.
@MainActor
enum Icons {
    private static var cache: [String: CGImage?] = [:]
    static let pixels = 72  // 36 pt at 2x, the largest size we show

    /// The blank white icon macOS hands back for bundles that ship no icon of their own.
    private static let genericData: Data? = render(NSWorkspace.shared.icon(for: .applicationBundle))?.dataProvider?.data as Data?

    /// Nil when there is no real icon (not an app, or only the generic placeholder).
    static func bitmap(for key: String) -> CGImage? {
        if let i = cache[key] { return i }
        guard key.hasSuffix(".app") else { return nil }
        var out = render(NSWorkspace.shared.icon(forFile: key))
        if let d = out?.dataProvider?.data as Data?, d == genericData { out = nil }
        cache[key] = out
        return out
    }

    private static func render(_ src: NSImage) -> CGImage? {
        var rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return ctx.makeImage()
    }

    /// Symbol for anything without a real icon: macOS parts get the Apple logo.
    static func symbol(for key: String) -> String {
        if key == "system" || key.hasPrefix("/System/") { return "apple.logo" }
        if key == "simulator" { return "iphone" }
        if key.hasSuffix(".app") { return "app.dashed" }
        return "terminal"
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
                Image(systemName: Icons.symbol(for: key))
                    .resizable().scaledToFit().padding(size * 0.14)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
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
