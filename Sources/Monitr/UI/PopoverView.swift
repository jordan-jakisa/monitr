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

            PreventSleepRow()
            QuickQuitRow()

            Divider()

            HStack {
                Button("Open Monitr") {
                    NSApp.keyWindow?.close()   // the panel, so the main window comes to the front
                    openWindow()
                }
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Quit Monitr") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(Space.l)
        .frame(width: 336)
        .onAppear {
            Engine.shared.setViewer("popover", active: true)
            Store.shared.popoverOpen = true
        }
        .onDisappear {
            Engine.shared.setViewer("popover", active: false)
            Store.shared.popoverOpen = false
        }
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
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Sparkline(ring: ring, ceiling: ceiling, tint: tint).frame(height: 28)
        }
        .frame(width: 144, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One switch to keep the Mac awake, with how long beside it and whether the screen stays on.
private struct PreventSleepRow: View {
    @State private var guardian = SleepGuard.shared

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: guardian.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.title3)
                .foregroundStyle(guardian.isOn ? Color.accentColor : .secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Prevent sleep")
                Text(guardian.isOn ? guardian.detail : (guardian.keepDisplayOn ? "Off, display stays on when on" : "Off"))
                    .font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: Space.s)
            Menu {
                ForEach(SleepGuard.Length.choices) { length in
                    Button {
                        guardian.turnOn(length)
                    } label: {
                        if guardian.lastLength == length {
                            Label(length.title, systemImage: "checkmark")
                        } else {
                            Text(length.title)
                        }
                    }
                }
                Divider()
                Toggle("Keep display on", isOn: $guardian.keepDisplayOn)
            } label: {
                Text(guardian.lastLength.title).font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("How long to stay awake, and whether the display stays on")
            Toggle("Prevent sleep", isOn: Binding(get: { guardian.isOn }, set: { _ in guardian.toggle() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Quits the saved Quick quit apps; shown only once the list has apps in it.
private struct QuickQuitRow: View {
    @State private var quick = QuickQuit.shared

    var body: some View {
        if !quick.entries.isEmpty {
            let n = quick.runningCount
            HStack(spacing: Space.m) {
                Image(systemName: "xmark.square")
                    .font(.title3).foregroundStyle(.secondary).frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Quick quit")
                    Text(n == 0 ? "None of your apps are running" : "\(n) of \(quick.entries.count) apps running")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit \(n)") { quick.quitAll() }
                    .controlSize(.small)
                    .disabled(n == 0)
            }
        }
    }
}
