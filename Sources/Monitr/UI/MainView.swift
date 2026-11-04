import SwiftUI

enum Pane: Hashable {
    case overview, processes, settings, quickQuit, diskClean
    case app(String)
}

struct MainView: View {
    @Environment(Store.self) private var store
    @State private var pane: Pane? = .overview
    @AppStorage("showBackgroundItems") private var showBackground = false

    /// "Jordan's MacBook Air, up 2d 4h": which Mac this is, under the Overview title.
    private var machineSubtitle: String {
        var boot = timeval()
        var len = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &len, nil, 0)
        let up = Date().timeIntervalSince1970 - Double(boot.tv_sec)
        return "\(Self.macName), up \(Fmt.duration(up))"
    }
    private static let macName = Host.current().localizedName ?? "This Mac"

    @ViewBuilder
    private func detail(for pane: Pane) -> some View {
        switch pane {
        case .overview:
            NavigationStack {
                DashboardView { self.pane = .app($0) }
                    .navigationTitle("Overview")
                    .navigationSubtitle(machineSubtitle)
                    .navigationDestination(for: MetricKind.self) { MetricDetailView(kind: $0) }
            }
        case .processes:
            ProcessesView(appKey: nil).navigationTitle("All processes")
        case .app(let key):
            ProcessesView(appKey: key, onBack: { self.pane = .overview })
        case .settings:
            SettingsView().navigationTitle("Settings")
        case .quickQuit:
            QuickQuitView()
        case .diskClean:
            DiskCleanView()
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section {
                    Label("Overview", systemImage: "gauge.with.dots.needle.33percent").tag(Pane.overview)
                    Label("All processes", systemImage: "list.bullet").tag(Pane.processes)
                }
                Section("Tools") {
                    Label("Quick quit", systemImage: "xmark.square").tag(Pane.quickQuit)
                    Label("Disk clean", systemImage: "internaldrive").tag(Pane.diskClean)
                }
                let entries = store.sidebar.filter { store.search.isEmpty || $0.name.localizedCaseInsensitiveContains(store.search) }
                Section("Apps") {
                    ForEach(entries.filter(\.isApp)) { e in
                        SidebarRow(key: e.key, name: e.name, flag: e.flag).equatable().tag(Pane.app(e.key))
                    }
                }
                // Daemons, helpers and system parts: useful, but not what people look for first.
                Section(isExpanded: Binding(get: { showBackground || !store.search.isEmpty }, set: { showBackground = $0 })) {
                    ForEach(entries.filter { !$0.isApp }) { e in
                        SidebarRow(key: e.key, name: e.name, flag: e.flag).equatable().tag(Pane.app(e.key))
                    }
                } header: {
                    Text("Background (\(entries.filter { !$0.isApp }.count))")
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Pinned to the bottom like Finder's sidebar footer, but it shows when it is the
                // current page, exactly like the rows above.
                Button { pane = .settings } label: {
                    Label("Settings", systemImage: "gearshape")
                        .foregroundStyle(pane == .settings ? Color.white : Color.primary)
                        .padding(.horizontal, Space.s).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(pane == .settings ? Color.accentColor : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                .padding(.horizontal, Space.s).padding(.vertical, Space.s)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            ZStack {
                detail(for: pane ?? .overview)
                    .id(pane ?? .overview)
                    .transition(.opacity)
            }
            .motion(Motion.reveal, value: pane)
            .overlay(alignment: .bottom) {
                if let n = store.notice {
                    NoticeBar(notice: n)
                        .padding(Space.l)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .motion(Motion.reveal, value: store.notice?.id)
        }
        // No separate toolbar band: content scrolls under a clear bar, so there is no seam where
        // the bar and the sidebar divider fail to line up.
        .toolbarBackground(.hidden, for: .windowToolbar)
        // Search lives at the top of the sidebar, like Mail and Notes: it narrows the app list and
        // the process table, and jumps to the table from pages that have none.
        .searchable(text: Bindable(store).search, placement: .sidebar, prompt: "Search apps and processes")
        .onChange(of: store.search) { _, q in
            guard !q.isEmpty else { return }
            switch pane {
            case .processes?, .app?: break
            default: pane = .processes
            }
        }
        .onChange(of: store.navigateTo) { _, target in
            if let target { pane = target; store.navigateTo = nil }
        }
        .frame(minWidth: 920, minHeight: 580)
    }
}

/// Only its inputs (not live CPU) are compared, so the sidebar re-renders a row only when the
/// app arrives, leaves or changes state; numbers live on the Overview and app pages.
private struct SidebarRow: View, Equatable {
    let key: String
    let name: String
    let flag: String?

    var body: some View {
        HStack(spacing: Space.s) {
            AppIcon(key: key, size: 16)
            Text(name).lineLimit(1)
            Spacer(minLength: Space.xs)
            if let flag {
                Circle().fill(.orange).frame(width: 6, height: 6)
                    .help(flag)
                    .accessibilityLabel(flag)
            }
        }
    }
}
