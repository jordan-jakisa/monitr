import Darwin
import Foundation
import IOKit
import IOKit.ps
import CMonitr

struct SystemSnapshot: Equatable, Sendable {
    var cpu: Double = 0            // 0...100, all cores
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var pressure: MemoryPressure = .normal
    var netIn: Double = 0          // bytes per second
    var netOut: Double = 0
    var temperature: Double?       // hottest CPU die, °C
    var power: Double?             // whole system draw, watts
    var battery: Int?              // percent
    var charging = false
    var onAC = true
    var minutesLeft: Int?
    var thermal: ProcessInfo.ThermalState = .nominal

    var memoryFraction: Double { memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) }
}

enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4
}

/// Cheap whole-system counters. Every call is a handful of syscalls; nothing is spawned.
final class SystemSampler {
    private let host = mach_host_self()
    private let pageSize = UInt64(vm_kernel_page_size)
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastNet: (rx: UInt64, tx: UInt64, at: UInt64)?
    private var ifNames: [UInt16: Bool] = [:]  // index -> counts toward traffic
    private var netBuffer = [UInt8](repeating: 0, count: 16 * 1024)
    private let tempAvailable = monitr_temp_open() == 0
    private var batteryService: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    private var slowCounter = 0
    private var cached = SystemSnapshot()

    deinit { if batteryService != 0 { IOObjectRelease(batteryService) } }

    func sample() -> SystemSnapshot {
        var s = cached
        s.cpu = cpuPercent()
        memory(into: &s)
        network(into: &s)
        s.thermal = ProcessInfo.processInfo.thermalState
        // Sensors and the battery change slowly; read them every other tick.
        if slowCounter % 2 == 0 {
            if tempAvailable {
                let t = monitr_cpu_temp()
                s.temperature = t > 0 ? t : nil
            }
            power(into: &s)
        }
        if slowCounter % 15 == 0 { battery(into: &s) }
        slowCounter &+= 1
        cached = s
        return s
    }

    private func cpuPercent() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), sys = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + sys + nice, total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total) * 100
    }

    private func memory(into s: inout SystemSnapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if r == KERN_SUCCESS {
            // Same definition as Activity Monitor's "Memory Used": app + wired + compressed.
            let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
            s.memoryUsed = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        }
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            s.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }
    }

    private func network(into s: inout SystemSnapshot) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return }
        if len > netBuffer.count { netBuffer = [UInt8](repeating: 0, count: len + 4096) }
        guard sysctl(&mib, 6, &netBuffer, &len, nil, 0) == 0 else { return }

        var rx: UInt64 = 0, tx: UInt64 = 0
        netBuffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let base = raw.baseAddress!.advanced(by: offset)
                let hdr = base.loadUnaligned(as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let h2 = base.loadUnaligned(as: if_msghdr2.self)
                    if counts(index: h2.ifm_index, flags: h2.ifm_flags) {
                        rx &+= h2.ifm_data.ifi_ibytes
                        tx &+= h2.ifm_data.ifi_obytes
                    }
                }
                offset += Int(hdr.ifm_msglen)
            }
        }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let last = lastNet, now > last.at, rx >= last.rx, tx >= last.tx {
            let secs = Double(now - last.at) / 1e9
            s.netIn = Double(rx - last.rx) / secs
            s.netOut = Double(tx - last.tx) / secs
        }
        lastNet = (rx, tx, now)
    }

    /// Physical interfaces only, so VPN tunnels do not double-count traffic.
    private func counts(index: UInt16, flags: Int32) -> Bool {
        if flags & IFF_LOOPBACK != 0 { return false }
        if let known = ifNames[index] { return known }
        var buf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        let name = if_indextoname(UInt32(index), &buf).map { String(cString: $0) } ?? ""
        let ok = name.hasPrefix("en") || name.hasPrefix("pdp_ip")
        ifNames[index] = ok
        return ok
    }

    private func power(into s: inout SystemSnapshot) {
        guard batteryService != 0,
              let prop = IORegistryEntryCreateCFProperty(batteryService, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let load = prop["SystemLoad"] as? Int else { return }
        s.power = Double(load) / 1000
    }

    private func battery(into s: inout SystemSnapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                s.battery = cur * 100 / max
            }
            s.charging = d[kIOPSIsChargingKey] as? Bool ?? false
            s.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let mins = d[kIOPSTimeToEmptyKey] as? Int ?? -1
            s.minutesLeft = (!s.onAC && mins > 0) ? mins : nil
        }
    }
}
