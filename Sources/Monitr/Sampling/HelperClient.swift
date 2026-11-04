import Foundation
import MonitrShared
import ServiceManagement

/// Talks to the optional root helper, which reports CPU, memory and energy for processes owned
/// by macOS or other users. Used only while per-process data is on screen.
final class HelperClient: @unchecked Sendable {
    static let shared = HelperClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var cachedStatus: SMAppService.Status = .notRegistered
    private var statusCheckedAt = Date.distantPast

    var service: SMAppService { SMAppService.daemon(plistName: HelperInfo.plistName) }

    /// Asking ServiceManagement for status is an XPC call, so it is cached for 30 seconds.
    var status: SMAppService.Status {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(statusCheckedAt) > 30 {
            cachedStatus = service.status
            statusCheckedAt = Date()
        }
        return cachedStatus
    }

    func refreshStatus() {
        lock.lock(); statusCheckedAt = .distantPast; lock.unlock()
        _ = status
    }

    func register() throws {
        try service.register()
        refreshStatus()
    }

    func unregister() throws {
        dropConnection()
        try service.unregister()
        refreshStatus()
    }

    /// Usage for every process the helper can read, keyed by pid. Nil when the helper is off,
    /// not yet approved, or slow to answer (it never blocks a tick for more than half a second).
    func usage() -> [pid_t: HelperRecord]? {
        guard status == .enabled else { return nil }
        let c = currentConnection()
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        let proxy = c.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? MonitrHelperProtocol
        guard let proxy else { return nil }
        proxy.usage { data in
            box.set(data)
            done.signal()
        }
        guard done.wait(timeout: .now() + 0.5) == .success, let data = box.get() else { return nil }
        var out: [pid_t: HelperRecord] = [:]
        for r in HelperRecord.unpack(data) { out[r.pid] = r }
        return out
    }

    private final class Box: @unchecked Sendable {
        private var data: Data?
        private let lock = NSLock()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: HelperInfo.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: MonitrHelperProtocol.self)
        // Only trust a helper signed by the same developer team.
        c.setCodeSigningRequirement(HelperInfo.helperRequirement)
        c.invalidationHandler = { [weak self] in self?.dropConnection() }
        c.resume()
        connection = c
        return c
    }

    private func dropConnection() {
        lock.lock()
        let c = connection
        connection = nil
        lock.unlock()
        c?.invalidate()
    }
}
