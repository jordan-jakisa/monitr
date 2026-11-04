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
            ChartHeader(value: Fmt.percent(s.cpu), caption: "of all cores in use", ring: store.cpuHistory, ceiling: 100, tint: .blue, peak: Fmt.percent)
        case .memory:
            ChartHeader(value: Fmt.bytes(s.memoryUsed), caption: "of \(Fmt.bytes(s.memoryTotal)) RAM in use", ring: store.memHistory, ceiling: 100, tint: .purple,
                        peak: { Fmt.bytes(UInt64($0 / 100 * Double(s.memoryTotal))) })
        case .network:
            ChartHeader(value: "↓" + Fmt.rate(s.netIn), caption: "down, ↑ \(Fmt.rate(s.netOut)) up", ring: store.netInHistory, ceiling: nil, tint: .teal, peak: Fmt.rate)
        case .temperature:
            // On this page the sensor list is read live; show its hottest core so the two agree.
            let hottest = store.detail?.sensors?.first { $0.title == "CPU cores" }?.hottest ?? s.temperature
            ChartHeader(value: hottest.map(Fmt.temp) ?? "–", caption: "hottest CPU core", ring: store.tempHistory, ceiling: 100, tint: .orange, peak: Fmt.temp)
        case .power:
            ChartHeader(value: s.power.map(Fmt.watts) ?? "–", caption: "the whole Mac is drawing", ring: store.powerHistory, ceiling: nil, tint: .green, peak: Fmt.watts)
        }
    }
}

private struct ChartHeader: View {
    let value: String
    let caption: String
    let ring: Ring
    let ceiling: Double?
    let tint: Color
    var peak: ((Double) -> String)? = nil

    private var span: String {
        let minutes = ring.count * Store.shared.interval / 60
        let base = minutes < 1 ? "Last minute" : "Last \(minutes) \(minutes == 1 ? "minute" : "minutes")"
        guard let peak, let top = ring.ordered.max(), ring.count > 1 else { return base }
        return "\(base), peak \(peak(top))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(caption).foregroundStyle(.secondary)
            }
            Sparkline(ring: ring, ceiling: ceiling, tint: tint, hoverFormat: peak ?? { Fmt.percent($0) })
                .frame(height: 120)
            Text(span).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, Space.xs)
    }
}

/// A "label: value" row that reads well with VoiceOver and keeps values in tabular digits.
private struct Fact: View {
    let label: String
    let value: String
    var note: String? = nil
    var swatch: Color? = nil   // ties the row to its colour in a chart above
    var body: some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            HStack(spacing: Space.s) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(swatch.opacity(0.85))
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                }
                Text(label)
            }
            if let note { Text(note).padding(.leading, swatch == nil ? 0 : 18) }
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
            let available = d.cached + d.free
            Section {
                MemoryBar(d: d)
                Fact(label: "Apps", value: Fmt.bytes(d.app), note: "Memory apps and their processes are using", swatch: .purple)
                Fact(label: "macOS (wired)", value: Fmt.bytes(d.wired), note: "Reserved by macOS itself; can't be freed", swatch: .orange)
                Fact(label: "Compressed", value: Fmt.bytes(d.compressed),
                     note: "App memory squeezed to fit in RAM; a lot of it means RAM is tight", swatch: .pink)
                Fact(label: "Pressure", value: pressureText(Store.shared.system.pressure), note: pressureNote(Store.shared.system.pressure))
            } header: {
                SectionHeading(title: "RAM in use", value: "\(Fmt.bytes(d.used)) of \(Fmt.bytes(d.total))")
            }
            Section {
                Fact(label: "Cached files", value: Fmt.bytes(d.cached),
                     note: "Kept to open files faster; handed to apps the moment they need it", swatch: .teal)
                Fact(label: "Free", value: Fmt.bytes(d.free), note: "Not used at all", swatch: Color.primary.opacity(0.18))
            } header: {
                SectionHeading(title: "RAM available", value: Fmt.bytes(available))
            }
            Section {
                if d.swapTotal > 0 {
                    SwapBar(used: d.swapUsed, total: d.swapTotal)
                }
                Fact(label: "In swap", value: d.swapTotal == 0 ? "None" : "\(Fmt.bytes(d.swapUsed)) of \(Fmt.bytes(d.swapTotal))",
                     note: "App memory that did not fit in RAM, parked in a file on the SSD")
                Fact(label: "Moving in and out now", value: swapActivity(d),
                     note: "Constant movement here is what makes a Mac feel slow")
            } header: {
                SectionHeading(title: "Swap, on the SSD", value: Fmt.bytes(d.swapUsed))
            } footer: {
                FormNote("Swap is not RAM. macOS uses it as overflow when RAM is full, and it is many times slower. A little is normal; gigabytes plus steady movement mean the Mac needs more RAM for what is open.")
            }
        } else {
            Section { Pending() }
        }
    }

    private func pressureNote(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: "RAM is enough for what is open"
        case .warning: "macOS is compressing and swapping to keep up. Quitting a big app helps."
        case .critical: "RAM is exhausted; apps will slow down. Quit apps you are not using."
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

/// A section title with its total on the right, like "In use      13.3 GB".
private struct SectionHeading: View {
    let title: String
    let value: String
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// All of RAM in one bar: what is in use, a gap, then what is available.
private struct MemoryBar: View {
    let d: MemoryDetail
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            GeometryReader { geo in
                let total = Double(max(d.total, 1))
                let w = geo.size.width - 6
                HStack(spacing: 2) {
                    seg(d.app, .purple, w, total)
                    seg(d.wired, .orange, w, total)
                    seg(d.compressed, .pink, w, total)
                    Spacer().frame(width: 4)
                    seg(d.cached, .teal, w, total)
                    Rectangle().fill(Color.primary.opacity(0.18))
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            HStack {
                Text("RAM in use").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Available").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Fmt.bytes(d.used)) in use, \(Fmt.bytes(d.cached + d.free)) available")
    }

    private func seg(_ v: UInt64, _ c: Color, _ w: CGFloat, _ total: Double) -> some View {
        Rectangle().fill(c.opacity(0.85)).frame(width: max(0, w * CGFloat(Double(v) / total) - 2))
    }
}

/// How full the swap file is, drawn apart from RAM so the two are never confused.
private struct SwapBar: View {
    let used: UInt64
    let total: UInt64
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            UsageBar(fraction: Double(used) / Double(max(total, 1)), tint: .indigo).frame(height: 12)
            HStack {
                Text("Swap used").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.bytes(total)) swap file").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Fmt.bytes(used)) of \(Fmt.bytes(total)) swap used")
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
    @State private var hovered: Int?

    var body: some View {
        HStack(alignment: .bottom, spacing: Space.s) {
            ForEach(cores) { c in
                VStack(spacing: Space.xs) {
                    // The value appears on hover, right above its bar.
                    Text(Fmt.percent(c.load))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .opacity(hovered == c.id ? 1 : 0)
                    UsageBar(fraction: c.load / 100, tint: c.efficiency ? .teal : .blue, vertical: true)
                        .frame(height: 64)
                        .opacity(hovered == nil || hovered == c.id ? 1 : 0.55)
                    Text(c.efficiency ? "E" : "P").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onHover { inside in hovered = inside ? c.id : (hovered == c.id ? nil : hovered) }
                .help("Core \(c.id + 1), \(c.efficiency ? "efficiency" : "performance")")
            }
        }
        .motion(Motion.feedback, value: hovered)
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
                FormNote("Counted from \(usage.since.formatted(date: .abbreviated, time: .shortened)), when Monitr first ran. Includes Wi-Fi, Ethernet and phone tethering; VPN traffic is not counted twice.")
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
                FormNote("Per-app totals come from macOS's own network statistics, checked every minute (every few seconds while this window is open). Traffic from an app that quits between checks can be missed; the Mac's total above is exact.")
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
                FormNote("Macs have no per-app temperature. Power use per app, below, shows which apps are heating it.")
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
    @State private var byProcess = false

    var body: some View {
        Section {
            if store.apps.isEmpty { Pending() }
            if byProcess {
                ForEach(topProcesses) { p in
                    HStack(spacing: Space.s) {
                        AppIcon(key: p.appKey, size: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.name).lineLimit(1)
                            Text(p.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(p.measured ? format(procValue(p)) : "–").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(topApps) { g in
                    DisclosureGroup {
                        ForEach(members(of: g)) { p in
                            HStack {
                                Text(p.name).lineLimit(1)
                                Spacer()
                                Text(p.measured ? format(procValue(p)) : "–").monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                        NavigationLink("Show all \(g.count) processes of \(g.name)",
                                       value: AppRoute(key: g.id, backTitle: kind.title))
                            .buttonStyle(.link)
                            .font(.callout)
                    } label: {
                        HStack(spacing: Space.s) {
                            AppIcon(key: g.id, size: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(g.name).lineLimit(1)
                                Text("\(g.count) \(g.count == 1 ? "process" : "processes")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(format(appValue(g))).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Picker("Show", selection: $byProcess) {
                    Text("Apps").tag(false)
                    Text("Processes").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        } footer: {
            FormNote(byProcess ? "Each process on its own, like Activity Monitor." : "Each app with all of its helper processes added up. Open one to see what is inside.")
        }
    }

    private var title: String {
        switch kind {
        case .cpu: "Using the most CPU"
        case .memory: "Using the most memory"
        case .network: "Using the network now"
        case .temperature, .power: "Using the most power"
        }
    }

    private func appValue(_ g: AppGroup) -> Double {
        switch kind {
        case .cpu: g.cpu
        case .memory: Double(g.memory)
        case .network: g.netIn + g.netOut
        case .temperature, .power: g.power
        }
    }

    private func procValue(_ p: ProcInfo) -> Double {
        switch kind {
        case .cpu: p.cpu
        case .memory: Double(p.memory)
        case .network: p.netIn + p.netOut
        case .temperature, .power: p.power ?? 0
        }
    }

    private func format(_ v: Double) -> String {
        switch kind {
        case .cpu: Fmt.percent(v)
        case .memory: Fmt.bytes(UInt64(max(v, 0)))
        case .network: Fmt.rate(v)
        case .temperature, .power: Fmt.watts(v)
        }
    }

    private var threshold: Double {
        switch kind {
        case .cpu: 0.1
        case .memory: 1
        case .network: 1
        case .temperature, .power: 0.001
        }
    }

    private var topApps: [AppGroup] {
        Array(store.apps.filter { appValue($0) >= threshold }.sorted { appValue($0) > appValue($1) }.prefix(8))
    }

    private var topProcesses: [ProcInfo] {
        Array(store.processes.filter { $0.measured && procValue($0) >= threshold }
            .sorted { procValue($0) > procValue($1) }.prefix(15))
    }

    private func members(of g: AppGroup) -> [ProcInfo] {
        Array(store.processes.filter { $0.appKey == g.id }.sorted { procValue($0) > procValue($1) }.prefix(6))
    }
}
