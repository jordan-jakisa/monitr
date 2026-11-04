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
                    EmptyRow(icon: "xmark.square", title: "No apps yet",
                             detail: "Add the apps you close together, like chat and music apps at the end of the day.")
                }
                ForEach(quick.entries) { e in
                    HStack(spacing: Space.m) {
                        AppIcon(key: e.path, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name)
                            HStack(spacing: Space.xs) {
                                Circle().fill(quick.isRunning(e) ? Color.green : Color.secondary.opacity(0.5))
                                    .frame(width: 6, height: 6)
                                    .accessibilityHidden(true)
                                Text(quick.isRunning(e) ? "Running" : "Not running")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        RemoveButton(name: e.name) { withAnimation(Motion.list) { quick.remove(e) } }
                    }
                    .padding(.vertical, 2)
                    .transition(.opacity)
                }
                Button { showAddMenu() } label: { AddLabel(title: "Add App") }
                    .buttonStyle(.borderless)
                    .help("Add a running app, or choose one from Applications")
            } header: {
                Text("Apps to quit together")
            } footer: {
                FormNote("Each app gets a normal quit, so it can still ask you to save. Also in the menu bar menu.")
            }

            if !quick.entries.isEmpty {
                Section {
                    if running == 0 {
                        Text("None of these apps are running right now.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Button { quick.quitAll() } label: {
                            Text("Quit \(running) \(running == 1 ? "App" : "Apps")").frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .motion(Motion.list, value: quick.entries.count)
        .navigationTitle("Quick quit")
    }

    /// A native pop-up menu at the pointer: running apps first, then the Applications picker.
    private func showAddMenu() {
        let menu = NSMenu()
        let running = quick.addableRunningApps
        if !running.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Running now"))
            for app in running {
                let item = ClosureMenuItem(title: app.localizedName ?? "App") {
                    if let u = app.bundleURL { withAnimation(Motion.list) { QuickQuit.shared.add(url: u) } }
                }
                if let icon = app.icon {
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(title: "Choose from Applications…") { chooseApp() })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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
                FormNote("Apps and tools rebuild these when they need them. Items go to the Trash, so you can put anything back until you empty it.")
            }

            Section {
                ForEach(clean.targets.filter(\.custom)) { t in row(t) }
                if clean.targets.allSatisfy({ !$0.custom }) {
                    EmptyRow(icon: "folder.badge.plus", title: "No folders of your own yet",
                             detail: "Add a folder whose contents are always safe to throw away.")
                }
                Button { chooseFolder() } label: { AddLabel(title: "Add Folder…") }
                    .buttonStyle(.borderless)
                if let addError { Text(addError).foregroundStyle(.red).font(.callout) }
            } header: {
                Text("Your folders")
            } footer: {
                FormNote("Advanced: everything inside a folder you add is moved to the Trash. Add only folders whose contents you never need, like a build or download cache.",
                         icon: "exclamationmark.triangle")
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
            get: { clean.selected.contains(t.id) && t.exists && t.size != 0 },
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
                } else if let s = t.size, s == 0 {
                    Text("Empty").foregroundStyle(.tertiary)
                } else if let s = t.size {
                    Text(Fmt.bytes(UInt64(s))).monospacedDigit().foregroundStyle(.secondary)
                        .transition(.opacity)
                } else {
                    Text("Measuring…").font(.callout).foregroundStyle(.tertiary)
                }
                if t.custom {
                    RemoveButton(name: t.name) { clean.removeCustom(t) }
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!t.exists || t.size == 0)
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

// MARK: Shared pieces

/// "+ Add …" in the accent colour, used the same way under every editable list.
private struct AddLabel: View {
    let title: String
    var body: some View {
        Label(title, systemImage: "plus.circle.fill")
            .foregroundStyle(Color.accentColor)
    }
}

private struct RemoveButton: View {
    let name: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Remove \(name) from the list")
        .accessibilityLabel("Remove \(name)")
    }
}

/// An empty list's first row: what goes here and why.
private struct EmptyRow: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Space.xs)
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
