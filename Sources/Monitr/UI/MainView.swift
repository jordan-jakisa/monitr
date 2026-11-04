import SwiftUI

enum Pane: Hashable {
    case overview, processes, settings
    case app(String)
}

struct MainView: View {
    @Environment(Store.self) private var store
    @State private var pane: Pane? = .overview
    @State private var appSearch = ""

    /// Sidebar apps in a stable order (user apps A to Z, then loose processes, then macOS)
    /// so rows don't jump around as numbers change.
    private var sidebarApps: [AppGroup] {
        store.apps.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func detail(for pane: Pane) -> some View {
        switch pane {
        case .overview:
            DashboardView { self.pane = .app($0) }.navigationTitle("Overview")
        case .processes:
            ProcessesView(appKey: nil).navigationTitle("All processes")
        case .app(let key):
            ProcessesView(appKey: key, onBack: { self.pane = .overview })
                .navigationTitle(store.apps.first { $0.id == key }?.name ?? "App")
        case .settings:
            SettingsView().navigationTitle("Settings")
        }
    }

    private func rank(_ g: AppGroup) -> Int { g.isSystem ? 2 : (g.isAppBundle ? 0 : 1) }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section {
                    Label("Overview", systemImage: "gauge.with.dots.needle.33percent").tag(Pane.overview)
                    Label("All processes", systemImage: "list.bullet").tag(Pane.processes)
                }
                Section("Apps") {
                    ForEach(sidebarApps) { g in
                        HStack(spacing: Space.s) {
                            AppIcon(key: g.id, size: 16)
                            Text(g.name).lineLimit(1)
                            Spacer(minLength: Space.xs)
                            if g.nonCritical {
                                Circle().fill(.orange).frame(width: 6, height: 6)
                                    .help(g.statusText?.0 ?? "")
                                    .accessibilityLabel(g.statusText?.0 ?? "")
                            }
                            Text(Fmt.percent(g.cpu))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .tag(Pane.app(g.id))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { pane = .settings } label: {
                    Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, Space.l).padding(.vertical, Space.m)
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
        .frame(minWidth: 920, minHeight: 580)
    }
}
