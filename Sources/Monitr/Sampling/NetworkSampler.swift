import Foundation

/// Per-process network totals from one-shot `nettop` snapshots.
///
/// macOS gives complete per-app network counters only to Apple's own entitled tools; an
/// ordinary app reading the kernel's network statistics misses most traffic (Safari's video,
/// anything over Network.framework). `nettop` is that entitled tool. A single snapshot costs
/// about 10 ms of CPU, so it is taken every few seconds while a window shows live rates and
/// once a minute otherwise, never in its continuous mode.
final class NetworkSampler: @unchecked Sendable {
    struct Snapshot {
        let at: UInt64                         // CLOCK_UPTIME_RAW ns
        let wall: Date
        let totals: [pid_t: (UInt64, UInt64)]  // lifetime bytes in, out
    }

    private var running: Process?
    private let lock = NSLock()

    /// Starts a snapshot unless one is already running. `done` is called on `queue`.
    func snapshot(on queue: DispatchQueue, done: @escaping (Snapshot) -> Void) {
        lock.lock()
        if running != nil { lock.unlock(); return }
        let task = Process()
        running = task
        lock.unlock()

        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        let at = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let wall = Date()
        let buffer = Buffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { buffer.append(d) }
        }
        task.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
            let totals = NettopParser.parse(buffer.take())
            self?.lock.lock(); self?.running = nil; self?.lock.unlock()
            queue.async { done(Snapshot(at: at, wall: wall, totals: totals)) }
        }
        do { try task.run() } catch {
            lock.lock(); running = nil; lock.unlock()
        }
    }

    private final class Buffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        func take() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
