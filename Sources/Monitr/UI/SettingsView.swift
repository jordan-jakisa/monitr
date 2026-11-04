import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

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

            Section("How Monitr stays light") {
                Text("With this window closed, Monitr reads only whole-Mac counters. Per-process CPU, memory, power and network are measured only while this window or the menu bar panel is open.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .onAppear { loginStatus = SMAppService.mainApp.status }
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
