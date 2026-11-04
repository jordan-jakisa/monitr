import Darwin
import Foundation
import MonitrShared

/// Monitr's root helper. launchd starts it when Monitr connects and it exits after a minute
/// with no requests. Read-only: it reports usage counters and nothing else.

final class Helper: NSObject, MonitrHelperProtocol, NSXPCListenerDelegate {
    private let ticksToNs: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
    private var lastRequest = Date()
    private let lock = NSLock()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // The listener-level code signing requirement already rejects anything but Monitr;
        // this is the per-connection check as a second gate.
        c.setCodeSigningRequirement(HelperInfo.appRequirement)
        c.exportedInterface = NSXPCInterface(with: MonitrHelperProtocol.self)
        c.exportedObject = self
        c.resume()
        return true
    }

    func version(reply: @escaping (Int) -> Void) {
        touch()
        reply(HelperInfo.version)
    }

    func usage(reply: @escaping (Data) -> Void) {
        touch()
        reply(HelperRecord.pack(read()))
    }

    private func touch() { lock.lock(); lastRequest = Date(); lock.unlock() }

    var idleFor: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastRequest) }

    private func read() -> [HelperRecord] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let n = size / MemoryLayout<kinfo_proc>.stride
        var out: [HelperRecord] = []
        out.reserveCapacity(n)
        var ru = rusage_info_v6()
        for kp in procs.prefix(n) {
            let pid = kp.kp_proc.p_pid
            if pid == 0 || kp.kp_proc.p_stat == SZOMB { continue }
            let ok = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            } == 0
            guard ok else { continue }
            let start = UInt64(kp.kp_proc.p_starttime.tv_sec) &* 1_000_000 &+ UInt64(kp.kp_proc.p_starttime.tv_usec)
            out.append(HelperRecord(
                pid: pid, start: start,
                cpuNs: UInt64(Double(ru.ri_user_time &+ ru.ri_system_time) * ticksToNs),
                footprint: ru.ri_phys_footprint,
                energyNj: ru.ri_energy_nj,
                wakeups: ru.ri_pkg_idle_wkups &+ ru.ri_interrupt_wkups
            ))
        }
        return out
    }
}

let helper = Helper()
let listener = NSXPCListener(machServiceName: HelperInfo.machService)
listener.setConnectionCodeSigningRequirement(HelperInfo.appRequirement)
listener.delegate = helper
listener.resume()

// Exit when idle; launchd starts the helper again on Monitr's next request.
let idleTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
idleTimer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
idleTimer.setEventHandler { if helper.idleFor > 60 { exit(0) } }
idleTimer.resume()

RunLoop.main.run()
