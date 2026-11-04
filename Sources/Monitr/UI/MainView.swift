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
                        HStack(spacing: 8) {
                            AppIcon(key: g.id, size: 16)
                            Text(g.name).lineLimit(1)
                            Spacer(minLength: 4)
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
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            switch pane ?? .overview {
            case .overview:
                DashboardView { pane = .app($0) }.navigationTitle("Overview")
            case .processes:
                ProcessesView(appKey: nil).navigationTitle("All processes").id("all")
            case .app(let key):
                ProcessesView(appKey: key)
                    .navigationTitle(store.apps.first { $0.id == key }?.name ?? "App")
                    .id(key)
            case .settings:
                SettingsView().navigationTitle("Settings")
            }
        }
        .frame(minWidth: 920, minHeight: 580)
    }
}
