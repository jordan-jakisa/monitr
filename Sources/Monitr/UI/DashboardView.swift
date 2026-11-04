import SwiftUI

struct DashboardView: View {
    @Environment(Store.self) private var store
    var openApp: (String) -> Void

    var body: some View {
        let worth = worthClosing
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                // What matters most first: is the Mac fine, then the numbers, then anything to act
                // on, then who is using what.
                StatusLine(status: status(worth))
                metrics
                if !worth.isEmpty { closable(worth).transition(.opacity) }
                HStack(alignment: .top, spacing: Space.xxl) {
                    usageList(title: "Most CPU", detail: "Click an app to see its processes.",
                              rows: store.busiest, value: { Fmt.percent($0.cpu) }, amount: { $0.cpu }, tint: .blue)
                    usageList(title: "Most memory", detail: "What is holding your RAM right now.",
                              rows: topMemory, value: { Fmt.bytes($0.memory) }, amount: { Double($0.memory) }, tint: .purple)
                }
            }
            .padding(Space.xl)
            .motion(Motion.reveal, value: worth.isEmpty)
        }
    }

    // MARK: Status line

    private var worthClosing: [AppGroup] {
        Array(store.apps.filter(\.suggestQuit).sorted { $0.memory > $1.memory }.prefix(5))
    }

    private var topMemory: [AppGroup] {
        Array(store.apps.filter { $0.memory > 0 }.sorted { $0.memory > $1.memory }.prefix(7))
    }

    /// The one sentence that answers "is my Mac all right?", most urgent condition first.
    private func status(_ worth: [AppGroup]) -> StatusLine.Status {
        let s = store.system
        let topCPU = store.busiest.first
        let topMem = topMemory.first
        if s.thermal == .serious || s.thermal == .critical {
            let who = store.apps.max { $0.power < $1.power }
            return .init(ok: false, title: "Your Mac is hot and slowing down",
                         detail: who.map { "\($0.name) is drawing the most power (\(Fmt.watts($0.power)))." } ?? "Close heavy apps to let it cool.")
        }
        if s.pressure != .normal {
            return .init(ok: false, title: "Memory is running short",
                         detail: topMem.map { "\($0.name) is using \(Fmt.bytes($0.memory)). Closing it frees the most." } ?? "Close apps you are not using.")
        }
        if let b = s.battery, !s.onAC, b <= 15 {
            return .init(ok: false, title: "Battery is low: \(b)%",
                         detail: s.minutesLeft.map { "About \(Fmt.duration(Double($0) * 60)) left. Plug in soon." } ?? "Plug in soon.")
        }
        if s.cpu >= 80, let t = topCPU {
            return .init(ok: false, title: "Your Mac is working hard",
                         detail: "\(t.name) is the busiest at \(Fmt.percent(t.cpu)) CPU.")
        }
        if !worth.isEmpty {
            let total = worth.reduce(UInt64(0)) { $0 + $1.memory }
            return .init(ok: true, title: "Running smoothly",
                         detail: "\(worth.count) unused \(worth.count == 1 ? "app is" : "apps are") holding \(Fmt.bytes(total)) you could free.")
        }
        return .init(ok: true, title: "Running smoothly",
                     detail: store.apps.isEmpty ? "Measuring…" : "Nothing needs your attention.")
    }

    // MARK: Metrics row

    private var metrics: some View {
        let s = store.system
        return HStack(alignment: .top, spacing: 0) {
            Metric(kind: .cpu, title: "CPU", value: Fmt.percent(s.cpu), detail: thermalText(s.thermal),
                   ring: store.cpuHistory, ceiling: 100, tint: .blue)
            Divider().padding(.vertical, Space.xs)
            Metric(kind: .memory, title: "Memory", value: Fmt.bytes(s.memoryUsed),
                   detail: s.pressure != .normal ? pressureText(s.pressure)
                       : s.swapUsed >= 100 * 1024 * 1024 ? "RAM, +\(Fmt.bytes(s.swapUsed)) swap" : "of \(Fmt.bytes(s.memoryTotal)) RAM",
                   ring: store.memHistory, ceiling: 100, tint: .purple)
            Divider().padding(.vertical, Space.xs)
            Metric(kind: .network, title: "Network", value: "↓" + Fmt.rate(s.netIn), detail: "↑ " + Fmt.rate(s.netOut) + " up",
                   ring: store.netInHistory, ceiling: nil, tint: .teal)
            Divider().padding(.vertical, Space.xs)
            Metric(kind: .temperature, title: "Temperature", value: s.temperature.map(Fmt.temp) ?? "–", detail: "Hottest core",
                   ring: store.tempHistory, ceiling: 100, tint: .orange)
            Divider().padding(.vertical, Space.xs)
            Metric(kind: .power, title: "Power", value: s.power.map(Fmt.watts) ?? "–", detail: batteryText(s),
                   ring: store.powerHistory, ceiling: nil, tint: .green)
        }
    }

    private func thermalText(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot, slowing"
        case .critical: "Throttling"
        @unknown default: "–"
        }
    }

    private func pressureText(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: "No pressure"
        case .warning: "Under pressure"
        case .critical: "Critical pressure"
        }
    }

    private func batteryText(_ s: SystemSnapshot) -> String {
        guard let b = s.battery else { return "Whole Mac" }
        if s.charging { return "\(b)%, charging" }
        if s.onAC { return "Battery \(b)%" }
        if let m = s.minutesLeft { return "\(b)%, \(Fmt.duration(Double(m) * 60)) left" }
        return "Battery \(b)%"
    }

    // MARK: Usage lists

    private func usageList(title: String, detail: String, rows: [AppGroup],
                           value: @escaping (AppGroup) -> String, amount: @escaping (AppGroup) -> Double,
                           tint: Color) -> some View {
        let top = max(rows.map(amount).max() ?? 1, 0.0001)
        return VStack(alignment: .leading, spacing: Space.xs) {
            SectionTitle(title: title, detail: detail)
            if rows.isEmpty {
                ProgressView().controlSize(.small).padding(.vertical, Space.s)
            }
            ForEach(rows) { g in
                Button { openApp(g.id) } label: {
                    HStack(spacing: Space.m) {
                        AppIcon(key: g.id, size: 20)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            HStack {
                                Text(g.name).lineLimit(1)
                                Spacer()
                                Text(value(g)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            UsageBar(fraction: amount(g) / top, tint: tint).frame(height: 4)
                        }
                    }
                }
                .buttonStyle(RowButtonStyle())
                .padding(.horizontal, -Space.s)
                .help("Show \(g.name)'s processes")
                .accessibilityLabel("\(g.name), \(value(g))")
                .accessibilityHint("Shows its processes")
                // Rows that drop out vanish at once, so nothing overlaps while the rest move up.
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .motion(Motion.list, value: rows.map(\.id))
    }

    // MARK: Worth closing

    private func closable(_ items: [AppGroup]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionTitle(
                title: "Worth closing",
                detail: "Not used for \(Int(Store.unusedAfter / 60)) minutes, or idle in the background for \(Int(ProcessSampler.idleAfter / 60)). Biggest first."
            )
            ForEach(items) { g in
                HStack(spacing: Space.m) {
                    AppIcon(key: g.id, size: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(g.name).lineLimit(1)
                        if let st = g.statusText { TagLabel(text: st.0, tone: st.1) }
                    }
                    Spacer()
                    Text(Fmt.bytes(g.memory)).monospacedDigit().foregroundStyle(.secondary)
                    StopButton(title: g.isAppBundle ? "Quit" : "Stop all") { force in
                        withAnimation(Motion.list) { store.stop(app: g.id, force: force) }
                    }
                }
                .padding(.vertical, Space.xs)
                .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .trailing))))
            }
        }
        .motion(Motion.list, value: items.map(\.id))
    }
}

/// The Overview's opening line: one sentence on how the Mac is doing, and what to do if not.
private struct StatusLine: View {
    struct Status: Equatable {
        let ok: Bool
        let title: String
        let detail: String
    }
    let status: Status

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(status.ok ? Color.green : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title).font(.title2.weight(.semibold))
                Text(status.detail).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Space.xs)
        .accessibilityElement(children: .combine)
        .motion(Motion.reveal, value: status.title)
    }
}

private struct SectionTitle: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Space.s)
    }
}

private struct Metric: View {
    let kind: MetricKind
    let title: String
    let value: String
    let detail: String
    let ring: Ring
    let ceiling: Double?
    let tint: Color

    var body: some View {
        NavigationLink(value: kind) { content }
            .buttonStyle(MetricButtonStyle())
            .help("Show \(title.lowercased()) details")
            .accessibilityLabel("\(title), \(value), \(detail)")
            .accessibilityHint("Shows \(title.lowercased()) details")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Sparkline(ring: ring, ceiling: ceiling, tint: tint)
                .frame(height: 44)
                .padding(.top, Space.s)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The whole metric column is the click target, with a soft highlight on hover and press.
private struct MetricButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { MetricBody(configuration: configuration) }

    private struct MetricBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .padding(Space.m)
                .background(
                    RoundedRectangle(cornerRadius: Radius.notice, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : hovering ? 0.04 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.notice, style: .continuous))
                .onHover { hovering = $0 }
                .motion(Motion.feedback, value: hovering)
                .motion(Motion.feedback, value: configuration.isPressed)
                .padding(.horizontal, Space.xs)
        }
    }
}

/// One click stops. Option-click force-stops.
struct StopButton: View {
    var title = "Stop"
    let action: (_ force: Bool) -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            action(NSEvent.modifierFlags.contains(.option))
        } label: {
            Text(title).font(.callout.weight(.medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(hovering ? .red : nil)
        .onHover { hovering = $0 }
        .motion(Motion.feedback, value: hovering)
        .help("\(title) now. Option-click to force.")
    }
}
