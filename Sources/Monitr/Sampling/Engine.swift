import Foundation

/// Owns the samplers. Touched only on its own serial queue.
private final class Worker: @unchecked Sendable {
    let queue = DispatchQueue(label: "monitr.sampler", qos: .utility, autoreleaseFrequency: .workItem)
    let system = SystemSampler()
    let processes = ProcessSampler()
    var network: NetworkSampler?
    var detailed = false
    private var lastProcAt: UInt64 = 0

    func resetProcesses() {
        processes.reset()
        lastProcAt = 0
    }

    func tickProcesses() {
        let procs = processes.sample(network: network?.take() ?? [:])
        network?.refresh()
        lastProcAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if Engine.shared.isDetailed { Store.shared.apply(processes: procs) }
            }
        }
    }

    func tick() {
        let s = system.sample()
        // Skip a process pass that would land right after another one: tiny intervals give noisy CPU %.
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var procs: [ProcInfo]?
        if detailed && (lastProcAt == 0 || now - lastProcAt > 500_000_000) {
            procs = processes.sample(network: network?.take() ?? [:])
            network?.refresh()
            lastProcAt = now
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Store.shared.apply(system: s)
                if let procs, Engine.shared.isDetailed { Store.shared.apply(processes: procs) }
            }
        }
    }
}

/// Whole-system counters are always sampled (for the menu bar). Per-process data, which
/// costs more, is sampled only while a window or popover that shows it is open.
@MainActor
final class Engine {
    static let shared = Engine()

    private let worker = Worker()
    private var timer: DispatchSourceTimer?
    private var viewers = Set<String>()
    private(set) var isDetailed = false

    func start() {
        reschedule()
        Store.shared.onIntervalChange = { [weak self] in self?.intervalChanged() }
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
                let n = NetworkSampler()
                n.start()
                n.refresh()
                w.network = n
                w.detailed = true
                w.tick()
            }
            // A second pass shortly after gives real CPU figures in under a second instead of one interval.
            w.queue.asyncAfter(deadline: .now() + 0.6) {
                guard w.detailed else { return }
                w.tickProcesses()
            }
        } else {
            w.queue.async {
                w.network?.stop()
                w.network = nil
                w.detailed = false
                w.resetProcesses()
            }
            Store.shared.clearProcesses()
        }
    }

    private func intervalChanged() { reschedule() }

    private func reschedule() {
        timer?.cancel()
        let iv = Double(Store.shared.interval)
        let w = worker
        let t = DispatchSource.makeTimerSource(queue: w.queue)
        // Generous leeway lets macOS coalesce our wakeups with others, which saves energy.
        t.schedule(deadline: .now(), repeating: iv, leeway: .milliseconds(Int(iv * 250)))
        t.setEventHandler { w.tick() }
        t.resume()
        timer = t
    }
}
