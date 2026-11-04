import os
import ServiceManagement
import SwiftUI

private let log = Logger(subsystem: "me.jordanjakisa.monitr", category: "helper")

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
                FormNote("With nothing selected, Monitr shows only its icon.")
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
                LabeledContent("Status", value: helperStatusText)
                if let helperError { Text(helperError).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            } header: {
                Text("System processes")
            } footer: {
                FormNote("macOS shows CPU and memory for its own processes (WindowServer, kernel_task and others) only to administrators. This adds a small helper that runs with administrator rights, starts only while Monitr's window is open and quits when idle. It can only read usage numbers; it cannot stop or change anything.")
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

    private var helperStatusText: String {
        switch helperStatus {
        case .enabled: "On"
        case .requiresApproval: "Waiting for your approval in Login Items"
        // macOS reports a never-registered service as "not found", so both read as Off.
        case .notRegistered, .notFound: "Off"
        @unknown default: "Unknown"
        }
    }

    private func setHelper(_ on: Bool) {
        helperError = nil
        var failure: NSError?
        do {
            if on { try HelperClient.shared.register() } else { try HelperClient.shared.unregister() }
        } catch {
            failure = error as NSError
        }
        HelperClient.shared.refreshStatus()
        helperStatus = HelperClient.shared.service.status
        // Registering a daemon that still needs the user's approval throws "Operation not
        // permitted" although it worked; only report errors that left it in the wrong state.
        if let ns = failure, !(on && helperStatus == .requiresApproval) {
            helperError = "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
            log.error("helper \(on ? "register" : "unregister", privacy: .public) failed: \(ns.domain, privacy: .public) \(ns.code) \(ns.localizedDescription, privacy: .public)")
        }
        log.notice("helper status after \(on ? "register" : "unregister", privacy: .public): \(helperStatus.rawValue)")
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
