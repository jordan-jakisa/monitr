import Foundation

/// The root helper's whole interface. It only reads usage counters; it cannot stop, signal or
/// change any process, and it returns numbers only (no names, paths or arguments).
@objc public protocol MonitrHelperProtocol {
    /// Bumped when the record layout changes, so the app can tell an outdated helper apart.
    func version(reply: @escaping (Int) -> Void)
    /// Usage for every process the helper can read, packed as `HelperRecord`s.
    func usage(reply: @escaping (Data) -> Void)
}

public enum HelperInfo {
    public static let version = 1
    public static let machService = "me.jordanjakisa.monitr.helper"
    public static let plistName = "me.jordanjakisa.monitr.helper.plist"
    public static let appIdentifier = "me.jordanjakisa.monitr"
    public static let teamID = "VZ87DND9MP"

    /// Only Monitr signed by this team may talk to the helper, and the app only trusts a helper
    /// signed the same way.
    public static let appRequirement =
        "identifier \"\(appIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    public static let helperRequirement =
        "identifier \"\(machService)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
}

/// One process's counters. Plain values so a batch packs into Data with no encoder.
public struct HelperRecord {
    public var pid: Int32
    public var pad: Int32 = 0
    public var start: UInt64        // process start, microseconds since 1970 (detects pid reuse)
    public var cpuNs: UInt64        // user + system time, nanoseconds
    public var footprint: UInt64    // physical footprint, bytes
    public var energyNj: UInt64     // energy, nanojoules
    public var wakeups: UInt64      // package idle + interrupt wakeups

    public init(pid: Int32, start: UInt64, cpuNs: UInt64, footprint: UInt64, energyNj: UInt64, wakeups: UInt64) {
        self.pid = pid
        self.start = start
        self.cpuNs = cpuNs
        self.footprint = footprint
        self.energyNj = energyNj
        self.wakeups = wakeups
    }

    public static func pack(_ records: [HelperRecord]) -> Data {
        records.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func unpack(_ data: Data) -> [HelperRecord] {
        let n = data.count / MemoryLayout<HelperRecord>.stride
        guard n > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<HelperRecord>.stride, as: HelperRecord.self) }
        }
    }
}
