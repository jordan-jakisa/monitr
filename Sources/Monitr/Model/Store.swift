import AppKit
import Observation

/// Fixed-size history for sparklines. No allocation after init.
struct Ring: Equatable {
    private(set) var values: [Double]
    private var head = 0
    private(set) var count = 0
    /// Total values ever pushed; changes on every push, so views can animate each new point.
    private(set) var pushes = 0
    var capacity: Int { values.count }

    init(capacity: Int) { values = Array(repeating: 0, count: capacity) }

    mutating func push(_ v: Double) {
        values[head] = v
        head = (head + 1) % values.count
        count = min(count + 1, values.count)
        pushes &+= 1
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
    @ObservationIgnored private(set) var cpuHistory = Ring(capacity: 90)
    @ObservationIgnored private(set) var memHistory = Ring(capacity: 90)
    @ObservationIgnored private(set) var netInHistory = Ring(capacity: 90)
    @ObservationIgnored private(set) var netOutHistory = Ring(capacity: 90)
    @ObservationIgnored private(set) var tempHistory = Ring(capacity: 90)
    @ObservationIgnored private(set) var powerHistory = Ring(capacity: 90)

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

    static let unusedAfter: TimeInterval = 15 * 60

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: "menuStats")?.compactMap(MenuStat.init) ?? [.cpu, .memory, .temperature]
        menuStats = saved
        let iv = UserDefaults.standard.integer(forKey: "interval")
        interval = [1, 2, 3, 5].contains(iv) ? iv : 2

        let ws = NSWorkspace.shared
        if let front = ws.frontmostApplication?.bundleURL?.path {
            lastActivated[front] = Date()
            frontPath = front
        }
        refreshRunningApps()
        let nc = ws.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let path = app.bundleURL?.path else { return }
            MainActor.assumeIsolated {
                Store.shared.lastActivated[path] = Date()
                Store.shared.frontPath = path
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Store.shared.refreshRunningApps() }
            }
        }
    }

    /// Running GUI apps by bundle path. Asking LaunchServices about every app on every tick is
    /// slow (an XPC round trip each), so this is rebuilt only when an app launches or quits.
    @ObservationIgnored private var runningApps: [String: (pid: pid_t, regular: Bool)] = [:]
    @ObservationIgnored private var frontPath: String?

    private func refreshRunningApps() {
        var map: [String: (pid_t, Bool)] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let path = app.bundleURL?.path else { continue }
            let regular = app.activationPolicy == .regular
            if map[path] == nil || regular { map[path] = (app.processIdentifier, regular) }
        }
        runningApps = map
    }

    /// What the sidebar shows. Changes only when an app arrives, leaves or changes state, so the
    /// window does not re-render its whole tree on every tick.
    private(set) var sidebar: [SidebarEntry] = []

    /// True while the window is the active one or the menu bar panel is open: the UI then
    /// refreshes every tick. Otherwise it refreshes every ~6 s; sampling (and the charts'
    /// history) continues every tick underneath.
    @ObservationIgnored var windowKey = false
    @ObservationIgnored var popoverOpen = false
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var pendingProcesses: [ProcInfo]?

    func ingest(system s: SystemSnapshot, processes list: [ProcInfo]?) {
        record(system: s)
        if let list { pendingProcesses = list }
        ticks &+= 1
        let slowEvery = max(1, 6 / max(interval, 1))
        guard windowKey || popoverOpen || ticks % slowEvery == 0 else { return }
        system = s
        if let p = pendingProcesses {
            pendingProcesses = nil
            apply(processes: p)
        }
    }

    private func record(system s: SystemSnapshot) {
        cpuHistory.push(s.cpu)
        memHistory.push(s.memoryFraction * 100)
        netInHistory.push(s.netIn)
        netOutHistory.push(s.netOut)
        if let t = s.temperature { tempHistory.push(t) }
        if let p = s.power { powerHistory.push(p) }
        onSystemUpdate?(s)
    }

    /// Publishes right away (used when a viewer just opened and is waiting for data).
    func publishNow() {
        if let p = pendingProcesses {
            pendingProcesses = nil
            apply(processes: p)
        }
    }

    func apply(processes list: [ProcInfo]) {
        if !stopped.isEmpty {
            let cutoff = Date().addingTimeInterval(-6)
            stopped = stopped.filter { $0.value > cutoff }
        }
        let visible = stopped.isEmpty ? list : list.filter { stopped[$0.id] == nil }
        processes = visible
        apps = group(visible)
        updateSidebar()
        updateBusiest()
    }

    private(set) var detail: MetricDetailSnapshot?

    func apply(detail d: MetricDetailSnapshot) {
        if detail != d { detail = d }
    }

    /// The busiest apps, ordered by CPU with hysteresis: an app moves above another only when it
    /// is clearly busier, so rows don't swap back and forth on every tick.
    private(set) var busiest: [AppGroup] = []

    private func updateBusiest(limit: Int = 7) {
        let byKey = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        let top = Set(apps.sorted { $0.cpu > $1.cpu }.prefix(limit).map(\.id))
        var order = busiest.map(\.id).filter { top.contains($0) }
        order += top.subtracting(order).sorted { (byKey[$0]?.cpu ?? 0) > (byKey[$1]?.cpu ?? 0) }
        var rows = order.compactMap { byKey[$0] }
        var i = 1
        while i < rows.count {
            if i > 0, rows[i].cpu > rows[i - 1].cpu * 1.25 + 1 {
                rows.swapAt(i, i - 1)
                i -= 1
            } else {
                i += 1
            }
        }
        busiest = rows
    }

    private func updateSidebar() {
        let rank: (AppGroup) -> Int = { $0.isSystem ? 2 : ($0.isAppBundle ? 0 : 1) }
        let entries = apps.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }.map { SidebarEntry(key: $0.id, name: $0.name, flag: $0.nonCritical ? $0.statusText?.0 : nil) }
        if entries != sidebar { sidebar = entries }
    }

    func clearProcesses() {
        pendingProcesses = nil
        processes = []
        apps = []
        sidebar = []
        busiest = []
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
        let now = Date()
        for (path, app) in runningApps {
            guard var g = map[path] else { continue }
            g.mainPid = app.pid
            if app.regular, path != frontPath, !g.isSystem {
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
    /// `force` sends SIGKILL. Anything that does not exit gets a notice with a way forward.
    func stop(pid: pid_t, force: Bool = false) {
        let name = processes.first { $0.id == pid }?.name ?? "Process \(pid)"
        let app = NSRunningApplication(processIdentifier: pid)
        let isApp = !force && app?.bundleURL != nil && app?.activationPolicy != .prohibited
        if isApp, let app {
            if !app.terminate() { kill(pid, SIGTERM) }
        } else if kill(pid, force ? SIGKILL : SIGTERM) != 0 {
            show(Notice(title: "Could not stop \(name)", detail: "macOS refused: \(String(cString: strerror(errno))).", kind: .error))
            return
        }
        hide([pid])
        verifyExit(pids: [pid], name: name, isApp: isApp, target: .pid(pid), forced: force)
    }

    /// Quits an app and every process it is responsible for.
    func stop(app key: String, force: Bool = false) {
        let members = processes.filter { $0.appKey == key && $0.killable }
        guard let group = apps.first(where: { $0.id == key }) else { return }
        if !force, let main = group.mainPid, let app = NSRunningApplication(processIdentifier: main) {
            app.terminate()
            hide(members.map(\.id))
            verifyExit(pids: [main], name: group.name, isApp: true, target: .app(key), forced: false)
            return
        }
        for p in members { kill(p.id, force ? SIGKILL : SIGTERM) }
        hide(members.map(\.id))
        verifyExit(pids: members.map(\.id), name: group.name, isApp: false, target: .app(key), forced: force)
    }

    /// A few seconds after a stop, checks the process really exited. If not, it comes back
    /// into the list and a notice explains why and offers the next step.
    private func verifyExit(pids: [pid_t], name: String, isApp: Bool, target: Notice.Target, forced: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            let alive = pids.filter { kill($0, 0) == 0 }
            guard !alive.isEmpty else { return }
            for p in alive { self.stopped[p] = nil }
            if forced {
                self.show(Notice(title: "\(name) is still running", detail: "Even a force stop did not end it. It may be stuck in the kernel; a restart clears it.", kind: .error))
            } else if isApp {
                self.show(Notice(title: "\(name) did not quit", detail: "It may be asking to save changes. Switch to it, or force quit and lose unsaved work.",
                                 kind: .refused, target: target, revealPid: pids.first))
            } else {
                self.show(Notice(title: "\(name) did not stop", detail: "It ignored the request. Force stop ends it at once.",
                                 kind: .refused, target: target))
            }
        }
    }

    private func hide(_ pids: [pid_t]) {
        let now = Date()
        for p in pids { stopped[p] = now }
        processes.removeAll { stopped[$0.id] != nil }
        apps = group(processes)
        updateSidebar()
        updateBusiest()
    }

    // MARK: Notices

    private(set) var notice: Notice?

    func show(_ n: Notice) {
        notice = n
        let id = n.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            if self?.notice?.id == id { self?.notice = nil }
        }
    }

    func dismissNotice() { notice = nil }

    func forceFromNotice() {
        guard let n = notice, let target = n.target else { return }
        notice = nil
        switch target {
        case .pid(let pid): stop(pid: pid, force: true)
        case .app(let key): stop(app: key, force: true)
        }
    }
}

struct Notice: Identifiable, Equatable {
    enum Kind { case refused, error }
    enum Target: Equatable { case pid(pid_t), app(String) }
    let id = UUID()
    var title: String
    var detail: String
    var kind: Kind
    var target: Target? = nil
    var revealPid: pid_t? = nil
}

struct SidebarEntry: Equatable, Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let flag: String?
}
