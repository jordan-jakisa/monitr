import SwiftUI

/// The panel under the menu bar icon: the key numbers and the busiest apps.
struct PopoverView: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openWindow: () -> Void

    private var topApps: [AppGroup] { Array(store.apps.sorted { $0.cpu > $1.cpu }.prefix(5)) }

    var body: some View {
        let s = store.system
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Stat(label: "CPU", value: Fmt.percent(s.cpu), history: store.cpuHistory.ordered, ceiling: 100, tint: .blue)
                    Stat(label: "Memory", value: Fmt.percent(s.memoryFraction * 100), history: store.memHistory.ordered, ceiling: 100, tint: .purple)
                }
                GridRow {
                    Stat(label: "Network", value: "↓\(Fmt.shortRate(s.netIn)) ↑\(Fmt.shortRate(s.netOut))",
                         history: store.netInHistory.ordered, ceiling: nil, tint: .teal)
                    Stat(label: s.temperature != nil ? "Temperature" : "Power",
                         value: s.temperature.map(Fmt.temp) ?? s.power.map(Fmt.watts) ?? "–",
                         history: s.temperature != nil ? store.tempHistory.ordered : store.powerHistory.ordered,
                         ceiling: s.temperature != nil ? 100 : nil, tint: .orange)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Busiest apps").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                let top = topApps
                if top.isEmpty { ProgressView().controlSize(.small) }
                ForEach(top) { g in
                    HStack(spacing: 8) {
                        AppIcon(key: g.id, size: 18)
                        Text(g.name).lineLimit(1)
                        Spacer()
                        Text(Fmt.bytes(g.memory)).foregroundStyle(.secondary)
                        Text(Fmt.percent(g.cpu)).frame(width: 48, alignment: .trailing)
                    }
                    .monospacedDigit()
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: topApps.map(\.id))

            Divider()

            HStack {
                Button("Open Monitr", action: openWindow)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 330)
    }
}

private struct Stat: View {
    let label: String
    let value: String
    let history: [Double]
    let ceiling: Double?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit().lineLimit(1)
            Sparkline(values: history, ceiling: ceiling, tint: tint).frame(height: 26)
        }
        .frame(width: 140, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
