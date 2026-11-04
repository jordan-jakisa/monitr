import Foundation

/// Owns the samplers. Touched only on its own serial queue.
private final class Worker: @unchecked Sendable {
    let queue = DispatchQueue(label: "monitr.sampler", qos: .utility, autoreleaseFrequency: .workItem)
    let system = SystemSampler()
    let processes = ProcessSampler()
    let details = DetailSampler()
    let usage = UsageTracker()
    let network = NetworkSampler()
    var detailed = false
    var detailKind: MetricKind?
    var interval = 2
    private var lastProcAt: UInt64 = 0
    private var ticks = 0
    private var lastNet: NetworkSampler.Snapshot?
    private var netRates: [pid_t: (Double, Double)] = [:]

    func resetProcesses() {
        processes.reset()
        lastProcAt = 0
    }

    /// Takes a network snapshot: every ~4 s while live rates are on screen, every minute otherwise.
    func snapshotNetworkIfDue(force: Bool = false) {
        let every = detailed ? max(1, 4 / interval) : max(1, 60 / interval)
        guard force || ticks % every == 0 else { return }
        network.snapshot(on: queue) { [weak self] snap in self?.ingest(snap) }
    }

    /// Turns two lifetime snapshots into bytes moved per pid: rates for the table, per-app
    /// totals for data usage. A process that started between snapshots counts in full.
    private func ingest(_ snap: NetworkSampler.Snapshot) {
        defer { lastNet = snap }
        guard let prev = lastNet, snap.at > prev.at else { return }
        let secs = Double(snap.at - prev.at) / 1e9
        var perApp: [String: (UInt64, UInt64)] = [:]
        var rates: [pid_t: (Double, Double)] = [:]
        for (pid, cur) in snap.totals {
            var moved: (UInt64, UInt64)
            if let p = prev.totals[pid] {
                guard cur.0 >= p.0, cur.1 >= p.1 else { continue }
                moved = (cur.0 - p.0, cur.1 - p.1)
            } else if let started = ProcessSampler.startDate(of: pid), started > prev.wall {
                moved = cur
            } else {
                continue
            }
            guard moved.0 > 0 || moved.1 > 0 else { continue }
            rates[pid] = (Double(moved.0) / secs, Double(moved.1) / secs)
            let name = processes.appName(for: pid)
            let c = perApp[name] ?? (0, 0)
            perApp[name] = (c.0 &+ moved.0, c.1 &+ moved.1)
        }
        netRates = rates
        usage.addApps(perApp)
    }

    func tickProcesses() {
        let procs = processes.sample(network: netRates)
        lastProcAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if Engine.shared.isDetailed { Store.shared.apply(processes: procs) }
            }
        }
    }

    func tick() {
        ticks &+= 1
        let s = system.sample()
        if let t = system.interfaceTotals { usage.addInterfaceTotals(rx: t.rx, tx: t.tx) }

        // Skip a process pass that would land right after another one: tiny intervals give noisy CPU %.
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var procs: [ProcInfo]?
        snapshotNetworkIfDue()
        if detailed && (lastProcAt == 0 || now - lastProcAt > 500_000_000) {
            procs = processes.sample(network: netRates)
            lastProcAt = now
        }

        var detail: MetricDetailSnapshot?
        if let kind = detailKind {
            var d = MetricDetailSnapshot(kind: kind)
            switch kind {
            case .memory: d.memory = details.memory()
            case .cpu: d.cpu = details.cpu()
            case .temperature: d.sensors = details.sensors()
            case .power: d.power = details.power()
            case .network:
                d.interfaces = details.interfaces()
                d.usage = usage.summary()
            }
            detail = d
        }
        usage.saveIfNeeded()

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Store.shared.ingest(system: s, processes: Engine.shared.isDetailed ? procs : nil)
                if let detail { Store.shared.apply(detail: detail) }
            }
        }
    }
}

struct MetricDetailSnapshot: Equatable {
    var kind: MetricKind
    var memory: MemoryDetail?
    var cpu: CPUDetail?
    var sensors: [SensorGroup]?
    var power: PowerDetail?
    var interfaces: [InterfaceInfo]?
    var usage: UsageSummary?
}

/// Whole-system counters are always sampled (for the menu bar and data usage). Per-process
/// data, which costs more, is sampled only while a window or popover that shows it is visible.
@MainActor
final class Engine {
    static let shared = Engine()

    private let worker = Worker()
    private var timer: DispatchSourceTimer?
    private var viewers = Set<String>()
    private(set) var isDetailed = false

    func start() {
        let w = worker
        let iv = Store.shared.interval
        w.queue.async {
            w.interval = iv
            w.snapshotNetworkIfDue(force: true)
        }
        reschedule()
        Store.shared.onIntervalChange = { [weak self] in self?.reschedule() }
    }

    /// Saves data usage before the app quits.
    func flush() {
        let w = worker
        w.queue.sync { w.usage.saveIfNeeded(force: true) }
    }

    /// A metric's detail page appeared (`kind`) or went away (`nil`).
    func setDetail(_ kind: MetricKind?) {
        let w = worker
        w.queue.async {
            w.detailKind = kind
            if kind != nil { w.tick() }
        }
    }

    /// A view that needs per-process data appeared (`true`) or went away (`false`).
    func setViewer(_ id: String, active: Bool) {
        if active { viewers.insert(id) } else { viewers.remove(id) }
        let want = !viewers.isEmpty
        guard want != isDetailed else { return }
        isDetailed = want
        let w = worker
        if want {
            w.queue.async {
                w.detailed = true
                w.snapshotNetworkIfDue(force: true)
                w.tick()
            }
            // A second pass shortly after gives real CPU figures in under a second instead of one interval.
            w.queue.asyncAfter(deadline: .now() + 0.6) {
                guard w.detailed else { return }
                w.tickProcesses()
            }
        } else {
            w.queue.async {
                w.detailed = false
                w.resetProcesses()
            }
            Store.shared.clearProcesses()
        }
    }

    private func reschedule() {
        timer?.cancel()
        let iv = Double(Store.shared.interval)
        let w = worker
        w.queue.async { w.interval = Int(iv) }
        let t = DispatchSource.makeTimerSource(queue: w.queue)
        // Generous leeway lets macOS coalesce our wakeups with others, which saves energy.
        t.schedule(deadline: .now(), repeating: iv, leeway: .milliseconds(Int(iv * 250)))
        t.setEventHandler { w.tick() }
        t.resume()
        timer = t
    }
}
