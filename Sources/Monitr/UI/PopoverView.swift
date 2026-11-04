import SwiftUI

/// The panel under the menu bar icon: the key numbers and the busiest apps.
struct PopoverView: View {
    @Environment(Store.self) private var store
    let openWindow: () -> Void

    private var topApps: [AppGroup] { Array(store.busiest.prefix(5)) }

    var body: some View {
        let s = store.system
        let hasTemp = s.temperature != nil
        VStack(alignment: .leading, spacing: Space.l) {
            Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.m) {
                GridRow {
                    Stat(label: "CPU", value: Fmt.percent(s.cpu), ring: store.cpuHistory, ceiling: 100, tint: .blue)
                    Stat(label: "Memory", value: Fmt.bytes(s.memoryUsed), ring: store.memHistory, ceiling: 100, tint: .purple)
                }
                GridRow {
                    Stat(label: "Network", value: "↓\(Fmt.shortRate(s.netIn)) ↑\(Fmt.shortRate(s.netOut))",
                         ring: store.netInHistory, ceiling: nil, tint: .teal)
                    Stat(label: hasTemp ? "Temperature" : "Power",
                         value: s.temperature.map(Fmt.temp) ?? s.power.map(Fmt.watts) ?? "–",
                         ring: hasTemp ? store.tempHistory : store.powerHistory,
                         ceiling: hasTemp ? 100 : nil, tint: .orange)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: Space.s) {
                Text("Busiest apps").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                let top = topApps
                if top.isEmpty { ProgressView().controlSize(.small) }
                ForEach(top) { g in
                    HStack(spacing: Space.s) {
                        AppIcon(key: g.id, size: 18)
                        Text(g.name).lineLimit(1)
                        Spacer()
                        Text(Fmt.bytes(g.memory)).foregroundStyle(.secondary)
                        Text(Fmt.percent(g.cpu)).frame(width: 48, alignment: .trailing)
                    }
                    .monospacedDigit()
                    .transition(.opacity)
                }
            }
            .motion(Motion.list, value: topApps.map(\.id))

            Divider()

            HStack {
                Button("Open Monitr", action: openWindow)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Quit Monitr") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(Space.l)
        .frame(width: 336)
    }
}

private struct Stat: View {
    let label: String
    let value: String
    let ring: Ring
    let ceiling: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Sparkline(ring: ring, ceiling: ceiling, tint: tint).frame(height: 28)
        }
        .frame(width: 144, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
