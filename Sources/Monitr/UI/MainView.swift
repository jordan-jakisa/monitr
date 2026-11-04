import SwiftUI

enum Pane: Hashable {
    case overview, processes, settings, quickQuit, diskClean
    case app(String)
}

struct MainView: View {
    @Environment(Store.self) private var store
    @State private var pane: Pane? = .overview

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
                    Label("Disk clean", systemImage: "externaldrive.badge.minus").tag(Pane.diskClean)
                }
                Section("Apps") {
                    ForEach(store.sidebar) { e in
                        SidebarRow(key: e.key, name: e.name, flag: e.flag)
                            .equatable()
                            .tag(Pane.app(e.key))
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
