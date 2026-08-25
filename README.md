# Shuttler

A modern, secure file transfer application for macOS that supports FTP, SFTP, and SCP protocols with a beautiful SwiftUI interface.

## Features

### 🔐 Secure Protocols
- **SFTP** - Secure File Transfer Protocol with native encryption
- **SCP** - Secure Copy Protocol for fast file transfers
- **FTP/FTPS** - Traditional file transfer protocol support

### 🚀 Core Capabilities
- **Multiple Concurrent Transfers** - Upload and download multiple files simultaneously
- **Drag-and-Drop Support** - Intuitive file transfer interface
- **Connection Management** - Save and organize your server connections
- **Favorites** - Quick access to frequently used servers
- **SSH Key Authentication** - Support for password and SSH key-based authentication
- **Transfer Progress Tracking** - Real-time progress monitoring with transfer speed indicators
- **Remote File Browser** - Navigate remote directories with an intuitive file browser
- **Tabbed Interface** - Manage multiple connections in separate tabs
- **Menu Bar Integration** - Quick access to transfers and connection status

### 🎨 User Experience
- Modern SwiftUI interface following macOS design guidelines
- Keyboard shortcuts for common actions
- Transfer notifications and status updates
- Customizable sidebar and list density preferences
- Help documentation built into the app

## Requirements

- macOS 14.0 or later
- Xcode 15.0 or later (for building from source)
- Swift 5.0 or later

## Installation

### Building from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/shuttler.git
   cd shuttler
   ```

2. Open the project in Xcode:
   ```bash
   open Shuttler.xcodeproj
   ```

3. The project uses Swift Package Manager for dependencies. Xcode will automatically resolve:
   - [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) - Apple's NIOSSH library for native SSH/SFTP/SCP support

4. Build and run the project (⌘R)

## Usage

### Creating a Connection

1. Click "New Connection" or press `⌘N`
2. Enter your server details:
   - **Name**: A friendly name for this connection
   - **Protocol**: Choose FTP, SFTP, or SCP
   - **Host**: Server address or IP
   - **Port**: Server port (defaults provided)
   - **Username**: Your server username
   - **Authentication**: Choose password or SSH key
   - **Starting Directory**: Optional default directory

3. Click "Connect" or press `⌘K`

### Transferring Files

- **Upload**: Drag files from Finder into the remote browser, or use `⌘U`
- **Download**: Select files in the remote browser and press `Return` or use the download button
- **Multiple Files**: Select multiple files using `⌘A` or Shift+Click

### Keyboard Shortcuts

- `⌘N` - New Connection
- `⌘K` - Connect
- `⌘⇧K` - Disconnect
- `⌘R` - Refresh
- `⌘U` - Upload Files
- `Return` - Download Selected
- `⌘A` - Select All
- `⌘⇧T` - Show Transfers
- `⌘T` - New Tab
- `⌘W` - Close Tab
- `⌘⌃S` - Toggle Sidebar
- `⌘⇧?` - Help

## Architecture

### Key Components

- **ConnectionManager** - Manages connection state across the application
- **TransferManager** - Handles file transfer operations and progress tracking
- **SSHTransport** - Implements SFTP and SCP using system SSH tools
- **NativeSFTPClient** - Native SFTP implementation using NIOSSH
- **NativeSCPClient** - Native SCP implementation using NIOSSH
- **NativeFTPClient** - FTP protocol implementation
- **RemoteBrowserViewModel** - Manages remote file system navigation
- **ConnectionsStore** - Persists connection data to disk

### Technology Stack

- **SwiftUI** - Modern declarative UI framework
- **NIOSSH** - Apple's SwiftNIO SSH library for secure connections
- **Combine** - Reactive programming for state management
- **AppKit** - macOS-specific UI components

## Project Structure

```
Shuttler/
├── Shuttler/
│   ├── ShuttlerApp.swift          # Main app entry point
│   ├── ContentView.swift          # Primary UI view
│   ├── Models.swift               # Data models and persistence
│   ├── ConnectionManager.swift   # Connection state management
│   ├── TransferManager.swift      # Transfer operations
│   ├── SSHTransport.swift         # SSH/SFTP/SCP transport layer
│   ├── NativeSFTPClient.swift     # Native SFTP implementation
│   ├── NativeSCPClient.swift      # Native SCP implementation
│   ├── NativeFTPClient.swift      # FTP implementation
│   ├── RemoteBrowserViewModel.swift # Remote file browser logic
│   ├── MenuBarManager.swift       # Menu bar integration
│   ├── Settings.swift             # App settings
│   └── ...                        # Additional UI and utility files
└── Shuttler.xcodeproj/            # Xcode project file
```

## Security

- All SFTP and SCP connections use native encryption
- SSH key authentication supported for enhanced security
- Passwords are stored securely in the macOS Keychain (when implemented)
- No data is transmitted over unencrypted connections for SFTP/SCP

## Current To-Do

The following features and fixes are currently in progress:

1. **Multi-select isn't working** - Fix file selection to allow selecting multiple files at once
2. **Quick Look / Preview file isn't working** - Implement Quick Look preview for remote files
3. **Edit remote file isn't working** - Add ability to edit files directly on remote servers
4. **SCP MFA support** - The native SCP/SFTP client (NIOSSH) doesn't support keyboard-interactive authentication, which is required for MFA/Duo. However, you can enable "Use System SSH Transport" in the connection settings to use system SSH instead, which supports MFA/keyboard-interactive authentication via expect scripts. This setting is available in the connection edit form for SFTP and SCP connections.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

Copyright © 2025 Adam Newman. All rights reserved.

## Support

For issues, feature requests, or questions, please open an issue on GitHub.

---

**Version**: 1.0.5
