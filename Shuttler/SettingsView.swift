import SwiftUI

struct SettingsView: View {
    @State private var settings = SettingsModel()

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            transfers
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down.circle") }
            advanced
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 320)
    }

    private var general: some View {
        Form {
            Picker("List density", selection: $settings.listDensity) {
                ForEach(ListDensity.allCases) { density in
                    Text(density.displayName).tag(density)
                }
            }
            Picker("Default protocol", selection: $settings.defaultProtocol) {
                ForEach(ProtocolType.allCases) { proto in
                    Text(proto.displayName).tag(proto)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var transfers: some View {
        Form {
            Stepper(value: $settings.transferConcurrency, in: 1...8) {
                Text("Transfer concurrency: \(settings.transferConcurrency)")
            }
            HStack {
                TextField("Default download folder", text: $settings.defaultDownloadFolder)
                Button { selectFolder() } label: { Label("Choose…", systemImage: "folder") }
            }
            Picker("When a file exists", selection: $settings.overwriteBehavior) {
                ForEach(OverwriteBehavior.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var advanced: some View {
        Form {
            TextField("Default SSH key path", text: $settings.sshKeyPath)
            Stepper(value: $settings.commandTimeout, in: 5...300, step: 5) {
                Text("Command timeout: \(Int(settings.commandTimeout))s")
            }
        }
        .formStyle(.grouped)
    }

    private func selectFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.defaultDownloadFolder = url.path
        }
        #endif
    }
}

#Preview {
    SettingsView()
}
