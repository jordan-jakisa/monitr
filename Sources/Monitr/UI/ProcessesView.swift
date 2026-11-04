import SwiftUI

enum ProcFilter: String, CaseIterable, Identifiable {
    case all = "All", nonCritical = "Non-critical", idle = "Idle", system = "System"
    var id: String { rawValue }
}

struct ProcessesView: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appKey: String?
    var onBack: () -> Void = {}
    @State private var appName = ""

    @State private var search = ""
    @State private var filter: ProcFilter = .all
    @State private var sortOrder = [KeyPathComparator(\ProcInfo.cpu, order: .reverse)]
    @State private var selection = Set<pid_t>()

    private var rows: [ProcInfo] {
        let q = search.trimmingCharacters(in: .whitespaces)
        var list = store.processes.filter { p in
            if let appKey, p.appKey != appKey { return false }
            switch filter {
            case .all: break
            case .nonCritical: if !p.nonCritical { return false }
            case .idle: if !p.tags.contains(.idle) { return false }
            case .system: if !p.tags.contains(.system) { return false }
            }
            if q.isEmpty { return true }
            return p.name.localizedCaseInsensitiveContains(q) || p.appName.localizedCaseInsensitiveContains(q)
                || (p.path as NSString).lastPathComponent.localizedCaseInsensitiveContains(q)
                || String(p.pid) == q
        }
        list.sort(using: sortOrder)
        return list
    }

    private var group: AppGroup? { appKey.flatMap { key in store.apps.first { $0.id == key } } }

    var body: some View {
        let rows = rows
        let gone = appKey != nil && group == nil && !store.processes.isEmpty
        VStack(spacing: 0) {
            if gone {
                ContentUnavailableView {
                    Label("\(appName.isEmpty ? "This app" : appName) is no longer running", systemImage: "checkmark.circle")
                } description: {
                    Text("It quit, so it has no processes left to show.")
                } actions: {
                    Button("Back to Overview", action: onBack)
                }
                .transition(.opacity)
            } else {
                if let g = group {
                    AppHeader(group: g)
                    Divider()
                }
                table(rows)
            }
        }
        .motion(Motion.reveal, value: gone)
        .onChange(of: group?.name, initial: true) { _, name in if let name { appName = name } }
        .searchable(text: $search, placement: .toolbar, prompt: "Process, app or pid")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Filter", selection: $filter.animation(reduceMotion ? nil : Motion.reveal)) {
                    ForEach(ProcFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .navigationSubtitle(gone ? "" : "\(rows.count) processes")
        .navigationTitle(appKey == nil ? "All processes" : (appName.isEmpty ? "App" : appName))
    }

    @ViewBuilder
    private func emptyState() -> some View {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            switch filter {
            case .all:
                ContentUnavailableView("No processes", systemImage: "list.bullet")
            case .nonCritical:
                ContentUnavailableView("Nothing non-critical", systemImage: "checkmark.circle",
                                       description: Text("Every process here is part of macOS, or busy and in use."))
            case .idle:
                ContentUnavailableView("Nothing idle", systemImage: "checkmark.circle",
                                       description: Text("No process has sat unused for \(Int(ProcessSampler.idleAfter / 60)) minutes."))
            case .system:
                ContentUnavailableView("No system processes", systemImage: "apple.logo",
                                       description: Text("Everything here belongs to you and can be stopped."))
            }
        }
    }

    private func table(_ rows: [ProcInfo]) -> some View {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Process", value: \.name) { p in
                    HStack(spacing: Space.s) {
                        AppIcon(key: p.appKey, size: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.name).lineLimit(1)
                            // Always two lines, so every row has the same height.
                            subtitle(p).font(.caption).lineLimit(1)
                        }
                    }
                    .help((p.path.isEmpty ? "pid \(p.pid)" : "\(p.path)\npid \(p.pid)")
                          + (p.measured ? "" : "\nOwned by macOS or another user: macOS does not share its usage."))
                }
                .width(min: 150, ideal: 200)

                TableColumn("CPU", value: \.cpu) { p in
                    Text(p.measured ? Fmt.percent(p.cpu) : "–").monospacedDigit()
                        .foregroundStyle(p.cpu >= 50 ? Color.orange : p.measured ? .primary : .secondary)
                }
                .width(min: 48, ideal: 54)

                TableColumn("Memory", value: \.memory) { p in
                    Text(p.measured ? Fmt.bytes(p.memory) : "–").monospacedDigit()
                        .foregroundStyle(p.measured ? .primary : .secondary)
                }
                .width(min: 64, ideal: 72)

                TableColumn("Power", value: \.powerSort) { p in
                    Text(p.power.map(Fmt.watts) ?? "–").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 56, ideal: 64)

                TableColumn("Network", value: \.netTotal) { p in
                    Text(Fmt.trafficShort(down: p.netIn, up: p.netOut))
                        .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 76, ideal: 96)

                TableColumn("") { p in
                    if p.killable {
                        StopButton { force in stop([p.pid], force: force) }
                    }
                }
                .width(52)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: pid_t.self) { pids in
                let killable = pids.filter { pid in store.processes.first { $0.pid == pid }?.killable == true }
                Button("Stop") { stop(Array(killable), force: false) }.disabled(killable.isEmpty)
                Button("Force Stop") { stop(Array(killable), force: true) }.disabled(killable.isEmpty)
                Divider()
                Button("Copy pid") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pids.map(String.init).joined(separator: " "), forType: .string)
                }
                if let pid = pids.first, let p = store.processes.first(where: { $0.pid == pid }), !p.path.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.selectFile(p.path, inFileViewerRootedAtPath: "") }
                }
            }
            .overlay {
                if store.processes.isEmpty {
                    ProgressView()
                } else if rows.isEmpty {
                    emptyState().transition(.opacity)
                }
            }
    }

    /// "Safari", "macOS", "Helper, idle 4m": what the process is, then its state when it matters.
    private func subtitle(_ p: ProcInfo) -> Text {
        let kind = Text(p.kindText(showApp: appKey == nil)).foregroundColor(.secondary)
        if p.tags.contains(.idle) {
            return kind + Text(", idle \(Fmt.duration(p.idleSeconds))").foregroundColor(.orange)
        }
        if p.tags.contains(.background) && appKey != nil {
            return kind + Text(", background").foregroundColor(.secondary)
        }
        return kind
    }

    private func stop(_ pids: [pid_t], force: Bool) {
        withAnimation(reduceMotion ? nil : Motion.list) {
            for pid in pids { store.stop(pid: pid, force: force) }
        }
        selection.subtract(pids)
    }
}

private struct AppHeader: View {
    @Environment(Store.self) private var store
    let group: AppGroup

    var body: some View {
        HStack(spacing: Space.m) {
            AppIcon(key: group.id, size: 36)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(group.name).font(.title3.weight(.semibold))
                HStack(spacing: Space.l) {
                    Label(Fmt.percent(group.cpu), systemImage: "cpu")
                    Label(Fmt.bytes(group.memory), systemImage: "memorychip")
                    if group.netIn + group.netOut >= 1 {
                        Label(Fmt.traffic(down: group.netIn, up: group.netOut), systemImage: "network")
                    }
                    if let st = group.statusText { TagLabel(text: st.0, tone: st.1) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            if group.killable {
                StopButton(title: group.isAppBundle ? "Quit" : "Stop all") { force in
                    withAnimation(Motion.list) { store.stop(app: group.id, force: force) }
                }
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.m)
    }
}

extension ProcInfo {
    /// Second line under the process name: the owning app, or what kind of process it is.
    func kindText(showApp: Bool) -> String {
        if showApp, appName != name { return appName }
        if tags.contains(.system) { return measured ? "macOS" : "macOS, usage hidden" }
        return isAppBundle ? (appName == name ? "App" : "Helper") : "Command-line tool"
    }

    var netTotal: Double { netIn + netOut }
    var powerSort: Double { power ?? -1 }
}
