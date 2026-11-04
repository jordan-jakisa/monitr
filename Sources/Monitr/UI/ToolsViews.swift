import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Quick quit

struct QuickQuitView: View {
    @State private var quick = QuickQuit.shared

    var body: some View {
        let running = quick.runningCount
        Form {
            Section {
                if quick.entries.isEmpty {
                    Text("No apps yet. Add the ones you close together, like chat and music apps at the end of the day.")
                        .foregroundStyle(.secondary)
                }
                ForEach(quick.entries) { e in
                    HStack(spacing: Space.s) {
                        AppIcon(key: e.path, size: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(e.name)
                            Text(quick.isRunning(e) ? "Running" : "Not running").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { withAnimation(Motion.list) { quick.remove(e) } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(e.name) from the list")
                        .accessibilityLabel("Remove \(e.name)")
                    }
                    .transition(.opacity)
                }
                HStack {
                    Menu {
                        ForEach(quick.addableRunningApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? "App") { if let u = app.bundleURL { withAnimation(Motion.list) { quick.add(url: u) } } }
                        }
                        if !quick.addableRunningApps.isEmpty { Divider() }
                        Button("Choose from Applications…") { chooseApp() }
                    } label: {
                        Label("Add app", systemImage: "plus")
                    }
                    .fixedSize()
                    Spacer()
                }
            } header: {
                Text("Apps to quit together")
            } footer: {
                Text("Each app gets a normal quit, so it can still ask you to save. Also in the menu bar menu.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    quick.quitAll()
                } label: {
                    Text(running == 0 ? "None of these apps are running" : "Quit \(running) \(running == 1 ? "app" : "apps")")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(running == 0)
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .navigationTitle("Quick quit")
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { panel.urls.forEach { quick.add(url: $0) } }
    }
}

// MARK: Disk clean

struct DiskCleanView: View {
    @State private var clean = DiskClean.shared
    @State private var confirming = false
    @State private var addError: String?

    var body: some View {
        let total = clean.selectedSize
        Form {
            Section {
                ForEach(clean.targets.filter { !$0.custom }) { t in row(t) }
            } header: {
                Text("Safe to clear")
            } footer: {
                Text("Apps and tools rebuild these when they need them. Items go to the Trash, so you can put anything back until you empty it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(clean.targets.filter(\.custom)) { t in row(t) }
                if clean.targets.allSatisfy({ !$0.custom }) {
                    Text("No folders of your own yet.").foregroundStyle(.secondary)
                }
                Button { chooseFolder() } label: { Label("Add folder…", systemImage: "plus") }
                    .buttonStyle(.borderless)
                if let addError { Text(addError).foregroundStyle(.red).font(.callout) }
            } header: {
                Text("Your folders")
            } footer: {
                Label("Advanced: everything inside a folder you add is moved to the Trash. Add only folders whose contents you never need, like a build or download cache.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            Section {
                if let r = clean.lastResult {
                    HStack {
                        Label(r, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Trash") {
                            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                        }
                    }
                }
                Button {
                    confirming = true
                } label: {
                    HStack {
                        if clean.cleaning || clean.measuring { ProgressView().controlSize(.small) }
                        Text(buttonTitle(total)).frame(maxWidth: .infinity)
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(clean.cleaning || clean.measuring || total == 0)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .navigationTitle("Disk clean")
        .toolbar {
            ToolbarItem {
                Button { clean.measure() } label: { Label("Measure again", systemImage: "arrow.clockwise") }
                    .disabled(clean.measuring || clean.cleaning)
                    .help("Measure the folders again")
            }
        }
        .onAppear { clean.measure() }
        .confirmationDialog("Move \(Fmt.bytes(UInt64(total))) to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { clean.clean() }
        } message: {
            Text(clean.targets.filter { clean.selected.contains($0.id) && $0.exists }.map(\.name).joined(separator: ", ")
                 + ". You can put items back from the Trash until you empty it.")
        }
    }

    private func buttonTitle(_ total: Int64) -> String {
        if clean.cleaning { return "Moving to Trash…" }
        if clean.measuring { return "Measuring…" }
        return total == 0 ? "Nothing selected to clear" : "Move \(Fmt.bytes(UInt64(total))) to Trash"
    }

    private func row(_ t: DiskClean.Target) -> some View {
        Toggle(isOn: Binding(
            get: { clean.selected.contains(t.id) },
            set: { on in if on { clean.selected.insert(t.id) } else { clean.selected.remove(t.id) } }
        )) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(t.name)
                    Text(t.exists ? t.detail : "Not on this Mac").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !t.exists {
                    EmptyView()
                } else if let s = t.size {
                    Text(Fmt.bytes(UInt64(s))).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                if t.custom {
                    Button { clean.removeCustom(t) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .help("Remove this folder from the list")
                        .accessibilityLabel("Remove \(t.name)")
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!t.exists)
        .help(DiskClean.tilde(t.path))
    }

    private func chooseFolder() {
        addError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder whose contents are always safe to delete."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try clean.addCustom(url) } catch { addError = error.localizedDescription }
    }
}
