import SwiftUI

struct DashboardView: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var openApp: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                metrics
                HStack(alignment: .top, spacing: 32) {
                    topApps.frame(maxWidth: .infinity, alignment: .topLeading)
                    closable.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(24)
        }
    }

    // MARK: Metrics row

    private var metrics: some View {
        let s = store.system
        return HStack(alignment: .top, spacing: 0) {
            Metric(title: "CPU", value: Fmt.percent(s.cpu), detail: thermalText(s.thermal),
                   history: store.cpuHistory.ordered, ceiling: 100, tint: .blue)
            Divider().padding(.vertical, 4)
            Metric(title: "Memory", value: Fmt.bytes(s.memoryUsed),
                   detail: s.pressure == .normal ? "of \(Fmt.bytes(s.memoryTotal))" : pressureText(s.pressure),
                   history: store.memHistory.ordered, ceiling: 100, tint: .purple)
            Divider().padding(.vertical, 4)
            Metric(title: "Network", value: "↓" + Fmt.rate(s.netIn), detail: "↑ " + Fmt.rate(s.netOut) + " up",
                   history: store.netInHistory.ordered, ceiling: nil, tint: .teal)
            Divider().padding(.vertical, 4)
            Metric(title: "Temperature", value: s.temperature.map(Fmt.temp) ?? "–", detail: "Hottest core",
                   history: store.tempHistory.ordered, ceiling: 100, tint: .orange)
            Divider().padding(.vertical, 4)
            Metric(title: "Power", value: s.power.map(Fmt.watts) ?? "–", detail: batteryText(s),
                   history: store.powerHistory.ordered, ceiling: nil, tint: .green)
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

    // MARK: Top apps

    private var topApps: some View {
        let top = Array(store.apps.sorted { $0.cpu > $1.cpu }.prefix(7))
        let maxCPU = max(top.first?.cpu ?? 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Busiest apps").font(.headline)
            if top.isEmpty {
                ProgressView().controlSize(.small).padding(.vertical, 8)
            }
            ForEach(top) { g in
                Button { openApp(g.id) } label: {
                    HStack(spacing: 10) {
                        AppIcon(key: g.id, size: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(g.name).lineLimit(1)
                                Spacer()
                                Text(Fmt.percent(g.cpu)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Capsule().fill(.blue.opacity(0.75))
                                .frame(width: nil, height: 4)
                                .scaleEffect(x: max(0.02, g.cpu / maxCPU), anchor: .leading)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(g.name)'s processes")
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: top.map(\.id))
    }

    // MARK: Closable

    private var closable: some View {
        let items = store.apps
            .filter { $0.nonCritical && $0.killable && $0.memory >= 30 * 1024 * 1024 }
            .sorted { $0.memory > $1.memory }
            .prefix(7)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Running but not used").font(.headline)
                Text("Apps you have not switched to in \(Int(Store.unusedAfter / 60)) minutes, and background work idle for \(Int(ProcessSampler.idleAfter / 60)) minutes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text(store.apps.isEmpty ? "Measuring…" : "Nothing idle right now.")
                    .foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(Array(items)) { g in
                HStack(spacing: 10) {
                    AppIcon(key: g.id, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.name).lineLimit(1)
                        if let st = g.statusText { TagLabel(text: st.0, tone: st.1) }
                    }
                    Spacer()
                    Text(Fmt.bytes(g.memory)).monospacedDigit().foregroundStyle(.secondary)
                    StopButton(title: g.isAppBundle ? "Quit" : "Stop") { force in
                        withAnimation(reduceMotion ? nil : .smooth) { store.stop(app: g.id, force: force) }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: items.map(\.id))
    }
}

private struct Metric: View {
    let title: String
    let value: String
    let detail: String
    let history: [Double]
    let ceiling: Double?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Sparkline(values: history, ceiling: ceiling, tint: tint)
                .frame(height: 44)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
        .help("\(title) now. Option-click to force.")
    }
}
