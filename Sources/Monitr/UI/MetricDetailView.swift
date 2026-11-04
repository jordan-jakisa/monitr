import SwiftUI

/// The page behind each metric on the Overview: the full breakdown and the apps driving it.
struct MetricDetailView: View {
    @Environment(Store.self) private var store
    let kind: MetricKind

    var body: some View {
        let d = store.detail?.kind == kind ? store.detail : nil
        Form {
            Section { header }
            switch kind {
            case .memory: MemorySections(d: d?.memory)
            case .cpu: CPUSections(d: d?.cpu)
            case .network: NetworkSections(interfaces: d?.interfaces, usage: d?.usage)
            case .temperature: TemperatureSections(groups: d?.sensors)
            case .power: PowerSections(d: d?.power)
            }
            TopAppsSection(kind: kind)
        }
        .formStyle(.grouped)
        .navigationTitle(kind.title)
        .onAppear { Engine.shared.setDetail(kind) }
        .onDisappear { Engine.shared.setDetail(nil) }
    }

    @ViewBuilder
    private var header: some View {
        let s = store.system
        switch kind {
        case .cpu:
            ChartHeader(value: Fmt.percent(s.cpu), caption: "of all cores in use", ring: store.cpuHistory, ceiling: 100, tint: .blue)
        case .memory:
            ChartHeader(value: Fmt.bytes(s.memoryUsed), caption: "used of \(Fmt.bytes(s.memoryTotal))", ring: store.memHistory, ceiling: 100, tint: .purple)
        case .network:
            ChartHeader(value: "↓" + Fmt.rate(s.netIn), caption: "↑ \(Fmt.rate(s.netOut)) up, all apps", ring: store.netInHistory, ceiling: nil, tint: .teal)
        case .temperature:
            ChartHeader(value: s.temperature.map(Fmt.temp) ?? "–", caption: "hottest CPU core", ring: store.tempHistory, ceiling: 100, tint: .orange)
        case .power:
            ChartHeader(value: s.power.map(Fmt.watts) ?? "–", caption: "the whole Mac is drawing", ring: store.powerHistory, ceiling: nil, tint: .green)
        }
    }
}

private struct ChartHeader: View {
    let value: String
    let caption: String
    let ring: Ring
    let ceiling: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(caption).foregroundStyle(.secondary)
            }
            Sparkline(ring: ring, ceiling: ceiling, tint: tint)
                .frame(height: 120)
            Text("Last \(ring.capacity * Store.shared.interval / 60) minutes").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, Space.xs)
    }
}

/// A "label: value" row that reads well with VoiceOver and keeps values in tabular digits.
private struct Fact: View {
    let label: String
    let value: String
    var note: String? = nil
    var body: some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            Text(label)
            if let note { Text(note) }
        }
    }
}

private struct Pending: View {
    var body: some View { HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) } }
}

// MARK: Memory

private struct MemorySections: View {
    let d: MemoryDetail?

    var body: some View {
        if let d {
            Section("Where it goes") {
                SegmentBar(parts: [
                    (d.app, .purple), (d.wired, .orange), (d.compressed, .pink), (d.cached, .teal),
                ], total: d.total)
                Fact(label: "App memory", value: Fmt.bytes(d.app), note: "Used by apps and their processes")
                Fact(label: "Wired", value: Fmt.bytes(d.wired), note: "Kept by macOS; can't be compressed or swapped")
                Fact(label: "Compressed", value: Fmt.bytes(d.compressed), note: "Squeezed in RAM to make room")
                Fact(label: "Cached files", value: Fmt.bytes(d.cached), note: "Recently used files; freed when needed")
                Fact(label: "Free", value: Fmt.bytes(d.free))
            }
            Section("Swap") {
                Fact(label: "Swap used", value: d.swapTotal == 0 ? "None" : "\(Fmt.bytes(d.swapUsed)) of \(Fmt.bytes(d.swapTotal))",
                     note: "Memory written to the SSD when RAM runs short")
                Fact(label: "Swapping now", value: swapActivity(d))
                Fact(label: "Pressure", value: pressureText(Store.shared.system.pressure),
                     note: "Green on the Mac's own scale means there is room to spare")
            }
        } else {
            Section { Pending() }
        }
    }

    private func swapActivity(_ d: MemoryDetail) -> String {
        let pages = (d.swapInsPerSec + d.swapOutsPerSec) * Double(vm_kernel_page_size)
        return pages < 1 ? "No" : "\(Fmt.rate(pages))"
    }

    private func pressureText(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

/// One bar split by share of a total, with no labels inside (the rows below name each part).
private struct SegmentBar: View {
    let parts: [(UInt64, Color)]
    let total: UInt64
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Rectangle().fill(p.1.opacity(0.85))
                        .frame(width: max(0, geo.size.width * CGFloat(Double(p.0) / Double(max(total, 1))) - 2))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: CPU

private struct CPUSections: View {
    let d: CPUDetail?

    var body: some View {
        if let d {
            Section("Split") {
                Fact(label: "Apps", value: Fmt.percent(d.user), note: "Work done for apps and tools")
                Fact(label: "macOS", value: Fmt.percent(d.system), note: "Work done by the system kernel")
                Fact(label: "Idle", value: Fmt.percent(d.idle))
            }
            Section("Cores") {
                CoreChart(cores: d.cores)
                Fact(label: "Performance cores", value: "\(d.performanceCores)", note: "Fast cores for heavy work")
                Fact(label: "Efficiency cores", value: "\(d.efficiencyCores)", note: "Low-power cores for background work")
            }
            Section("System") {
                Fact(label: "Load average", value: String(format: "%.2f  %.2f  %.2f", d.load.0, d.load.1, d.load.2),
                     note: "Waiting work over 1, 5 and 15 minutes")
                Fact(label: "Up for", value: Fmt.duration(d.uptime))
                Fact(label: "Processes", value: "\(Store.shared.processes.count)")
            }
        } else {
            Section { Pending() }
        }
    }
}

private struct CoreChart: View {
    let cores: [CoreLoad]
    var body: some View {
        HStack(alignment: .bottom, spacing: Space.s) {
            ForEach(cores) { c in
                VStack(spacing: Space.xs) {
                    UsageBar(fraction: c.load / 100, tint: c.efficiency ? .teal : .blue, vertical: true)
                        .frame(height: 64)
                    Text(c.efficiency ? "E" : "P").font(.caption2).foregroundStyle(.secondary)
                }
                .help("Core \(c.id + 1), \(c.efficiency ? "efficiency" : "performance"): \(Fmt.percent(c.load))")
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Per-core load")
        .accessibilityValue(cores.map { "\(Int($0.load))%" }.joined(separator: ", "))
    }
}

// MARK: Network

private struct NetworkSections: View {
    let interfaces: [InterfaceInfo]?
    let usage: UsageSummary?
    @State private var period = "Today"

    var body: some View {
        if let usage {
            Section {
                ForEach(usage.periods) { p in
                    Fact(label: p.title, value: Fmt.bytes(p.total), note: "↓ \(Fmt.bytes(p.received)) received, ↑ \(Fmt.bytes(p.sent)) sent")
                }
                DailyBars(days: usage.daily)
            } header: {
                Text("Data used")
            } footer: {
                Text("Counted from \(usage.since.formatted(date: .abbreviated, time: .shortened)), when Monitr first ran. Includes Wi-Fi, Ethernet and phone tethering; VPN traffic is not counted twice.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Period", selection: $period) {
                    ForEach(usage.periods) { Text($0.title).tag($0.title) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                let apps = usage.periods.first { $0.title == period }?.apps ?? []
                if apps.isEmpty {
                    Text("No app data yet for this period.").foregroundStyle(.secondary)
                }
                ForEach(apps) { a in
                    LabeledContent {
                        Text(Fmt.bytes(a.total)).monospacedDigit()
                    } label: {
                        Text(a.name)
                        Text("↓ \(Fmt.bytes(a.received))  ↑ \(Fmt.bytes(a.sent))")
                    }
                }
            } header: {
                Text("Data used by app")
            } footer: {
                Text("Per-app totals come from macOS's own network statistics, checked every minute (every few seconds while this window is open). Traffic from an app that quits between checks can be missed; the Mac's total above is exact.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section { Pending() }
        }
        if let interfaces, !interfaces.isEmpty {
            Section("Connections since the Mac started") {
                ForEach(interfaces) { i in
                    LabeledContent {
                        Text("↓ \(Fmt.bytes(i.received))  ↑ \(Fmt.bytes(i.sent))").monospacedDigit()
                    } label: {
                        Text(i.kind)
                        Text([i.name, i.address].compactMap { $0 }.joined(separator: ", "))
                    }
                }
            }
        }
    }
}

/// Fourteen days of data use, one bar per day, today on the right.
private struct DailyBars: View {
    let days: [DayTotal]
    var body: some View {
        let top = Double(days.map(\.total).max() ?? 0)
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .bottom, spacing: Space.xs) {
                ForEach(days) { d in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.teal.opacity(Calendar.current.isDateInToday(d.date) ? 0.9 : 0.55))
                        .frame(height: top == 0 ? 2 : max(2, 56 * Double(d.total) / top))
                        .frame(maxWidth: .infinity)
                        .help("\(d.date.formatted(.dateTime.weekday(.wide).day().month())): \(Fmt.bytes(d.total))")
                }
            }
            .frame(height: 56, alignment: .bottom)
            HStack {
                Text("14 days ago")
                Spacer()
                Text("Today")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Data used per day, last 14 days")
    }
}

// MARK: Temperature

private struct TemperatureSections: View {
    let groups: [SensorGroup]?

    var body: some View {
        Section("Now") {
            Fact(label: "Heat level", value: thermal(ProcessInfo.processInfo.thermalState),
                 note: "macOS slows the chip when this reaches Serious")
            if let cpu = groups?.first(where: { $0.title == "CPU cores" }) {
                Fact(label: "CPU cores", value: "\(Fmt.temp(cpu.average)) average, \(Fmt.temp(cpu.hottest)) hottest")
            }
            ForEach(groups?.filter { $0.title != "CPU cores" } ?? []) { g in
                Fact(label: g.title, value: Fmt.temp(g.hottest))
            }
        }
        if let groups {
            Section {
                ForEach(groups) { g in
                    DisclosureGroup("\(g.title) (\(g.readings.count) sensors)") {
                        ForEach(g.readings) { r in Fact(label: r.name, value: Fmt.temp(r.value)) }
                    }
                }
            } header: {
                Text("Every sensor")
            } footer: {
                Text("Macs have no per-app temperature. Power use per app, below, shows which apps are heating it.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section { Pending() }
        }
    }

    private func thermal(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

// MARK: Power

private struct PowerSections: View {
    let d: PowerDetail?

    var body: some View {
        if let d {
            Section("Charging") {
                Fact(label: "Status", value: status(d))
                if let p = d.percent { Fact(label: "Battery", value: "\(p)%") }
                if let m = d.minutesToFull { Fact(label: "Full in", value: Fmt.duration(Double(m) * 60)) }
                if let m = d.minutesToEmpty { Fact(label: "Time left", value: Fmt.duration(Double(m) * 60)) }
                if d.onAdapter {
                    Fact(label: "Adapter", value: [d.adapterName, d.adapterRating.map { "\($0) W" }].compactMap { $0 }.first ?? "Connected")
                    if let w = d.adapterInWatts { Fact(label: "Drawing from adapter", value: Fmt.watts(w)) }
                }
                if let w = d.systemWatts { Fact(label: "Mac is using", value: Fmt.watts(w)) }
            }
            Section("Battery health") {
                if let h = d.health { Fact(label: "Maximum capacity", value: "\(Int((h * 100).rounded()))%", note: "Compared with when it was new") }
                if let c = d.cycleCount { Fact(label: "Charge cycles", value: "\(c)") }
                if let f = d.fullChargeMah, let des = d.designMah { Fact(label: "Full charge", value: "\(f) of \(des) mAh") }
                if let v = d.voltage { Fact(label: "Voltage", value: String(format: "%.2f V", v)) }
                if let a = d.amperage { Fact(label: "Current", value: "\(a) mA", note: a < 0 ? "Negative: the battery is powering the Mac" : nil) }
            }
        } else {
            Section { Pending() }
        }
    }

    private func status(_ d: PowerDetail) -> String {
        if d.charging { return "Charging" }
        if d.onAdapter && d.fullyCharged { return "Fully charged" }
        if d.onAdapter { return "On power adapter, not charging" }
        return d.percent == nil ? "No battery" : "On battery"
    }
}

// MARK: Top apps

private struct TopAppsSection: View {
    @Environment(Store.self) private var store
    let kind: MetricKind

    var body: some View {
        let rows = ranked
        Section(title) {
            if store.apps.isEmpty { Pending() }
            ForEach(rows, id: \.0.id) { g, value in
                HStack(spacing: Space.s) {
                    AppIcon(key: g.id, size: 18)
                    Text(g.name).lineLimit(1)
                    Spacer()
                    Text(value).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .motion(Motion.list, value: rows.map(\.0.id))
    }

    private var title: String {
        switch kind {
        case .cpu: "Apps using the most CPU"
        case .memory: "Apps using the most memory"
        case .network: "Apps using the network now"
        case .temperature, .power: "Apps using the most power"
        }
    }

    private var ranked: [(AppGroup, String)] {
        let apps = store.apps
        let list: [(AppGroup, String)]
        switch kind {
        case .cpu:
            list = apps.filter { $0.cpu >= 0.1 }.sorted { $0.cpu > $1.cpu }.map { ($0, Fmt.percent($0.cpu)) }
        case .memory:
            list = apps.filter { $0.memory > 0 }.sorted { $0.memory > $1.memory }.map { ($0, Fmt.bytes($0.memory)) }
        case .network:
            list = apps.filter { $0.netIn + $0.netOut >= 1 }.sorted { $0.netIn + $0.netOut > $1.netIn + $1.netOut }
                .map { ($0, Fmt.traffic(down: $0.netIn, up: $0.netOut)) }
        case .temperature, .power:
            list = apps.filter { $0.power > 0.001 }.sorted { $0.power > $1.power }.map { ($0, Fmt.watts($0.power)) }
        }
        return Array(list.prefix(8))
    }
}
