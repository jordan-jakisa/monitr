import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var helperStatus = HelperClient.shared.service.status
    @State private var helperError: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section("General") {
                Toggle("Open Monitr at login", isOn: Binding(
                    get: { loginStatus == .enabled },
                    set: { setLogin($0) }
                ))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("macOS needs your approval in Login Items.").foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError { Text(loginError).foregroundStyle(.red).font(.callout) }

                Picker("Update every", selection: $store.interval) {
                    Text("1 second").tag(1)
                    Text("2 seconds").tag(2)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
            }

            Section {
                ForEach(MenuStat.allCases) { stat in
                    Toggle(stat.title, isOn: Binding(
                        get: { store.menuStats.contains(stat) },
                        set: { on in
                            var s = store.menuStats.filter { $0 != stat }
                            if on { s.append(stat) }
                            // Keep the canonical order so the menu bar reads the same way every time.
                            store.menuStats = MenuStat.allCases.filter(s.contains)
                        }
                    ))
                }
            } header: {
                Text("Menu bar")
            } footer: {
                Text("With nothing selected, Monitr shows only its icon.").foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show usage for system processes", isOn: Binding(
                    get: { helperStatus == .enabled || helperStatus == .requiresApproval },
                    set: { setHelper($0) }
                ))
                if helperStatus == .requiresApproval {
                    HStack {
                        Text("Turn on Monitr under Allow in the Background, then come back.").foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let helperError { Text(helperError).foregroundStyle(.red).font(.callout) }
            } header: {
                Text("System processes")
            } footer: {
                Text("macOS shows CPU and memory for its own processes (WindowServer, kernel_task and others) only to administrators. This adds a small helper that runs with administrator rights, starts only while Monitr's window is open and quits when idle. It can only read usage numbers; it cannot stop or change anything.")
                    .foregroundStyle(.secondary)
            }

            Section("How Monitr stays light") {
                Text("With this window closed, Monitr reads only whole-Mac counters. Per-process CPU, memory, power and network are measured only while this window or the menu bar panel is open.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .onAppear {
            loginStatus = SMAppService.mainApp.status
            HelperClient.shared.refreshStatus()
            helperStatus = HelperClient.shared.service.status
        }
        // Coming back from System Settings after approving: pick up the new status.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            HelperClient.shared.refreshStatus()
            helperStatus = HelperClient.shared.service.status
        }
    }

    private func setHelper(_ on: Bool) {
        helperError = nil
        do {
            if on { try HelperClient.shared.register() } else { try HelperClient.shared.unregister() }
        } catch {
            helperError = error.localizedDescription
        }
        helperStatus = HelperClient.shared.service.status
        if on && helperStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    private func setLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }
}
