import Foundation

/// Per-process network rates from the kernel's network statistics (the same source `nettop`
/// reads), queried in-process. No subprocess, no polling thread of its own.
/// Runs only while a view that shows per-process data is open.
final class NetworkSampler: @unchecked Sendable {
    private typealias SourceBlock = @convention(block) (OpaquePointer, UnsafeMutableRawPointer?) -> Void
    private typealias DictBlock = @convention(block) (CFDictionary) -> Void
    private typealias VoidBlock = @convention(block) () -> Void

    private struct API {
        let create: @convention(c) (CFAllocator?, DispatchQueue, @escaping SourceBlock) -> OpaquePointer?
        let addTCP: @convention(c) (OpaquePointer) -> Void
        let addUDP: @convention(c) (OpaquePointer) -> Void
        let destroy: @convention(c) (OpaquePointer) -> Void
        let query: @convention(c) (OpaquePointer, VoidBlock?) -> Void
        let queryDescriptions: @convention(c) (OpaquePointer, VoidBlock?) -> Void
        let setCounts: @convention(c) (OpaquePointer, @escaping DictBlock) -> Void
        let setDescription: @convention(c) (OpaquePointer, @escaping DictBlock) -> Void
        let setRemoved: @convention(c) (OpaquePointer, @escaping VoidBlock) -> Void
        let keyPID: CFString
        let keyRx: CFString
        let keyTx: CFString

        static let shared: API? = {
            guard let h = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY) else { return nil }
            func fn<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
            func key(_ name: String) -> CFString? {
                dlsym(h, name)?.assumingMemoryBound(to: Unmanaged<CFString>.self).pointee.takeUnretainedValue()
            }
            guard let create = fn("NStatManagerCreate", (@convention(c) (CFAllocator?, DispatchQueue, @escaping SourceBlock) -> OpaquePointer?).self),
                  let addTCP = fn("NStatManagerAddAllTCP", (@convention(c) (OpaquePointer) -> Void).self),
                  let addUDP = fn("NStatManagerAddAllUDP", (@convention(c) (OpaquePointer) -> Void).self),
                  let destroy = fn("NStatManagerDestroy", (@convention(c) (OpaquePointer) -> Void).self),
                  let query = fn("NStatManagerQueryAllSources", (@convention(c) (OpaquePointer, VoidBlock?) -> Void).self),
                  let queryDesc = fn("NStatManagerQueryAllSourcesDescriptions", (@convention(c) (OpaquePointer, VoidBlock?) -> Void).self),
                  let setCounts = fn("NStatSourceSetCountsBlock", (@convention(c) (OpaquePointer, @escaping DictBlock) -> Void).self),
                  let setDesc = fn("NStatSourceSetDescriptionBlock", (@convention(c) (OpaquePointer, @escaping DictBlock) -> Void).self),
                  let setRemoved = fn("NStatSourceSetRemovedBlock", (@convention(c) (OpaquePointer, @escaping VoidBlock) -> Void).self),
                  let pid = key("kNStatSrcKeyPID"), let rx = key("kNStatSrcKeyRxBytes"), let tx = key("kNStatSrcKeyTxBytes")
            else { return nil }
            return API(create: create, addTCP: addTCP, addUDP: addUDP, destroy: destroy, query: query,
                       queryDescriptions: queryDesc, setCounts: setCounts, setDescription: setDesc,
                       setRemoved: setRemoved, keyPID: pid, keyRx: rx, keyTx: tx)
        }()
    }

    /// One socket. Only touched on `queue`.
    private final class Source {
        var pid: pid_t = -1
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var seen = false
    }

    private let queue = DispatchQueue(label: "monitr.netstat", qos: .utility)
    private var manager: OpaquePointer?
    private var sources: [OpaquePointer: Source] = [:]
    private var unknownPid = false
    // Bytes moved per pid since the last `take`.
    private var moved: [pid_t: (UInt64, UInt64)] = [:]
    private var lastTake = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

    static var isAvailable: Bool { API.shared != nil }

    func start() {
        guard let api = API.shared else { return }
        queue.sync {
            guard manager == nil else { return }
            manager = api.create(kCFAllocatorDefault, queue) { [weak self] src, _ in
                self?.added(src, api: api)
            }
            if let m = manager {
                api.addTCP(m)
                api.addUDP(m)
            }
            lastTake = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        }
    }

    func stop() {
        guard let api = API.shared else { return }
        queue.sync {
            if let m = manager { api.destroy(m) }
            manager = nil
            sources.removeAll()
            moved.removeAll()
        }
    }

    /// Asks the kernel for fresh counters; results arrive on `queue` before the next `take`.
    func refresh() {
        guard let api = API.shared else { return }
        queue.async { [self] in
            guard let m = manager else { return }
            if unknownPid {
                unknownPid = false
                api.queryDescriptions(m, nil)
            }
            api.query(m, nil)
        }
    }

    /// Bytes per second per pid since the previous call.
    func take() -> [pid_t: (Double, Double)] {
        queue.sync {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let secs = max(Double(now - lastTake) / 1e9, 0.001)
            lastTake = now
            var out = [pid_t: (Double, Double)](minimumCapacity: moved.count)
            for (pid, b) in moved where b.0 > 0 || b.1 > 0 {
                out[pid] = (Double(b.0) / secs, Double(b.1) / secs)
            }
            moved.removeAll(keepingCapacity: true)
            return out
        }
    }

    private func added(_ src: OpaquePointer, api: API) {
        let s = Source()
        sources[src] = s
        unknownPid = true
        api.setDescription(src) { d in
            let dict = d as NSDictionary
            if let pid = dict[api.keyPID] as? NSNumber { s.pid = pid.int32Value }
        }
        api.setCounts(src) { [weak self] d in
            let dict = d as NSDictionary
            let rx = (dict[api.keyRx] as? NSNumber)?.uint64Value ?? s.rx
            let tx = (dict[api.keyTx] as? NSNumber)?.uint64Value ?? s.tx
            // The first report is the socket's lifetime total; count only what moved after we saw it.
            let first = !s.seen
            s.seen = true
            let dRx = rx >= s.rx ? rx - s.rx : 0
            let dTx = tx >= s.tx ? tx - s.tx : 0
            s.rx = rx; s.tx = tx
            guard !first, s.pid > 0, let self else { return }
            let cur = self.moved[s.pid] ?? (0, 0)
            self.moved[s.pid] = (cur.0 + dRx, cur.1 + dTx)
        }
        api.setRemoved(src) { [weak self] in self?.sources[src] = nil }
    }
}
