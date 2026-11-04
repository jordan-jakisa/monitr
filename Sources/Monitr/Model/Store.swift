import AppKit
import Observation

/// Fixed-size history for sparklines. No allocation after init.
struct Ring: Equatable {
    private(set) var values: [Double]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) { values = Array(repeating: 0, count: capacity) }

    mutating func push(_ v: Double) {
        values[head] = v
        head = (head + 1) % values.count
        count = min(count + 1, values.count)
    }

    /// Oldest to newest.
    var ordered: [Double] {
        guard count > 0 else { return [] }
        let start = (head - count + values.count) % values.count
        return (0..<count).map { values[(start + $0) % values.count] }
    }

    var max: Double { values.max() ?? 0 }
}

struct AppGroup: Identifiable, Equatable {
    let id: String          // appKey
    var name: String
    var cpu: Double = 0
    var memory: UInt64 = 0
    var power: Double = 0
    var netIn: Double = 0
    var netOut: Double = 0
    var count = 0
    var isSystem = false
    var isAppBundle = false
    var mainPid: pid_t?
    var unusedFor: Double?  // seconds since the app was last in front, when it counts as unused
    var idleFor: Double?    // every process in the group is idle
    var killable = false

    var nonCritical: Bool { !isSystem && (unusedFor != nil || idleFor != nil) }
}

enum MenuStat: String, CaseIterable, Identifiable {
    case cpu, memory, temperature, network, power, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .temperature: "Temperature"
        case .network: "Network"
        case .power: "Power"
        case .battery: "Battery"
        }
    }
}

@MainActor
@Observable
final class Store {
    static let shared = Store()

    private(set) var system = SystemSnapshot()
    private(set) var processes: [ProcInfo] = []
    private(set) var apps: [AppGroup] = []
    private(set) var cpuHistory = Ring(capacity: 90)
    private(set) var memHistory = Ring(capacity: 90)
    private(set) var netInHistory = Ring(capacity: 90)
    private(set) var netOutHistory = Ring(capacity: 90)
    private(set) var tempHistory = Ring(capacity: 90)
    private(set) var powerHistory = Ring(capacity: 90)
    private(set) var lastError: String?

    var menuStats: [MenuStat] {
        didSet { UserDefaults.standard.set(menuStats.map(\.rawValue), forKey: "menuStats"); onMenuStatsChange?() }
    }
    var interval: Int {
        didSet { UserDefaults.standard.set(interval, forKey: "interval"); onIntervalChange?() }
    }
    @ObservationIgnored var onMenuStatsChange: (() -> Void)?
    @ObservationIgnored var onIntervalChange: (() -> Void)?
    @ObservationIgnored var onSystemUpdate: ((SystemSnapshot) -> Void)?

    /// Bundle path -> last time the app was frontmost.
    @ObservationIgnored private var lastActivated: [String: Date] = [:]
    @ObservationIgnored private let launchedAt = Date()
    /// Pids the user just stopped, hidden for a few seconds while they exit. A process that
    /// refuses to quit (an unsaved-document prompt) reappears once this lapses.
    @ObservationIgnored private var stopped: [pid_t: Date] = [:]

    static let unusedAfter: TimeInterval = 30 * 60

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: "menuStats")?.compactMap(MenuStat.init) ?? [.cpu, .memory, .temperature]
        menuStats = saved
        let iv = UserDefaults.standard.integer(forKey: "interval")
        interval = [1, 2, 3, 5].contains(iv) ? iv : 2

        let ws = NSWorkspace.shared
        if let front = ws.frontmostApplication?.bundleURL?.path { lastActivated[front] = Date() }
        ws.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let path = app.bundleURL?.path else { return }
            MainActor.assumeIsolated { Store.shared.lastActivated[path] = Date() }
        }
    }

    func apply(system s: SystemSnapshot) {
        system = s
        cpuHistory.push(s.cpu)
        memHistory.push(s.memoryFraction * 100)
        netInHistory.push(s.netIn)
        netOutHistory.push(s.netOut)
        if let t = s.temperature { tempHistory.push(t) }
        if let p = s.power { powerHistory.push(p) }
        onSystemUpdate?(s)
    }

    func apply(processes list: [ProcInfo]) {
        if !stopped.isEmpty {
            let cutoff = Date().addingTimeInterval(-6)
            stopped = stopped.filter { $0.value > cutoff }
        }
        let visible = stopped.isEmpty ? list : list.filter { stopped[$0.id] == nil }
        processes = visible
        apps = group(visible)
    }

    func clearProcesses() {
        processes = []
        apps = []
    }

    private func group(_ list: [ProcInfo]) -> [AppGroup] {
        var map: [String: AppGroup] = [:]
        map.reserveCapacity(128)
        var allIdle: [String: Double] = [:]
        for p in list {
            var g = map[p.appKey] ?? AppGroup(id: p.appKey, name: p.appName)
            g.cpu += p.cpu
            g.memory += p.memory
            g.power += p.power ?? 0
            g.netIn += p.netIn
            g.netOut += p.netOut
            g.count += 1
            // An app counts as system only if all of its processes are; a user app's
            // WebKit or Metal helpers living in /System must not make it "System".
            g.isSystem = (g.count == 1 || g.isSystem) && p.tags.contains(.system)
            g.isAppBundle = p.isAppBundle
            g.killable = g.killable || p.killable
            if p.tags.contains(.idle) {
                allIdle[p.appKey] = min(allIdle[p.appKey] ?? .infinity, p.idleSeconds)
            } else {
                allIdle[p.appKey] = -1
            }
            map[p.appKey] = g
        }
        let running = NSWorkspace.shared.runningApplications
        let now = Date()
        let frontPath = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        for app in running {
            guard let path = app.bundleURL?.path, var g = map[path] else { continue }
            if g.mainPid == nil || app.activationPolicy == .regular { g.mainPid = app.processIdentifier }
            if app.activationPolicy == .regular, path != frontPath, !g.isSystem {
                let last = lastActivated[path] ?? launchedAt
                let gap = now.timeIntervalSince(last)
                if gap >= Self.unusedAfter { g.unusedFor = gap }
            }
            map[path] = g
        }
        for (key, idle) in allIdle where idle >= 0 { map[key]?.idleFor = idle }
        return Array(map.values)
    }

    // MARK: Actions

    /// One-click stop. Apps get a normal quit (they can save); other processes get SIGTERM.
    /// `force` sends SIGKILL.
    func stop(pid: pid_t, force: Bool = false) {
        if !force, let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil, app.activationPolicy != .prohibited {
            if !app.terminate() { kill(pid, SIGTERM) }
        } else if kill(pid, force ? SIGKILL : SIGTERM) != 0 {
            lastError = "Could not stop pid \(pid): \(String(cString: strerror(errno)))"
            return
        }
        hide([pid])
    }

    /// Quits an app and every process it is responsible for.
    func stop(app key: String, force: Bool = false) {
        let members = processes.filter { $0.appKey == key && $0.killable }
        guard let group = apps.first(where: { $0.id == key }) else { return }
        if !force, let main = group.mainPid, let app = NSRunningApplication(processIdentifier: main) {
            app.terminate()
            hide(members.map(\.id))
            return
        }
        for p in members { kill(p.id, force ? SIGKILL : SIGTERM) }
        hide(members.map(\.id))
    }

    private func hide(_ pids: [pid_t]) {
        let now = Date()
        for p in pids { stopped[p] = now }
        processes.removeAll { stopped[$0.id] != nil }
        apps = group(processes)
    }

    func dismissError() { lastError = nil }
}
