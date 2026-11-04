import Darwin
import Foundation
import IOKit
import SystemConfiguration
import CMonitr

enum MetricKind: String, Hashable, CaseIterable, Identifiable {
    case cpu, memory, network, temperature, power
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .temperature: "Temperature"
        case .power: "Power and battery"
        }
    }
}

struct MemoryDetail: Equatable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapInsPerSec: Double = 0
    var swapOutsPerSec: Double = 0
    var pageInsPerSec: Double = 0
}

struct CoreLoad: Equatable, Identifiable {
    let id: Int
    let efficiency: Bool
    var load: Double  // 0...100
}

struct CPUDetail: Equatable {
    var user: Double = 0
    var system: Double = 0
    var idle: Double = 100
    var cores: [CoreLoad] = []
    var load: (Double, Double, Double) = (0, 0, 0)
    var uptime: TimeInterval = 0
    var performanceCores = 0
    var efficiencyCores = 0

    static func == (a: CPUDetail, b: CPUDetail) -> Bool {
        a.user == b.user && a.system == b.system && a.cores == b.cores && a.load == b.load
    }
}

struct SensorReading: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let value: Double
}

struct SensorGroup: Equatable, Identifiable {
    var id: String { title }
    let title: String
    let readings: [SensorReading]
    var hottest: Double { readings.map(\.value).max() ?? 0 }
    var average: Double { readings.isEmpty ? 0 : readings.map(\.value).reduce(0, +) / Double(readings.count) }
}

struct PowerDetail: Equatable {
    var systemWatts: Double?
    var adapterInWatts: Double?
    var percent: Int?
    var charging = false
    var fullyCharged = false
    var onAdapter = false
    var adapterName: String?
    var adapterRating: Int?
    var cycleCount: Int?
    var health: Double?          // 0...1, full-charge capacity versus design
    var fullChargeMah: Int?
    var designMah: Int?
    var voltage: Double?
    var amperage: Int?           // mA, negative while discharging
    var minutesToFull: Int?
    var minutesToEmpty: Int?
}

struct InterfaceInfo: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let kind: String
    let address: String?
    let received: UInt64   // since the Mac started
    let sent: UInt64
}

/// Extra figures for one metric, read only while its detail page is open.
final class DetailSampler {
    private let host = mach_host_self()
    private let pageSize = UInt64(vm_kernel_page_size)
    private var lastCores: [(busy: UInt64, total: UInt64)] = []
    private var lastVM: (swapIns: UInt64, swapOuts: UInt64, pageIns: UInt64, at: UInt64)?
    private let perfCores: Int = DetailSampler.sysctlInt("hw.perflevel0.logicalcpu")
    private let effCores: Int = DetailSampler.sysctlInt("hw.perflevel1.logicalcpu")
    private let battery: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))

    deinit { if battery != 0 { IOObjectRelease(battery) } }

    func memory() -> MemoryDetail {
        var d = MemoryDetail()
        d.total = ProcessInfo.processInfo.physicalMemory
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        if r == KERN_SUCCESS {
            let anon = UInt64(s.internal_page_count), purgeable = UInt64(s.purgeable_count)
            d.app = (anon - min(anon, purgeable)) * pageSize
            d.wired = UInt64(s.wire_count) * pageSize
            d.compressed = UInt64(s.compressor_page_count) * pageSize
            d.cached = (UInt64(s.external_page_count) + purgeable) * pageSize
            d.free = UInt64(s.free_count) * pageSize
            d.used = d.app + d.wired + d.compressed
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if let last = lastVM, now > last.at {
                let secs = Double(now - last.at) / 1e9
                d.swapInsPerSec = Double(s.swapins &- last.swapIns) / secs
                d.swapOutsPerSec = Double(s.swapouts &- last.swapOuts) / secs
                d.pageInsPerSec = Double(s.pageins &- last.pageIns) / secs
            }
            lastVM = (s.swapins, s.swapouts, s.pageins, now)
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            d.swapUsed = swap.xsu_used
            d.swapTotal = swap.xsu_total
        }
        return d
    }

    func cpu() -> CPUDetail {
        var d = CPUDetail()
        d.performanceCores = perfCores
        d.efficiencyCores = effCores
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        if host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info {
            var cores: [CoreLoad] = []
            var sumUser: UInt64 = 0, sumSys: UInt64 = 0, sumTotal: UInt64 = 0
            var now: [(UInt64, UInt64)] = []
            for i in 0..<Int(cpuCount) {
                let base = Int(CPU_STATE_MAX) * i
                let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
                let sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
                let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
                let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
                let busy = user + sys + nice, total = busy + idle
                now.append((busy, total))
                var load = 0.0
                if i < lastCores.count, total > lastCores[i].total {
                    load = Double(busy - lastCores[i].busy) / Double(total - lastCores[i].total) * 100
                }
                // Apple silicon numbers its efficiency cores first.
                cores.append(CoreLoad(id: i, efficiency: i < effCores, load: load))
                sumUser += user
                sumSys += sys
                sumTotal += total
            }
            if lastCores.count == now.count, let prevTotals = lastTotals {
                let dt = Double(sumTotal &- prevTotals.total)
                if dt > 0 {
                    d.user = Double(sumUser &- prevTotals.user) / dt * 100
                    d.system = Double(sumSys &- prevTotals.sys) / dt * 100
                    d.idle = max(0, 100 - d.user - d.system)
                }
            }
            lastTotals = (sumUser, sumSys, sumTotal)
            lastCores = now
            d.cores = cores
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var la = [Double](repeating: 0, count: 3)
        if getloadavg(&la, 3) == 3 { d.load = (la[0], la[1], la[2]) }
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            d.uptime = Date().timeIntervalSince1970 - Double(boot.tv_sec)
        }
        return d
    }
    private var lastTotals: (user: UInt64, sys: UInt64, total: UInt64)?

    func sensors() -> [SensorGroup] {
        var groups: [String: [SensorReading]] = [:]
        for i in 0..<Int(monitr_temp_count()) {
            let v = monitr_temp_value(Int32(i))
            guard v > 0 else { continue }
            let name = String(cString: monitr_temp_name(Int32(i)))
            groups[Self.group(for: name), default: []].append(SensorReading(name: name, value: v))
        }
        let order = ["CPU cores", "Chip", "Storage", "Battery", "Other"]
        return order.compactMap { title in
            guard let r = groups[title], !r.isEmpty else { return nil }
            return SensorGroup(title: title, readings: r.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }

    private static func group(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("tdie") || n.contains("cpu") { return "CPU cores" }
        if n.contains("tdev") || n.contains("tcal") || n.contains("soc") || n.contains("gpu") { return "Chip" }
        if n.contains("nand") || n.contains("ssd") { return "Storage" }
        if n.contains("battery") || n.contains("gas gauge") { return "Battery" }
        return "Other"
    }

    func power() -> PowerDetail {
        var d = PowerDetail()
        guard battery != 0 else { return d }
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(battery, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        if let t = prop("PowerTelemetryData") as? [String: Any] {
            if let l = t["SystemLoad"] as? Int { d.systemWatts = Double(l) / 1000 }
            if let p = t["SystemPowerIn"] as? Int { d.adapterInWatts = Double(p) / 1000 }
        }
        d.percent = prop("CurrentCapacity") as? Int
        d.charging = prop("IsCharging") as? Bool ?? false
        d.fullyCharged = prop("FullyCharged") as? Bool ?? false
        d.onAdapter = prop("ExternalConnected") as? Bool ?? false
        if let a = prop("AdapterDetails") as? [String: Any] {
            d.adapterName = a["Name"] as? String
            d.adapterRating = a["Watts"] as? Int
        }
        d.cycleCount = prop("CycleCount") as? Int
        if let v = prop("Voltage") as? Int { d.voltage = Double(v) / 1000 }
        d.amperage = prop("Amperage") as? Int
        let data = prop("BatteryData") as? [String: Any]
        d.designMah = (prop("DesignCapacity") as? Int) ?? (data?["DesignCapacity"] as? Int)
        d.fullChargeMah = (prop("NominalChargeCapacity") as? Int) ?? (data?["NominalChargeCapacity"] as? Int)
            ?? (prop("AppleRawMaxCapacity") as? Int)
        if let f = d.fullChargeMah, let des = d.designMah, des > 0 { d.health = min(Double(f) / Double(des), 1) }
        if let t = prop("AvgTimeToFull") as? Int, t > 0, t < 65535, d.charging { d.minutesToFull = t }
        if let t = prop("AvgTimeToEmpty") as? Int, t > 0, t < 65535, !d.onAdapter { d.minutesToEmpty = t }
        return d
    }

    func interfaces() -> [InterfaceInfo] {
        var out: [InterfaceInfo] = []
        var addrs: [String: String] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var stats: [String: (UInt64, UInt64)] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip"), let sa = p.pointee.ifa_addr else { continue }
            if sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addrs[name] = String(cString: host)
                }
            }
        }
        // 64-bit counters come from the routing table; getifaddrs' are 32-bit and wrap at 4 GB.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        if sysctl(&mib, 6, nil, &len, nil, 0) == 0 {
            var buf = [UInt8](repeating: 0, count: len)
            if sysctl(&mib, 6, &buf, &len, nil, 0) == 0 {
                buf.withUnsafeBytes { raw in
                    var off = 0
                    while off + MemoryLayout<if_msghdr>.size <= len {
                        let base = raw.baseAddress!.advanced(by: off)
                        let h = base.loadUnaligned(as: if_msghdr.self)
                        if h.ifm_msglen == 0 { break }
                        if Int32(h.ifm_type) == RTM_IFINFO2 {
                            let h2 = base.loadUnaligned(as: if_msghdr2.self)
                            var nb = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                            if let n = if_indextoname(UInt32(h2.ifm_index), &nb).map({ String(cString: $0) }) {
                                stats[n] = (h2.ifm_data.ifi_ibytes, h2.ifm_data.ifi_obytes)
                            }
                        }
                        off += Int(h.ifm_msglen)
                    }
                }
            }
        }
        for (name, s) in stats where (name.hasPrefix("en") || name.hasPrefix("pdp_ip")) && (s.0 > 0 || s.1 > 0) {
            let kind = Self.interfaceKinds[name] ?? (name.hasPrefix("pdp_ip") ? "Cellular" : "Network")
            out.append(InterfaceInfo(name: name, kind: kind, address: addrs[name], received: s.0, sent: s.1))
        }
        return out.sorted { $0.received + $0.sent > $1.received + $1.sent }
    }

    /// BSD name to what macOS calls it ("Wi-Fi", "Ethernet", "iPhone USB"), read once.
    private static let interfaceKinds: [String: String] = {
        var out: [String: String] = [:]
        for i in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
            out[bsd] = (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd
        }
        return out
    }()

    private static func sysctlInt(_ name: String) -> Int {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : 0
    }
}
