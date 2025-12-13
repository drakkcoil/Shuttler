import SwiftUI

struct AboutView: View {
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Shuttler"
    }
    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .cornerRadius(20)
                .shadow(radius: 4)

            AppTheme.Typography.title(appName)
            AppTheme.Typography.subtitle(versionString)

            Text("Secure, simple file transfers with FTP, SFTP, and SCP.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(minWidth: 360)
    }
}

#if os(macOS)
import AppKit
#endif

#Preview {
    AboutView()
}
