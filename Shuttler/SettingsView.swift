import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @State private var settings = SettingsModel()
    @AppStorage("settings.menuBarEnabled") private var menuBarEnabled: Bool = false

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            transfers
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down.circle") }
            advanced
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(minWidth: 600, minHeight: 450)
        .onChange(of: menuBarEnabled) { oldValue, newValue in
            #if os(macOS)
            // Use async dispatch to ensure we're on the main thread
            DispatchQueue.main.async {
                if newValue {
                    MenuBarManager.shared.setup()
                } else {
                    MenuBarManager.shared.teardown()
                }
            }
            #endif
        }
    }

    private var general: some View {
        Form {
            Section("Interface") {
                Toggle("Show menu bar status", isOn: $menuBarEnabled)
                    .help("Show transfer status and quick actions in the menu bar")
            }
            
            Section("Display") {
                Picker("List density", selection: $settings.listDensity) {
                    ForEach(ListDensity.allCases) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                .pickerStyle(.segmented)
                
                Picker("Default protocol", selection: $settings.defaultProtocol) {
                    ForEach(TransferProtocol.allCases) { proto in
                        Text(proto.displayName).tag(proto)
                    }
                }
                .help("Default protocol to use when creating new connections")
            }
            
            Section("Sorting") {
                Picker("Sort by", selection: $settings.sortKey) {
                    ForEach(SortKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                
                Toggle("Ascending", isOn: $settings.sortAscending)
                    .help("Sort items in ascending order (A-Z, smallest first)")
                
                Toggle("Folders first", isOn: $settings.foldersFirst)
                    .help("Always show folders before files in the listing")
            }
        }
        .formStyle(.grouped)
        .padding(AppTheme.Spacing.m)
    }

    private var transfers: some View {
        Form {
            Section {
                Stepper(value: $settings.transferConcurrency, in: 1...8) {
                    HStack {
                        Text("Concurrent transfers")
                        Spacer()
                        Text("\(settings.transferConcurrency)")
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Maximum number of file transfers to run simultaneously")
                
                HStack {
                    LabeledContent("Default download folder") {
                        HStack {
                            Text(settings.defaultDownloadFolder)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: 300, alignment: .trailing)
                            Button { selectFolder() } label: {
                                Label("Choose…", systemImage: "folder")
                            }
                        }
                    }
                }
                .help("Default location to save downloaded files")
            }
            
            Section("File Conflicts") {
                Picker("When a file exists", selection: $settings.overwriteBehavior) {
                    ForEach(OverwriteBehavior.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .help("What to do when uploading a file that already exists on the server")
                
                if settings.overwriteBehavior == .ask {
                    Text("You will be prompted each time a file conflict occurs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(AppTheme.Spacing.m)
    }

    private var advanced: some View {
        Form {
            Section("SSH") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                    LabeledContent("Default SSH key") {
                        HStack {
                            TextField("~/.ssh/id_ed25519", text: $settings.sshKeyPath)
                                .frame(maxWidth: 320)
                            
                            Button { selectSSHKey() } label: {
                                Label("Choose", systemImage: "folder")
                            }
                            
                            Button { useSuggestedSSHKey() } label: {
                                Label("Suggested", systemImage: "wand.and.stars")
                            }
                            .disabled(suggestedSSHKeyPath == nil)
                        }
                    }
                    .help("Default private key path to use for SSH authentication")
                    
                    sshKeyStatus
                }
            }
            
            Section("Performance") {
                Stepper(value: $settings.commandTimeout, in: 5...300, step: 5) {
                    HStack {
                        Text("Command timeout")
                        Spacer()
                        Text("\(Int(settings.commandTimeout))s")
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Maximum time to wait for SSH commands to complete")
            }
            
            Section {
                Text("These settings apply globally and will be used as defaults for new connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(AppTheme.Spacing.m)
    }

    private func selectFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: settings.defaultDownloadFolder)
        if panel.runModal() == .OK, let url = panel.url {
            settings.defaultDownloadFolder = url.path
        }
        #endif
    }
    
    private func selectSSHKey() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.prompt = "Choose"
        if let currentPath = settings.sshKeyPath.isEmpty ? nil : URL(fileURLWithPath: settings.sshKeyPath) {
            panel.directoryURL = currentPath.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            settings.sshKeyPath = url.path
        }
        #endif
    }
    
    @ViewBuilder
    private var sshKeyStatus: some View {
        if settings.sshKeyPath.isEmpty {
            Label("No default key selected", systemImage: "key")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if FileManager.default.fileExists(atPath: expandedPath(settings.sshKeyPath)) {
            HStack(spacing: AppTheme.Spacing.s) {
                Label((settings.sshKeyPath as NSString).lastPathComponent, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Reveal") {
                    revealSSHKey()
                }
                .buttonStyle(.borderless)
            }
        } else {
            Label("Key file not found", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
    
    private var suggestedSSHKeyPath: String? {
        let sshDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        let candidates = ["id_ed25519", "id_ecdsa", "id_rsa"]
        return candidates
            .map { sshDirectory.appendingPathComponent($0).path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }
    
    private func useSuggestedSSHKey() {
        settings.sshKeyPath = suggestedSSHKeyPath ?? settings.sshKeyPath
    }
    
    private func revealSSHKey() {
        #if os(macOS)
        let path = expandedPath(settings.sshKeyPath)
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        #endif
    }
    
    private func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}

#Preview {
    SettingsView()
}
