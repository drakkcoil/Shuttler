//
//  HelpView.swift
//  Shuttler
//
//  Help documentation and quick reference guide
//

import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    // Header
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                        Text("Shuttler Help")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("Quick reference guide and tips")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, AppTheme.Spacing.m)
                    
                    Divider()
                    
                    // Getting Started
                    HelpSection(title: "Getting Started", icon: "sparkles") {
                        HelpItem(
                            title: "Create a Connection",
                            description: "Click 'New Connection' or press ⌘N to add a server. Enter the host, username, and choose your protocol (FTP, SFTP, or SCP)."
                        )
                        HelpItem(
                            title: "Connect to Server",
                            description: "Select a connection and click 'Connect' or press ⌘K. For password-based auth, you'll be prompted for credentials."
                        )
                        HelpItem(
                            title: "Transfer Files",
                            description: "Drag and drop files between your Mac and the remote server, or use the Upload/Download buttons in the toolbar."
                        )
                    }
                    
                    Divider()
                    
                    // Keyboard Shortcuts
                    HelpSection(title: "Keyboard Shortcuts", icon: "keyboard") {
                        HelpShortcut(key: "⌘N", description: "New Connection")
                        HelpShortcut(key: "⌘K", description: "Connect to selected server")
                        HelpShortcut(key: "⌘⇧K", description: "Disconnect from server")
                        HelpShortcut(key: "⌘R", description: "Refresh directory listing")
                        HelpShortcut(key: "⌘U", description: "Upload files")
                        HelpShortcut(key: "⌘⇧T", description: "Show Transfers window")
                        HelpShortcut(key: "⌘T", description: "New tab")
                        HelpShortcut(key: "⌘W", description: "Close tab")
                        HelpShortcut(key: "⌘⇧S", description: "Toggle sidebar")
                        HelpShortcut(key: "⌘A", description: "Select all files")
                        HelpShortcut(key: "⌘⌫", description: "Delete selected files")
                        HelpShortcut(key: "⌘?", description: "Show this help")
                    }
                    
                    Divider()
                    
                    // Features
                    HelpSection(title: "Features", icon: "star.fill") {
                        HelpItem(
                            title: "Multiple Tabs",
                            description: "Open multiple directories in tabs. Each tab maintains its own navigation history."
                        )
                        HelpItem(
                            title: "Drag and Drop",
                            description: "Drag files from Finder directly into the remote browser to upload, or drag remote files to download."
                        )
                        HelpItem(
                            title: "Concurrent Transfers",
                            description: "Transfer multiple files simultaneously. Adjust the concurrency limit in Settings."
                        )
                        HelpItem(
                            title: "File Operations",
                            description: "Right-click files for rename, delete, duplicate, change permissions, and more."
                        )
                        HelpItem(
                            title: "Search",
                            description: "Use ⌘F to search files in the current directory, or search connections in the sidebar."
                        )
                    }
                    
                    Divider()
                    
                    // Tips
                    HelpSection(title: "Tips & Tricks", icon: "lightbulb.fill") {
                        HelpItem(
                            title: "Quick Navigation",
                            description: "Click breadcrumb segments to jump to any parent directory. Use ⌘← to go back."
                        )
                        HelpItem(
                            title: "Multiple Selection",
                            description: "Hold ⌘ to select multiple files, or ⌘A to select all. Selected files can be downloaded together."
                        )
                        HelpItem(
                            title: "Menu Bar Status",
                            description: "Enable the menu bar item in Settings to see transfer status and quick actions from anywhere."
                        )
                        HelpItem(
                            title: "Connection Favorites",
                            description: "Star connections to add them to your favorites section for quick access."
                        )
                    }
                    
                    Divider()
                    
                    // Troubleshooting
                    HelpSection(title: "Troubleshooting", icon: "wrench.and.screwdriver") {
                        HelpItem(
                            title: "Connection Failed",
                            description: "Check your host, port, and credentials. For SFTP/SCP, ensure your SSH key path is correct."
                        )
                        HelpItem(
                            title: "Transfer Errors",
                            description: "Check your network connection and server permissions. Large files may take time to transfer."
                        )
                        HelpItem(
                            title: "Permission Denied",
                            description: "Ensure you have read/write permissions on the remote directory. Use the permissions editor to change file permissions."
                        )
                    }
                    
                    Spacer(minLength: AppTheme.Spacing.xl)
                }
                .padding(AppTheme.Spacing.xl)
                .frame(maxWidth: 800)
            }
            .navigationTitle("Help")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 600)
    }
}

struct HelpSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            HStack(spacing: AppTheme.Spacing.s) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
            }
            
            VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                content
            }
            .padding(.leading, AppTheme.Spacing.l)
        }
    }
}

struct HelpItem: View {
    let title: String
    let description: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

struct HelpShortcut: View {
    let key: String
    let description: String
    
    var body: some View {
        HStack {
            Text(key)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppTheme.Spacing.xs)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                .frame(width: 100, alignment: .leading)
            
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    HelpView()
}
