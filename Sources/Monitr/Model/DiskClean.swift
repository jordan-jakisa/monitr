import AppKit
import Observation

/// Frees disk space by moving cache-type folders' contents to the Trash. Nothing is deleted
/// outright: the space comes back when the Trash is emptied, and anything can be put back.
@MainActor
@Observable
final class DiskClean {
    static let shared = DiskClean()

    struct Target: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
        let path: String
        let custom: Bool
        var size: Int64?          // nil while measuring
        var exists = true
    }

    private(set) var targets: [Target] = []
    var selected: Set<String> = []
    private(set) var measuring = false
    private(set) var cleaning = false
    private(set) var lastResult: String?
    private(set) var customPaths: [String] = []

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Regenerable data only: apps and tools rebuild these on demand.
    private static let builtIn: [(id: String, name: String, detail: String, path: String, on: Bool)] = [
        ("caches", "App caches", "Temporary files apps rebuild when needed", "~/Library/Caches", true),
        ("logs", "Logs", "Old diagnostic logs from apps", "~/Library/Logs", true),
        ("derived", "Xcode build data", "DerivedData; Xcode rebuilds it on the next build", "~/Library/Developer/Xcode/DerivedData", true),
        ("simcache", "Simulator caches", "Rebuilt when a simulator next starts", "~/Library/Developer/CoreSimulator/Caches", true),
        ("gradle", "Gradle caches", "Downloaded again on the next Android build (slow)", "~/.gradle/caches", false),
        ("npm", "npm cache", "Packages download again when next installed", "~/.npm/_cacache", false),
    ]

    private init() {
        customPaths = UserDefaults.standard.stringArray(forKey: "diskCleanCustom") ?? []
        rebuild()
        selected = Set(Self.builtIn.filter(\.on).map(\.id))
    }

    private func rebuild() {
        let fm = FileManager.default
        var list = Self.builtIn.map {
            Target(id: $0.id, name: $0.name, detail: $0.detail, path: Self.expand($0.path), custom: false)
        }
        list += customPaths.map {
            Target(id: "custom:" + $0, name: ($0 as NSString).lastPathComponent, detail: Self.tilde($0), path: $0, custom: true)
        }
        for i in list.indices { list[i].exists = fm.fileExists(atPath: list[i].path) }
        targets = list
    }

    static func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }
    static func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

    var selectedSize: Int64 {
        targets.filter { selected.contains($0.id) && $0.exists }.compactMap(\.size).reduce(0, +)
    }

    // MARK: Measuring

    func measure() {
        guard !measuring else { return }
        measuring = true
        lastResult = nil
        let paths = targets.map { ($0.id, $0.path) }
        for i in targets.indices { targets[i].size = nil }
        Task.detached(priority: .utility) {
            for (id, path) in paths {
                let size = Self.allocatedSize(of: path)
                await MainActor.run {
                    if let i = DiskClean.shared.targets.firstIndex(where: { $0.id == id }) {
                        DiskClean.shared.targets[i].size = size
                    }
                }
            }
            await MainActor.run { DiskClean.shared.measuring = false }
        }
    }

    nonisolated static func allocatedSize(of path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var total: Int64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        if total == 0, let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
            total = Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Cleaning

    /// Moves the contents of each selected folder (or the selected file) to the Trash.
    func clean() {
        guard !cleaning else { return }
        cleaning = true
        let chosen = targets.filter { selected.contains($0.id) && $0.exists }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var moved: Int64 = 0
            var skipped = 0
            for t in chosen {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: t.path, isDirectory: &isDir) else { continue }
                // Folders keep existing (apps expect them); only what is inside goes.
                let items = isDir.boolValue
                    ? ((try? fm.contentsOfDirectory(atPath: t.path)) ?? []).map { (t.path as NSString).appendingPathComponent($0) }
                    : [t.path]
                for item in items {
                    let size = Self.allocatedSize(of: item)
                    do {
                        try fm.trashItem(at: URL(fileURLWithPath: item), resultingItemURL: nil)
                        moved += size
                    } catch {
                        skipped += 1  // in use or protected by macOS; left alone
                    }
                }
            }
            let summary = skipped == 0
                ? "Moved \(Fmt.bytes(UInt64(moved))) to the Trash. Empty the Trash to free the space."
                : "Moved \(Fmt.bytes(UInt64(moved))) to the Trash. \(skipped) items were in use or protected and were left alone. Empty the Trash to free the space."
            await MainActor.run {
                DiskClean.shared.cleaning = false
                DiskClean.shared.lastResult = summary
                DiskClean.shared.measure()
                DiskClean.shared.lastResult = summary
            }
        }
    }

    // MARK: Custom targets

    enum AddError: LocalizedError {
        case unsafe(String)
        var errorDescription: String? { if case .unsafe(let s) = self { return s }; return nil }
    }

    /// Refuses places where deleting contents would lose personal files or break macOS.
    func addCustom(_ url: URL) throws {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let h = Self.home
        let blocked = ["/", "/System", "/Library", "/Applications", "/Users", "/usr", "/bin", "/sbin", "/private", "/Volumes",
                       h, h + "/Desktop", h + "/Documents", h + "/Downloads", h + "/Pictures", h + "/Movies", h + "/Music",
                       h + "/Library", h + "/Library/Mobile Documents", h + "/Library/CloudStorage", h + "/Applications"]
        if blocked.contains(p) || h.hasPrefix(p + "/") {
            throw AddError.unsafe("\(Self.tilde(p)) holds personal files or parts of macOS, so it can't be a cleanup target.")
        }
        if p.hasPrefix("/System/") || p.hasPrefix("/usr/") || p.hasPrefix("/bin/") || p.hasPrefix("/sbin/") {
            throw AddError.unsafe("Folders inside macOS can't be cleanup targets.")
        }
        guard !customPaths.contains(p) else { return }
        customPaths.append(p)
        UserDefaults.standard.set(customPaths, forKey: "diskCleanCustom")
        rebuild()
        selected.insert("custom:" + p)
        measure()
    }

    func removeCustom(_ t: Target) {
        customPaths.removeAll { $0 == t.path }
        UserDefaults.standard.set(customPaths, forKey: "diskCleanCustom")
        selected.remove(t.id)
        rebuild()
        measure()
    }
}
