import SwiftUI

struct DashboardView: View {
    @Environment(Store.self) private var store
    var openApp: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                metrics
                HStack(alignment: .top, spacing: Space.xxl) {
                    topApps.frame(maxWidth: .infinity, alignment: .topLeading)
                    closable.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(Space.xl)
        }
    }

    // MARK: Metrics row

    private var metrics: some View {
        let s = store.system
        return HStack(alignment: .top, spacing: 0) {
            Metric(title: "CPU", value: Fmt.percent(s.cpu), detail: thermalText(s.thermal),
                   ring: store.cpuHistory, ceiling: 100, tint: .blue)
            Divider().padding(.vertical, Space.xs)
            Metric(title: "Memory", value: Fmt.bytes(s.memoryUsed),
                   detail: s.pressure == .normal ? "of \(Fmt.bytes(s.memoryTotal))" : pressureText(s.pressure),
                   ring: store.memHistory, ceiling: 100, tint: .purple)
            Divider().padding(.vertical, Space.xs)
            Metric(title: "Network", value: "↓" + Fmt.rate(s.netIn), detail: "↑ " + Fmt.rate(s.netOut) + " up",
                   ring: store.netInHistory, ceiling: nil, tint: .teal)
            Divider().padding(.vertical, Space.xs)
            Metric(title: "Temperature", value: s.temperature.map(Fmt.temp) ?? "–", detail: "Hottest core",
                   ring: store.tempHistory, ceiling: 100, tint: .orange)
            Divider().padding(.vertical, Space.xs)
            Metric(title: "Power", value: s.power.map(Fmt.watts) ?? "–", detail: batteryText(s),
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

    // MARK: Busiest apps

    private var topApps: some View {
        let top = Array(store.apps.sorted { $0.cpu > $1.cpu }.prefix(7))
        let maxCPU = max(top.first?.cpu ?? 1, 1)
        return VStack(alignment: .leading, spacing: Space.xs) {
            SectionTitle(title: "Busiest apps", detail: "By CPU. Click one to see its processes.")
            if top.isEmpty {
                ProgressView().controlSize(.small).padding(.vertical, Space.s)
            }
            ForEach(top) { g in
                Button { openApp(g.id) } label: {
                    HStack(spacing: Space.m) {
                        AppIcon(key: g.id, size: 20)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            HStack {
                                Text(g.name).lineLimit(1)
                                Spacer()
                                Text(Fmt.percent(g.cpu)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            UsageBar(fraction: g.cpu / maxCPU, tint: .blue)
                        }
                    }
                }
                .buttonStyle(RowButtonStyle())
                .padding(.horizontal, -Space.s)
                .help("Show \(g.name)'s processes")
                .transition(.opacity)
            }
        }
        .motion(Motion.list, value: top.map(\.id))
    }

    // MARK: Running but not used

    private var closable: some View {
        let items = Array(store.apps
            .filter { $0.nonCritical && $0.killable && $0.memory >= 30 * 1024 * 1024 }
            .sorted { $0.memory > $1.memory }
            .prefix(7))
        return VStack(alignment: .leading, spacing: Space.xs) {
            SectionTitle(
                title: "Running but not used",
                detail: "Apps you have not switched to in \(Int(Store.unusedAfter / 60)) minutes, and background work idle for \(Int(ProcessSampler.idleAfter / 60)) minutes."
            )
            if items.isEmpty {
                Label(store.apps.isEmpty ? "Measuring…" : "Nothing idle right now.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Space.s)
                    .transition(.opacity)
            }
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
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .motion(Motion.list, value: items.map(\.id))
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

/// A thin track with a fill that eases to its new length.
struct UsageBar: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(tint.opacity(0.8))
                        .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
                }
            }
            .motion(Motion.data, value: fraction)
    }
}

private struct Metric: View {
    let title: String
    let value: String
    let detail: String
    let ring: Ring
    let ceiling: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
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
        .padding(.horizontal, Space.l)
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
        .motion(Motion.feedback, value: hovering)
        .help("\(title) now. Option-click to force.")
    }
}
