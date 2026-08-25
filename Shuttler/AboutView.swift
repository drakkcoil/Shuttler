import SwiftUI
#if os(macOS)
import AppKit
#endif

struct AboutView: View {
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Shuttler"
    }
    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(version) (\(build))"
    }
    
    private var copyrightString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        let year = formatter.string(from: Date())
        return "Copyright © \(year) Adam Newman. All rights reserved."
    }

    var body: some View {
        VStack(spacing: 24) {
#if os(macOS)
            if let appIcon = NSApplication.shared.applicationIconImage, appIcon.size.width > 0 {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .cornerRadius(24)
                    .shadow(radius: 8)
            } else {
                Image(systemName: "shippingbox.circle.fill")
                    .resizable()
                    .frame(width: 128, height: 128)
                    .foregroundStyle(.tint)
            }
#else
            Image(systemName: "shippingbox.circle.fill")
                .resizable()
                .frame(width: 128, height: 128)
                .foregroundStyle(.tint)
#endif

            VStack(spacing: 8) {
                AppTheme.Typography.title(appName)
                    .font(.system(size: 28, weight: .bold))
                AppTheme.Typography.subtitle(versionString)
                    .font(.system(size: 13))
            }

            VStack(spacing: 16) {
                Text("Secure, simple file transfers")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                VStack(alignment: .leading, spacing: 8) {
                    FeatureRow(icon: "lock.shield.fill", text: "SFTP and SCP support with native encryption")
                    FeatureRow(icon: "server.rack", text: "FTP and FTPS protocol support")
                    FeatureRow(icon: "arrow.up.arrow.down", text: "Drag-and-drop file transfers")
                    FeatureRow(icon: "bolt.fill", text: "Multiple concurrent transfers")
                }
                .padding(.horizontal)
            }
            
            Divider()
                .padding(.horizontal)
            
            Text(copyrightString)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            
            HStack(spacing: 20) {
                Link("GitHub", destination: URL(string: "https://github.com")!)
                    .font(.system(size: 12))
                Link("Support", destination: URL(string: "https://github.com")!)
                    .font(.system(size: 12))
            }
            .foregroundStyle(.link)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(minWidth: 480, minHeight: 600)
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

#Preview {
    AboutView()
}
