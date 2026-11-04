import Foundation

/// Data used per day, for the whole Mac and per app, kept for 90 days in
/// ~/Library/Application Support/Monitr/usage.json. Touched only on the sampler queue.
final class UsageTracker {
    private struct Day: Codable {
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var apps: [String: [UInt64]] = [:]  // app name -> [received, sent]
    }
    private struct File: Codable {
        var since: Date
        var days: [String: Day]
    }

    private var file: File
    private var lastInterface: (rx: UInt64, tx: UInt64)?
    private var dirty = false
    private var lastSave = Date()
    private let url: URL
    private let calendar = Calendar.current
    private let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Monitr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("usage.json")
        if let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) {
            file = f
        } else {
            file = File(since: Date(), days: [:])
        }
    }

    private var todayKey: String { keyFormatter.string(from: Date()) }

    /// Feeds the interface byte counters (cumulative since boot).
    func addInterfaceTotals(rx: UInt64, tx: UInt64) {
        defer { lastInterface = (rx, tx) }
        guard let last = lastInterface else { return }
        // Counters reset when the Mac restarts; then the new value is all fresh traffic.
        let dRx = rx >= last.rx ? rx - last.rx : rx
        let dTx = tx >= last.tx ? tx - last.tx : tx
        guard dRx > 0 || dTx > 0 else { return }
        let key = todayKey
        file.days[key, default: Day()].rx &+= dRx
        file.days[key, default: Day()].tx &+= dTx
        dirty = true
    }

    func addApps(_ bytes: [String: (UInt64, UInt64)]) {
        guard !bytes.isEmpty else { return }
        let key = todayKey
        var day = file.days[key] ?? Day()
        for (name, b) in bytes {
            var cur = day.apps[name] ?? [0, 0]
            cur[0] &+= b.0
            cur[1] &+= b.1
            day.apps[name] = cur
        }
        file.days[key] = day
        dirty = true
    }

    /// Writes at most once a minute, or right away with `force`.
    func saveIfNeeded(force: Bool = false) {
        guard dirty, force || Date().timeIntervalSince(lastSave) > 60 else { return }
        let cutoff = keyFormatter.string(from: calendar.date(byAdding: .day, value: -90, to: Date()) ?? Date())
        file.days = file.days.filter { $0.key >= cutoff }
        if let data = try? JSONEncoder().encode(file) { try? data.write(to: url, options: .atomic) }
        dirty = false
        lastSave = Date()
    }

    func summary() -> UsageSummary {
        let now = Date()
        func total(days back: Int) -> (rx: UInt64, tx: UInt64, apps: [String: (UInt64, UInt64)]) {
            var rx: UInt64 = 0, tx: UInt64 = 0
            var apps: [String: (UInt64, UInt64)] = [:]
            for i in 0..<back {
                guard let d = calendar.date(byAdding: .day, value: -i, to: now),
                      let day = file.days[keyFormatter.string(from: d)] else { continue }
                rx &+= day.rx
                tx &+= day.tx
                for (n, b) in day.apps {
                    let c = apps[n] ?? (0, 0)
                    apps[n] = (c.0 &+ b[0], c.1 &+ b[1])
                }
            }
            return (rx, tx, apps)
        }
        func top(_ apps: [String: (UInt64, UInt64)]) -> [AppUsage] {
            apps.map { AppUsage(name: $0.key, received: $0.value.0, sent: $0.value.1) }
                .filter { $0.total > 0 }
                .sorted { $0.total > $1.total }
                .prefix(8).map { $0 }
        }
        var periods: [UsagePeriod] = []
        for (title, n) in [("Today", 1), ("Last 7 days", 7), ("Last 30 days", 30)] {
            let t = total(days: n)
            periods.append(UsagePeriod(title: title, received: t.rx, sent: t.tx, apps: top(t.apps)))
        }
        var daily: [DayTotal] = []
        for i in (0..<14).reversed() {
            guard let d = calendar.date(byAdding: .day, value: -i, to: now) else { continue }
            let day = file.days[keyFormatter.string(from: d)]
            daily.append(DayTotal(date: calendar.startOfDay(for: d), received: day?.rx ?? 0, sent: day?.tx ?? 0))
        }
        return UsageSummary(since: file.since, periods: periods, daily: daily)
    }
}

struct AppUsage: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let received: UInt64
    let sent: UInt64
    var total: UInt64 { received &+ sent }
}

struct UsagePeriod: Equatable, Identifiable {
    var id: String { title }
    let title: String
    let received: UInt64
    let sent: UInt64
    let apps: [AppUsage]
    var total: UInt64 { received &+ sent }
}

struct DayTotal: Equatable, Identifiable {
    var id: Date { date }
    let date: Date
    let received: UInt64
    let sent: UInt64
    var total: UInt64 { received &+ sent }
}

struct UsageSummary: Equatable {
    var since: Date
    var periods: [UsagePeriod]
    var daily: [DayTotal]
}
