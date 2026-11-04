import AppKit
import Observation

/// A saved list of apps to quit together in one click (to free memory or end a session).
/// Apps get a normal quit, so they can still ask to save.
@MainActor
@Observable
final class QuickQuit {
    static let shared = QuickQuit()

    struct Entry: Codable, Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let path: String
    }

    private(set) var entries: [Entry] = []
    /// Bumped when apps launch or quit, so views re-check which entries are running.
    private(set) var runningVersion = 0

    private init() {
        if let data = UserDefaults.standard.data(forKey: "quickQuit"),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { QuickQuit.shared.runningVersion &+= 1 }
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: "quickQuit") }
    }

    func isRunning(_ e: Entry) -> Bool {
        _ = runningVersion
        return !NSRunningApplication.runningApplications(withBundleIdentifier: e.bundleID).isEmpty
    }

    var runningCount: Int { entries.filter(isRunning).count }

    func add(url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              id != Bundle.main.bundleIdentifier, !entries.contains(where: { $0.bundleID == id }) else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        entries.append(Entry(bundleID: id, name: name, path: url.path))
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func remove(_ e: Entry) {
        entries.removeAll { $0.bundleID == e.bundleID }
        save()
    }

    /// Regular apps running now that are not in the list yet (for the Add menu).
    var addableRunningApps: [NSRunningApplication] {
        _ = runningVersion
        let listed = Set(entries.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleURL != nil }
            .filter { guard let id = $0.bundleIdentifier else { return false }
                      return !listed.contains(id) && id != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    /// Quits every listed app that is running. Returns how many were asked to quit.
    @discardableResult
    func quitAll() -> Int {
        var asked: [(Entry, [NSRunningApplication])] = []
        for e in entries {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: e.bundleID)
            guard !apps.isEmpty else { continue }
            apps.forEach { $0.terminate() }
            asked.append((e, apps))
        }
        // An app with unsaved work stays open and asks; say so instead of failing silently.
        if !asked.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                let stayed = asked.filter { _, apps in apps.contains { !$0.isTerminated } }.map(\.0.name)
                guard !stayed.isEmpty else { return }
                Store.shared.show(Notice(
                    title: stayed.count == 1 ? "\(stayed[0]) did not quit" : "\(stayed.count) apps did not quit",
                    detail: "\(stayed.joined(separator: ", ")) may be asking to save changes.",
                    kind: .refused))
            }
        }
        return asked.count
    }
}
