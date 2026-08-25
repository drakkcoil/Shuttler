//
//  RemoteBrowserViewModel.swift
//  Shuttler
//

import Foundation
import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
final class RemoteBrowserViewModel: ObservableObject {
    var connection: Connection
    private var transport: Transporting

    @Published var items: [RemoteItem] = []
    @Published var isLoading = false
    @Published private(set) var currentDirectory = RemotePath(rawValue: "/")
    @Published var directoryHistory: [RemotePath] = []
    @Published var isConnected = false
    
    @AppStorage(AppSettingsKeys.overwriteBehavior) private var overwriteBehaviorRaw: String = OverwriteBehavior.ask.rawValue
    
    private var overwriteBehavior: OverwriteBehavior {
        OverwriteBehavior(rawValue: overwriteBehaviorRaw) ?? .ask
    }

    init(connection: Connection) {
        self.connection = connection
        self.transport = TransportFactory.make(for: connection)
        // Set initial directory from connection's starting directory
        if let startingDir = connection.startingDirectory, !startingDir.isEmpty {
            self.currentDirectory = RemotePath(rawValue: startingDir)
        }
    }
    
    func updateConnection(_ newConnection: Connection) {
        let oldConnectionId = self.connection.id
        let wasConnectedBefore = isConnected
        self.connection = newConnection
        self.transport = TransportFactory.make(for: newConnection)
        
        // If the connection ID changed, check if the new connection is already connected
        if oldConnectionId != newConnection.id {
            // Check ConnectionManager to see if this connection is already connected
            let shouldBeConnected = ConnectionManager.shared.isConnected(newConnection.id)
            if shouldBeConnected {
                // ConnectionManager says this should be connected, but we have a new transport instance
                // The transport isn't actually connected, so we need to reconnect
                // Don't set isConnected = true yet - let the restore logic handle it
                isConnected = false
            } else {
                // Reset connection state when connection changes
                isConnected = false
            }
        } else {
            // Same connection ID, just update the connection details
            // Keep connection state if it was connected
            // But note: transport was recreated, so it might not actually be connected
            if wasConnectedBefore {
                // We had a connection before, but the transport is new
                // Mark as disconnected - the restore logic will reconnect if ConnectionManager says it should be
                isConnected = false
            }
        }
        
        items = []
        // Use starting directory if configured, otherwise default to "/"
        if let startingDir = newConnection.startingDirectory, !startingDir.isEmpty {
            currentDirectory = RemotePath(rawValue: startingDir)
        } else {
            currentDirectory = RemotePath(rawValue: "/")
        }
        directoryHistory = []
    }
    
    /// Restore connection state by verifying and reconnecting if needed
    func restoreConnectionIfNeeded() async {
        // Check if ConnectionManager says this connection should be connected
        let shouldBeConnected = ConnectionManager.shared.isConnected(connection.id)
        
        if shouldBeConnected && !isConnected {
            // ConnectionManager says we should be connected, but we're not
            // Try to reconnect silently (without showing progress)
            do {
                try await transport.connect()
                isConnected = true
                // Try to refresh to verify the connection works
                try await refresh()
            } catch {
                // Reconnection failed - mark as disconnected in ConnectionManager
                ConnectionManager.shared.setConnected(connection.id, isConnected: false)
                isConnected = false
            }
        } else if !shouldBeConnected && isConnected {
            // ConnectionManager says we shouldn't be connected, but we are
            // This shouldn't happen, but let's sync the state
            isConnected = false
        }
    }

    func connect(outputHandler: ((String) -> Void)? = nil) async throws {
        isLoading = true
        defer { isLoading = false }
        // #region agent log
        agentDebugLog(
            runId: "run1",
            hypothesisId: "H1",
            location: "RemoteBrowserViewModel.connect",
            message: "connect_start",
            data: [
                "connectionId": connection.id.uuidString,
                "protocol": connection.protocolType.rawValue,
                "host": connection.host,
                "port": connection.port,
                "usesKeyAuth": connection.usesKeyAuth,
                "useSystemSSHTransport": connection.useSystemSSHTransport,
                "startingDirectory": connection.startingDirectory ?? ""
            ]
        )
        // #endregion
        
        do {
            let activeTransport = transport
            try await Task.detached(priority: .userInitiated) {
                try await activeTransport.connect(outputHandler: outputHandler)
            }.value
            isConnected = true
            // Update ConnectionManager to track this connection
            ConnectionManager.shared.setConnected(connection.id, isConnected: true)
            #if os(macOS)
            if let delegate = AppDelegate.shared {
                delegate.isAnyConnectionActive = true
            }
            #endif
            
            // Validate starting directory for FTP and SFTP
            if let startingDir = connection.startingDirectory, !startingDir.isEmpty {
                var directoryExists = false
                
                // Check if directory exists based on protocol type
                if connection.protocolType == .ftp, let ftpClient = transport as? NativeFTPClient {
                    directoryExists = (try? await ftpClient.directoryExists(startingDir)) ?? false
                } else if connection.protocolType == .sftp, let sftpClient = transport as? NativeSFTPClient {
                    directoryExists = (try? await sftpClient.directoryExists(startingDir)) ?? false
                }
                
                if directoryExists {
                    currentDirectory = RemotePath(rawValue: startingDir)
                } else {
                    // Directory doesn't exist - default to "/" and show warning
                    currentDirectory = RemotePath(rawValue: "/")
                    
                    // Show warning on main thread
                    await MainActor.run {
                        #if os(macOS)
                        let alert = NSAlert()
                        alert.messageText = "Directory Not Found"
                        alert.informativeText = "The starting directory \"\(startingDir)\" does not exist on the server. Defaulting to \"/\"."
                        alert.addButton(withTitle: "OK")
                        alert.alertStyle = .warning
                        alert.runModal()
                        #endif
                    }
                }
            } else {
                currentDirectory = RemotePath(rawValue: "/")
            }
            
            // #region agent log
            agentDebugLog(
                runId: "run1",
                hypothesisId: "H1",
                location: "RemoteBrowserViewModel.connect",
                message: "connect_success",
                data: [
                    "connectionId": connection.id.uuidString,
                    "currentDirectory": currentDirectory.rawValue,
                    "isConnected": isConnected
                ]
            )
            // #endregion
            
            try await refresh()
        } catch {
            if shouldRetryWithSystemSSH(after: error) {
                outputHandler?("Native SSH transport does not support this authentication flow.")
                outputHandler?("Retrying with system SSH transport for keyboard-interactive MFA...")
                var systemConnection = connection
                systemConnection.useSystemSSHTransport = true
                connection = systemConnection
                transport = TransportFactory.make(for: systemConnection)
                try await connect(outputHandler: outputHandler)
                return
            }
            
            // #region agent log
            agentDebugLog(
                runId: "run1",
                hypothesisId: "H1",
                location: "RemoteBrowserViewModel.connect",
                message: "connect_failure",
                data: [
                    "connectionId": connection.id.uuidString,
                    "protocol": connection.protocolType.rawValue,
                    "host": connection.host,
                    "error": "\(error)"
                ]
            )
            // #endregion
            throw error
        }
    }

    private func shouldRetryWithSystemSSH(after error: Error) -> Bool {
        guard !connection.useSystemSSHTransport,
              connection.protocolType == .sftp || connection.protocolType == .scp else {
            return false
        }
        
        let message = error.localizedDescription.lowercased()
        return message.contains("keyboard-interactive") ||
            message.contains("interactive mfa") ||
            message.contains("duo") ||
            message.contains("passcode") ||
            message.contains("verification code") ||
            message.contains("permission denied") ||
            message.contains("authentication failed")
    }
    
    func disconnect() {
        isConnected = false
        items = []
        currentDirectory = RemotePath(rawValue: "/")
        directoryHistory = []
        // Update ConnectionManager to track disconnection
        ConnectionManager.shared.setConnected(connection.id, isConnected: false)
        #if os(macOS)
        // Update global state - check if any other connections are active
        if let delegate = AppDelegate.shared {
            delegate.isAnyConnectionActive = !ConnectionManager.shared.connectedConnectionIds.isEmpty
        }
        #endif
    }

    func refresh() async throws {
        isLoading = true
        defer { isLoading = false }
        // #region agent log
        agentDebugLog(
            runId: "run1",
            hypothesisId: "H2",
            location: "RemoteBrowserViewModel.refresh",
            message: "refresh_start",
            data: [
                "directory": currentDirectory.rawValue,
                "isConnected": isConnected
            ]
        )
        // #endregion
        
        do {
            items = try await transport.list(directory: currentDirectory)
            // #region agent log
            agentDebugLog(
                runId: "run1",
                hypothesisId: "H2",
                location: "RemoteBrowserViewModel.refresh",
                message: "refresh_success",
                data: [
                    "directory": currentDirectory.rawValue,
                    "itemCount": items.count
                ]
            )
            // #endregion
        } catch {
            // #region agent log
            agentDebugLog(
                runId: "run1",
                hypothesisId: "H2",
                location: "RemoteBrowserViewModel.refresh",
                message: "refresh_failure",
                data: [
                    "directory": currentDirectory.rawValue,
                    "error": "\(error)"
                ]
            )
            // #endregion
            throw error
        }
    }

    func open(_ item: RemoteItem) async throws {
        guard item.isDirectory else { return }
        isLoading = true
        defer { isLoading = false }
        directoryHistory.append(currentDirectory)
        
        // Construct full path if item.path is relative
        let fullPath: String
        if item.path.hasPrefix("/") {
            // Already absolute path
            fullPath = item.path
        } else {
            // Relative path - combine with current directory
            let currentDir = currentDirectory.rawValue
            if currentDir == "/" || currentDir.isEmpty {
                // At root, construct path as "/name"
                fullPath = "/" + item.path
            } else {
                // Normalize: ensure currentDir ends with / before appending
                let normalizedBase = currentDir.hasSuffix("/") ? currentDir : currentDir + "/"
                fullPath = normalizedBase + item.path
            }
        }
        
        // Create a temporary item with the full path for openDirectory
        let itemWithFullPath = RemoteItem(name: item.name, path: fullPath, isDirectory: item.isDirectory, size: item.size, permissions: item.permissions)
        print("🔍 RemoteBrowserViewModel.open: Navigating from '\(currentDirectory.rawValue)' to '\(fullPath)'")
        currentDirectory = try await transport.openDirectory(itemWithFullPath)
        print("✅ RemoteBrowserViewModel.open: currentDirectory is now '\(currentDirectory.rawValue)'")
        items = try await transport.list(directory: currentDirectory)
        // #region agent log
        agentDebugLog(
            runId: "run1",
            hypothesisId: "H3",
            location: "RemoteBrowserViewModel.open",
            message: "open_success",
            data: [
                "fromDirectory": directoryHistory.last?.rawValue ?? "",
                "toDirectory": currentDirectory.rawValue,
                "openedPath": fullPath,
                "itemCount": items.count
            ]
        )
        // #endregion
    }
    
    func goBack() async throws {
        guard !directoryHistory.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        currentDirectory = directoryHistory.removeLast()
        items = try await transport.list(directory: currentDirectory)
    }
    
    func navigateToPath(_ path: String) async throws {
        isLoading = true
        defer { isLoading = false }
        // Clear directory history when navigating to a specific path
        directoryHistory = []
        currentDirectory = RemotePath(rawValue: path)
        items = try await transport.list(directory: currentDirectory)
    }

    func download(_ item: RemoteItem, to destination: URL, as localName: String? = nil) async throws {
        // Start transfer tracking
        let finalName = localName?.isEmpty == false ? localName! : item.name
        let localPath = destination.appendingPathComponent(finalName).path
        let transferId = TransferManager.shared.start(name: item.name, direction: .download, totalBytes: item.size > 0 ? item.size : nil, remotePath: item.path, localPath: localPath)
        let downloadDestination: URL
        let temporaryDirectory: URL?
        if finalName == item.name {
            downloadDestination = destination
            temporaryDirectory = nil
        } else {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            downloadDestination = tempDir
            temporaryDirectory = tempDir
        }
        
        // Create a cancellable task
        let downloadTask: Task<Void, Error> = Task {
            // Capture transport reference
            let transportRef = self.transport
            
            // Progress callback
            let progressCallback: (Int64, Int64) -> Void = { bytesTransferred, totalBytes in
                // Use DispatchQueue.main.async for immediate execution on main thread
                DispatchQueue.main.async {
                    TransferManager.shared.update(id: transferId, bytesTransferred: bytesTransferred, totalBytes: totalBytes)
                }
            }
            
            // Run the actual download - pass transfer ID if transport supports cancellation
            if let cancellableTransport = transportRef as? CancellableTransport {
                try await cancellableTransport.download(item: item, to: downloadDestination, transferId: transferId, progressCallback: progressCallback)
            } else {
                try await transportRef.download(item: item, to: downloadDestination, progressCallback: progressCallback)
            }
            
            if finalName != item.name {
                let downloadedURL = downloadDestination.appendingPathComponent(item.name)
                let finalURL = destination.appendingPathComponent(finalName)
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: downloadedURL, to: finalURL)
            }
            
            // Update progress on main actor
            await MainActor.run {
                TransferManager.shared.update(id: transferId, bytesTransferred: item.size > 0 ? item.size : 1, totalBytes: item.size > 0 ? item.size : 1)
                TransferManager.shared.finish(id: transferId)
            }
        }
        
        // Register cancellation task - use transport cancellation if available
        if let cancellableTransport = self.transport as? CancellableTransport {
            TransferManager.shared.registerCancellationTask(id: transferId) {
                cancellableTransport.cancelTransfer(id: transferId)
                downloadTask.cancel()
            }
        } else {
            TransferManager.shared.registerCancellationTask(id: transferId, task: downloadTask)
        }
        
        // Wait for completion and handle errors
        do {
            try await downloadTask.value
        } catch {
            await MainActor.run {
                TransferManager.shared.finish(id: transferId, withError: error)
            }
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
            throw error
        }
        
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }
    
    func delete(_ item: RemoteItem) async throws {
        try await transport.delete(item: item)
        try await refresh()
    }
    
    /// Check if a directory is empty by listing its contents
    func isDirectoryEmpty(_ item: RemoteItem) async throws -> Bool {
        guard item.isDirectory else {
            return true // Files are not "empty"
        }
        
        // Construct the full path for the directory
        let fullPath: String
        if item.path.hasPrefix("/") {
            fullPath = item.path
        } else {
            let currentDir = currentDirectory.rawValue
            if currentDir == "/" || currentDir.isEmpty {
                fullPath = "/" + item.path
            } else {
                let normalizedBase = currentDir.hasSuffix("/") ? currentDir : currentDir + "/"
                fullPath = normalizedBase + item.path
            }
        }
        
        let directoryPath = RemotePath(rawValue: fullPath)
        let contents = try await transport.list(directory: directoryPath)
        // Filter out "." and ".." entries if present
        let filteredContents = contents.filter { $0.name != "." && $0.name != ".." }
        return filteredContents.isEmpty
    }
    
    func rename(_ item: RemoteItem, to newName: String) async throws {
        try await transport.rename(item: item, to: newName)
        try await refresh()
    }
    
    func createDirectory(name: String) async throws {
        try await transport.createDirectory(name: name, in: currentDirectory)
        try await refresh()
    }
    
    func copy(item: RemoteItem, to destination: RemotePath) async throws {
        try await transport.copy(item: item, to: destination)
        try await refresh()
    }
    
    func move(item: RemoteItem, to destination: RemotePath) async throws {
        try await transport.move(item: item, to: destination)
        try await refresh()
    }
    
    func duplicate(item: RemoteItem) async throws {
        try await transport.duplicate(item: item)
        try await refresh()
    }
    
    func changePermissions(item: RemoteItem, permissions: String) async throws {
        try await transport.changePermissions(item: item, permissions: permissions)
        try await refresh()
    }
    
    func editFile(_ item: RemoteItem) async throws -> URL {
        // Download file to temp location for editing
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempFile = tempDir.appendingPathComponent(item.name)
        // Pass nil for progress callback for edit operations
        let transportRef = self.transport
        try await transportRef.download(item: item, to: tempDir, progressCallback: nil)
        return tempFile
    }

    func upload(_ localURL: URL, withName remoteFileName: String? = nil, to directory: RemotePath? = nil) async throws {
        let fileName = remoteFileName ?? localURL.lastPathComponent
        let targetDirectory = directory ?? currentDirectory
        
        // Refresh directory listing first to ensure we have current file list
        let directoryItems: [RemoteItem]
        if targetDirectory == currentDirectory {
            try await refresh()
            directoryItems = items
        } else {
            directoryItems = try await transport.list(directory: targetDirectory)
        }
        
        // Check if file already exists
        let existingItem = directoryItems.first { $0.name == fileName && !$0.isDirectory }
        
        var finalFileName = fileName
        
        if let existing = existingItem {
            // File exists - handle according to overwrite behavior
            switch overwriteBehavior {
            case .ask:
                // Defer to UI to ask user
                throw UploadConflictError(localURL: localURL, existingItem: existing)
                
            case .overwrite:
                // Proceed with upload (will overwrite)
                finalFileName = fileName
                
            case .keepBoth:
                // Generate unique filename
                finalFileName = generateUniqueFilename(baseName: fileName, in: directoryItems)
            }
        }
        
        // Perform the actual upload
        try await performUpload(localURL: localURL, remoteFileName: finalFileName, to: targetDirectory)
        
        // Refresh directory listing
        try await refresh()
    }
    
    func uploadWithResolution(_ localURL: URL, overwrite: Bool, to directory: RemotePath? = nil) async throws {
        let targetDirectory = directory ?? currentDirectory
        // Refresh directory listing first to ensure we have current file list
        let directoryItems: [RemoteItem]
        if targetDirectory == currentDirectory {
            try await refresh()
            directoryItems = items
        } else {
            directoryItems = try await transport.list(directory: targetDirectory)
        }
        
        let fileName = localURL.lastPathComponent
        let existingItem = directoryItems.first { $0.name == fileName && !$0.isDirectory }
        
        let finalFileName: String
        if existingItem != nil {
            if overwrite {
                finalFileName = fileName
            } else {
                finalFileName = generateUniqueFilename(baseName: fileName, in: directoryItems)
            }
        } else {
            finalFileName = fileName
        }
        
        try await performUpload(localURL: localURL, remoteFileName: finalFileName, to: targetDirectory)
        try await refresh()
    }
    
    private func performUpload(localURL: URL, remoteFileName: String, to directory: RemotePath? = nil) async throws {
        let targetDirectory = directory ?? currentDirectory
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        let remotePath = targetDirectory.rawValue.hasSuffix("/") ? "\(targetDirectory.rawValue)\(remoteFileName)" : "\(targetDirectory.rawValue)/\(remoteFileName)"
        let transferId = TransferManager.shared.start(name: remoteFileName, direction: .upload, totalBytes: fileSize > 0 ? fileSize : nil, remotePath: remotePath, localPath: localURL.path)
        
        // If we need a different filename, copy to temp location with that name
        let uploadURL: URL
        let shouldCleanup: Bool
        if localURL.lastPathComponent != remoteFileName {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            uploadURL = tempDir.appendingPathComponent(remoteFileName)
            try FileManager.default.copyItem(at: localURL, to: uploadURL)
            shouldCleanup = true
        } else {
            uploadURL = localURL
            shouldCleanup = false
        }
        
        defer {
            if shouldCleanup {
                try? FileManager.default.removeItem(at: uploadURL.deletingLastPathComponent())
            }
        }
        
        // Create a cancellable task
        let uploadTask: Task<Void, Error> = Task {
            // Progress callback
            let progressCallback: (Int64, Int64) -> Void = { bytesTransferred, totalBytes in
                // Use DispatchQueue.main.async for immediate execution on main thread
                DispatchQueue.main.async {
                    TransferManager.shared.update(id: transferId, bytesTransferred: bytesTransferred, totalBytes: totalBytes)
                }
            }
            
            // Pass transfer ID if transport supports cancellation
            print("📤 RemoteBrowserViewModel: Starting upload task for transfer \(transferId.uuidString.prefix(8))")
            if let cancellableTransport = transport as? CancellableTransport {
                try await cancellableTransport.upload(localURL: uploadURL, to: targetDirectory, transferId: transferId, progressCallback: progressCallback)
            } else {
                try await transport.upload(localURL: uploadURL, to: targetDirectory, progressCallback: progressCallback)
            }
            print("✅ RemoteBrowserViewModel: Upload completed for transfer \(transferId.uuidString.prefix(8))")
            
            // The progress callback should have already reported 100% progress
            // Give a small delay to ensure UI shows 100% before marking as complete
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
            
            // Now finish the transfer
            await MainActor.run {
                print("🔄 RemoteBrowserViewModel: Calling finish() for transfer \(transferId.uuidString.prefix(8))")
                TransferManager.shared.finish(id: transferId)
            }
            print("✅ RemoteBrowserViewModel: finish() called for transfer \(transferId.uuidString.prefix(8))")
        }
        
        // Register cancellation task - use transport cancellation if available
        if let cancellableTransport = transport as? CancellableTransport {
            TransferManager.shared.registerCancellationTask(id: transferId) {
                cancellableTransport.cancelTransfer(id: transferId)
                uploadTask.cancel()
            }
        } else {
            TransferManager.shared.registerCancellationTask(id: transferId, task: uploadTask)
        }
        
        // Wait for completion and handle errors
        do {
            print("⏳ RemoteBrowserViewModel: Waiting for upload task to complete for transfer \(transferId.uuidString.prefix(8))")
            try await uploadTask.value
            print("✅ RemoteBrowserViewModel: Upload task completed successfully for transfer \(transferId.uuidString.prefix(8))")
        } catch {
            print("❌ RemoteBrowserViewModel: Upload task failed for transfer \(transferId.uuidString.prefix(8)): \(error)")
            await MainActor.run {
                TransferManager.shared.finish(id: transferId, withError: error)
            }
            throw error
        }
    }
    
    private func generateUniqueFilename(baseName: String, in items: [RemoteItem]) -> String {
        let nameWithoutExt: String
        let ext: String
        if let dotIndex = baseName.lastIndex(of: ".") {
            nameWithoutExt = String(baseName[..<dotIndex])
            ext = String(baseName[dotIndex...])
        } else {
            nameWithoutExt = baseName
            ext = ""
        }
        
        var counter = 1
        var candidate = "\(nameWithoutExt) (\(counter))\(ext)"
        
        while items.contains(where: { $0.name == candidate && !$0.isDirectory }) {
            counter += 1
            candidate = "\(nameWithoutExt) (\(counter))\(ext)"
        }
        
        return candidate
    }
    
    private func agentDebugLog(runId: String, hypothesisId: String, location: String, message: String, data: [String: Any]) {
        let logPath = "/Users/anewman/Library/CloudStorage/OneDrive-sbfoods.com/Documents/XCode Projects/Shuttler/Shuttler/.cursor/debug.log"
        let payload: [String: Any] = [
            "sessionId": "debug-session",
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        
        let newline = Data("\n".utf8)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        
        guard let handle = FileHandle(forWritingAtPath: logPath) else {
            return
        }
        
        handle.seekToEndOfFile()
        handle.write(jsonData)
        handle.write(newline)
        try? handle.close()
    }
}

// Error type for upload conflicts
struct UploadConflictError: Error {
    let localURL: URL
    let existingItem: RemoteItem
    var localizedDescription: String {
        "File '\(existingItem.name)' already exists on the server"
    }
}
