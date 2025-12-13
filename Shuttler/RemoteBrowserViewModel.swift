//
//  RemoteBrowserViewModel.swift
//  Shuttler
//

import Foundation
import Combine
import SwiftUI

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
        self.connection = newConnection
        self.transport = TransportFactory.make(for: newConnection)
        // Reset connection state when connection changes
        isConnected = false
        items = []
        // Use starting directory if configured, otherwise default to "/"
        if let startingDir = newConnection.startingDirectory, !startingDir.isEmpty {
            currentDirectory = RemotePath(rawValue: startingDir)
        } else {
            currentDirectory = RemotePath(rawValue: "/")
        }
        directoryHistory = []
    }

    func connect(outputHandler: ((String) -> Void)? = nil) async throws {
        isLoading = true
        defer { isLoading = false }
        try await transport.connect(outputHandler: outputHandler)
        isConnected = true
        #if os(macOS)
        if let delegate = AppDelegate.shared {
            delegate.isAnyConnectionActive = true
        }
        #endif
        // Ensure we're at the starting directory before refreshing
        if let startingDir = connection.startingDirectory, !startingDir.isEmpty {
            currentDirectory = RemotePath(rawValue: startingDir)
        }
        try await refresh()
    }
    
    func disconnect() {
        isConnected = false
        items = []
        currentDirectory = RemotePath(rawValue: "/")
        directoryHistory = []
        #if os(macOS)
        // Update connection state - check if any other connections are active
        updateGlobalConnectionState()
        #endif
    }
    
    #if os(macOS)
    private func updateGlobalConnectionState() {
        // This will be called to update global state when connections change
        // For now, we'll update it directly, but ideally we'd check all active connections
        // Since we only have one connection view at a time in this app, this should work
        if let delegate = AppDelegate.shared {
            delegate.isAnyConnectionActive = isConnected
        }
    }
    #endif

    func refresh() async throws {
        isLoading = true
        defer { isLoading = false }
        items = try await transport.list(directory: currentDirectory)
    }

    func open(_ item: RemoteItem) async throws {
        guard item.isDirectory else { return }
        isLoading = true
        defer { isLoading = false }
        directoryHistory.append(currentDirectory)
        currentDirectory = try await transport.openDirectory(item)
        items = try await transport.list(directory: currentDirectory)
    }
    
    func goBack() async throws {
        guard !directoryHistory.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        currentDirectory = directoryHistory.removeLast()
        items = try await transport.list(directory: currentDirectory)
    }

    func download(_ item: RemoteItem, to destination: URL) async throws {
        // Start transfer tracking
        let transferId = TransferManager.shared.start(name: item.name, direction: .download, totalBytes: item.size > 0 ? item.size : nil)
        
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
                try await cancellableTransport.download(item: item, to: destination, transferId: transferId, progressCallback: progressCallback)
            } else {
                try await transportRef.download(item: item, to: destination, progressCallback: progressCallback)
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
                TransferManager.shared.finish(id: transferId)
            }
            throw error
        }
    }
    
    func delete(_ item: RemoteItem) async throws {
        try await transport.delete(item: item)
        try await refresh()
    }
    
    func rename(_ item: RemoteItem, to newName: String) async throws {
        try await transport.rename(item: item, to: newName)
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

    func upload(_ localURL: URL, withName remoteFileName: String? = nil) async throws {
        let fileName = remoteFileName ?? localURL.lastPathComponent
        
        // Refresh directory listing first to ensure we have current file list
        try await refresh()
        
        // Check if file already exists
        let existingItem = items.first { $0.name == fileName && !$0.isDirectory }
        
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
                finalFileName = generateUniqueFilename(baseName: fileName, in: items)
            }
        }
        
        // Perform the actual upload
        try await performUpload(localURL: localURL, remoteFileName: finalFileName)
        
        // Refresh directory listing
        try await refresh()
    }
    
    func uploadWithResolution(_ localURL: URL, overwrite: Bool) async throws {
        // Refresh directory listing first to ensure we have current file list
        try await refresh()
        
        let fileName = localURL.lastPathComponent
        let existingItem = items.first { $0.name == fileName && !$0.isDirectory }
        
        let finalFileName: String
        if existingItem != nil {
            if overwrite {
                finalFileName = fileName
            } else {
                finalFileName = generateUniqueFilename(baseName: fileName, in: items)
            }
        } else {
            finalFileName = fileName
        }
        
        try await performUpload(localURL: localURL, remoteFileName: finalFileName)
        try await refresh()
    }
    
    private func performUpload(localURL: URL, remoteFileName: String) async throws {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        let transferId = TransferManager.shared.start(name: remoteFileName, direction: .upload, totalBytes: fileSize > 0 ? fileSize : nil)
        
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
                try await cancellableTransport.upload(localURL: uploadURL, to: currentDirectory, transferId: transferId, progressCallback: progressCallback)
            } else {
                try await transport.upload(localURL: uploadURL, to: currentDirectory, progressCallback: progressCallback)
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
                TransferManager.shared.finish(id: transferId)
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
}

// Error type for upload conflicts
struct UploadConflictError: Error {
    let localURL: URL
    let existingItem: RemoteItem
    var localizedDescription: String {
        "File '\(existingItem.name)' already exists on the server"
    }
}
