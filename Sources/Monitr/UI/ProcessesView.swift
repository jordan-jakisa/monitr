import SwiftUI

enum ProcFilter: String, CaseIterable, Identifiable {
    case all = "All", nonCritical = "Non-critical", idle = "Idle", system = "System"
    var id: String { rawValue }
}

struct ProcessesView: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appKey: String?

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
                || String(p.pid) == q
        }
        list.sort(using: sortOrder)
        return list
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            if let appKey, let g = store.apps.first(where: { $0.id == appKey }) {
                AppHeader(group: g)
                Divider()
            }
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Process", value: \.name) { p in
                    HStack(spacing: 8) {
                        AppIcon(key: p.appKey, size: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.name).lineLimit(1)
                            if appKey == nil, p.appName != p.name {
                                Text(p.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .help((p.path.isEmpty ? "pid \(p.pid)" : "\(p.path)\npid \(p.pid)")
                          + (p.measured ? "" : "\nOwned by macOS or another user: macOS does not share its usage."))
                }
                .width(min: 160, ideal: 220)

                TableColumn("CPU", value: \.cpu) { p in
                    Text(p.measured ? Fmt.percent(p.cpu) : "–").monospacedDigit()
                        .foregroundStyle(p.cpu >= 50 ? Color.orange : p.measured ? .primary : .secondary)
                }
                .width(min: 56, ideal: 64)

                TableColumn("Memory", value: \.memory) { p in
                    Text(p.measured ? Fmt.bytes(p.memory) : "–").monospacedDigit()
                        .foregroundStyle(p.measured ? .primary : .secondary)
                }
                .width(min: 70, ideal: 80)

                TableColumn("Power", value: \.powerSort) { p in
                    Text(p.power.map(Fmt.watts) ?? "–").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 56, ideal: 64)

                TableColumn("Network", value: \.netTotal) { p in
                    Text(p.netTotal < 1 ? "–" : "↓\(Fmt.rate(p.netIn))  ↑\(Fmt.rate(p.netOut))")
                        .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 90, ideal: 130)

                TableColumn("Status", value: \.tagSort) { p in
                    if let st = p.statusText { TagLabel(text: st.0, tone: st.1) }
                }
                .width(min: 70, ideal: 90)

                TableColumn("") { p in
                    if p.killable {
                        StopButton { force in stop([p.pid], force: force) }
                    }
                }
                .width(56)
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
                if rows.isEmpty && !store.processes.isEmpty {
                    ContentUnavailableView.search(text: search.isEmpty ? filter.rawValue : search)
                } else if store.processes.isEmpty {
                    ProgressView()
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Process, app or pid")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Filter", selection: $filter.animation(reduceMotion ? nil : .smooth)) {
                    ForEach(ProcFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .navigationSubtitle("\(rows.count) processes")
    }

    private func stop(_ pids: [pid_t], force: Bool) {
        withAnimation(reduceMotion ? nil : .smooth) {
            for pid in pids { store.stop(pid: pid, force: force) }
        }
        selection.subtract(pids)
    }
}

private struct AppHeader: View {
    @Environment(Store.self) private var store
    let group: AppGroup

    var body: some View {
        HStack(spacing: 14) {
            AppIcon(key: group.id, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.title3.weight(.semibold))
                HStack(spacing: 14) {
                    Label(Fmt.percent(group.cpu), systemImage: "cpu")
                    Label(Fmt.bytes(group.memory), systemImage: "memorychip")
                    if group.netIn + group.netOut >= 1 {
                        Label("↓\(Fmt.rate(group.netIn)) ↑\(Fmt.rate(group.netOut))", systemImage: "network")
                    }
                    if let st = group.statusText { TagLabel(text: st.0, tone: st.1) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            if group.killable {
                StopButton(title: group.isAppBundle ? "Quit app" : "Stop all") { force in
                    withAnimation(.smooth) { store.stop(app: group.id, force: force) }
                }
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

extension ProcInfo {
    var netTotal: Double { netIn + netOut }
    var powerSort: Double { power ?? -1 }
    var tagSort: UInt8 { tags.rawValue }
}
