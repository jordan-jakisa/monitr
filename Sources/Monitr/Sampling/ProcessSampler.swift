import Darwin
import Foundation
import CMonitr

struct ProcTags: OptionSet, Sendable, Hashable {
    let rawValue: UInt8
    static let system     = ProcTags(rawValue: 1 << 0)  // macOS or another user owns it; leave alone
    static let background = ProcTags(rawValue: 1 << 1)  // helper or daemon with no window of its own
    static let idle       = ProcTags(rawValue: 1 << 2)  // no CPU use for a while
    static let unusedApp  = ProcTags(rawValue: 1 << 3)  // its app has not been in front for a while
    static let heavy      = ProcTags(rawValue: 1 << 4)  // idle yet holding a lot of memory
}

struct ProcInfo: Identifiable, Equatable, Sendable {
    let id: pid_t
    var name: String
    var path: String
    var appKey: String       // bundle path, or a synthetic key for loose binaries
    var appName: String
    var isAppBundle: Bool
    var cpu: Double          // percent of one core, like Activity Monitor
    var memory: UInt64       // bytes (physical footprint)
    var power: Double?       // watts
    var measured: Bool       // false for processes owned by root or other users: macOS hides their usage
    var wakeups: Double      // per second
    var netIn: Double        // bytes per second
    var netOut: Double
    var idleSeconds: Double
    var tags: ProcTags
    var killable: Bool

    var pid: pid_t { id }
    var nonCritical: Bool { !tags.contains(.system) }
}

/// Reads every process with one sysctl plus one `proc_pid_rusage` per process the user owns.
/// macOS gives an unprivileged app no usage figures for processes owned by root or other users;
/// those are listed (with their app) but marked unmeasured. The whole-Mac totals include them.
final class ProcessSampler {
    private struct Identity {
        let start: UInt64
        let name: String
        let path: String
        let appKey: String
        let appName: String
        let isAppBundle: Bool
        let isSystem: Bool
    }
    private struct Prev { var cpuNs: UInt64; var energy: UInt64; var wakeups: UInt64; var lastActive: UInt64; var firstSeen: UInt64 }

    private let myUid = getuid()
    private let myPid = getpid()
    private let ticksToNs: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
    private var identities: [pid_t: Identity] = [:]
    private var prev: [pid_t: Prev] = [:]
    private var lastSampleAt: UInt64 = 0
    private var kinfo = [kinfo_proc]()
    private var bundleNames: [String: String] = [:]

    static let idleAfter: Double = 5 * 60
    static let heavyBytes: UInt64 = 200 * 1024 * 1024
    private static let protectedNames: Set<String> = [
        "Finder", "Dock", "loginwindow", "WindowServer", "SystemUIServer", "ControlCenter",
        "NotificationCenter", "Spotlight", "kernel_task", "launchd",
    ]

    func sample(network: [pid_t: (Double, Double)]) -> [ProcInfo] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsedNs = lastSampleAt == 0 ? 0 : Double(now - lastSampleAt)
        lastSampleAt = now
        guard loadKinfo() else { return [] }

        var out = [ProcInfo]()
        out.reserveCapacity(kinfo.count)
        var seen = Set<pid_t>(minimumCapacity: kinfo.count)
        var ru = rusage_info_v6()

        for kp in kinfo {
            let pid = kp.kp_proc.p_pid
            if pid == 0 || kp.kp_proc.p_stat == SZOMB { continue }
            seen.insert(pid)
            let uid = kp.kp_eproc.e_ucred.cr_uid
            let start = UInt64(kp.kp_proc.p_starttime.tv_sec) &* 1_000_000 &+ UInt64(kp.kp_proc.p_starttime.tv_usec)
            let ident: Identity
            if let cached = identities[pid], cached.start == start {
                ident = cached
            } else {
                ident = resolve(pid: pid, uid: uid, start: start, comm: kp.kp_proc.p_comm)
                identities[pid] = ident
                prev[pid] = nil
            }

            var cpu = 0.0, mem: UInt64 = 0, power: Double?, wake = 0.0
            var p = prev[pid] ?? Prev(cpuNs: 0, energy: 0, wakeups: 0, lastActive: now, firstSeen: now)
            let fresh = prev[pid] == nil

            let ok = uid == myUid && withUnsafeMutablePointer(to: &ru, {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }) == 0
            if ok {
                let cpuNs = UInt64(Double(ru.ri_user_time &+ ru.ri_system_time) * ticksToNs)
                let wk = ru.ri_pkg_idle_wkups &+ ru.ri_interrupt_wkups
                mem = ru.ri_phys_footprint
                if !fresh, elapsedNs > 0 {
                    cpu = Double(cpuNs &- min(cpuNs, p.cpuNs)) / elapsedNs * 100
                    wake = Double(wk &- min(wk, p.wakeups)) / (elapsedNs / 1e9)
                    if ru.ri_energy_nj >= p.energy {
                        power = Double(ru.ri_energy_nj - p.energy) / elapsedNs  // nJ per ns = W
                    }
                }
                p.cpuNs = cpuNs; p.energy = ru.ri_energy_nj; p.wakeups = wk
            }
            if cpu >= 0.5 || fresh || !ok { p.lastActive = now }
            prev[pid] = p

            let idleSecs = Double(now - p.lastActive) / 1e9
            var tags: ProcTags = []
            if ident.isSystem { tags.insert(.system) }
            if !ident.isAppBundle && !ident.isSystem { tags.insert(.background) }
            if idleSecs >= Self.idleAfter && !ident.isSystem {
                tags.insert(.idle)
                if mem >= Self.heavyBytes { tags.insert(.heavy) }
            }
            let net = network[pid]
            out.append(ProcInfo(
                id: pid, name: ident.name, path: ident.path, appKey: ident.appKey, appName: ident.appName,
                isAppBundle: ident.isAppBundle, cpu: cpu, memory: mem, power: power, measured: ok, wakeups: wake,
                netIn: net?.0 ?? 0, netOut: net?.1 ?? 0, idleSeconds: idleSecs, tags: tags,
                killable: uid == myUid && pid != myPid && !ident.isSystem
            ))
        }

        if identities.count > seen.count + 64 {
            identities = identities.filter { seen.contains($0.key) }
            prev = prev.filter { seen.contains($0.key) }
        }
        return out
    }

    /// Drops per-process history so the next sample starts clean (sampling was paused).
    func reset() {
        prev.removeAll(keepingCapacity: true)
        lastSampleAt = 0
    }

    private func loadKinfo() -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return false }
        let n = size / MemoryLayout<kinfo_proc>.stride + 16
        if kinfo.count < n { kinfo = [kinfo_proc](repeating: kinfo_proc(), count: n) }
        size = kinfo.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0 else { return false }
        let got = size / MemoryLayout<kinfo_proc>.stride
        if got < kinfo.count { kinfo.removeLast(kinfo.count - got) }
        return true
    }

    private func resolve(pid: pid_t, uid: uid_t, start: UInt64, comm: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) -> Identity {
        let path = Self.path(of: pid)
        var shortName = withUnsafeBytes(of: comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        if pid == 0 { shortName = "kernel_task" }
        let name = path.isEmpty ? shortName : (path as NSString).lastPathComponent

        // The app that "owns" this process: the responsible pid's outermost .app bundle.
        var bundle = Self.outermostBundle(in: path)
        let rpid = monitr_responsible_pid(pid)
        if rpid > 0, rpid != pid {
            let rpath = Self.path(of: rpid)
            if let b = Self.outermostBundle(in: rpath) { bundle = b }
        }

        let inSystemDir = path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/")
            || path.hasPrefix("/bin/") || path.hasPrefix("/Library/Apple/") || path.isEmpty
        var isSystem = uid != myUid || Self.protectedNames.contains(name)
        if let b = bundle {
            // CoreServices bundles (Finder, Dock, Siri...) are part of macOS; user-facing apps are not.
            if b.hasPrefix("/System/Library/") || Self.protectedNames.contains(Self.bundleBaseName(b)) { isSystem = true }
            return Identity(start: start, name: name, path: path, appKey: b, appName: displayName(bundle: b),
                            isAppBundle: true, isSystem: isSystem)
        }
        if inSystemDir { isSystem = true }
        if isSystem {
            return Identity(start: start, name: name, path: path, appKey: "system", appName: "macOS",
                            isAppBundle: false, isSystem: true)
        }
        return Identity(start: start, name: name, path: path, appKey: "bin:" + name, appName: name,
                        isAppBundle: false, isSystem: false)
    }

    private func displayName(bundle: String) -> String {
        if let n = bundleNames[bundle] { return n }
        var n = Self.bundleBaseName(bundle)
        if let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist") {
            n = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? n
        }
        bundleNames[bundle] = n
        return n
    }

    static func bundleBaseName(_ bundle: String) -> String {
        ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func outermostBundle(in path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func path(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }
}
