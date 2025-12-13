//
//  NativeSCPClient.swift
//  Shuttler
//
//  Native SCP client implementation using SwiftNIO SSH
//

import Foundation
import NIOSSH
import NIOCore
import NIOPosix

// MARK: - SCP Types

private struct SCPDownloadResult {
    let metadata: Data
    let data: Data
}

// Protocol for cancellable transfer handlers
private protocol CancellableTransferHandler: AnyObject {
    func cancel()
}

/// Native SCP client implementation using SwiftNIO SSH
final class NativeSCPClient: CancellableTransport {
    private let connection: Connection
    private let auth: SSHAuthConfig
    private var eventLoopGroup: EventLoopGroup?
    private var sshChannel: Channel?
    // Store active transfer handlers for cancellation
    private var activeTransfers: [UUID: any CancellableTransferHandler] = [:]
    private let transferLock = NSLock()
    
    // Method to cancel a transfer (called by RemoteBrowserViewModel)
    func cancelTransfer(id: UUID) {
        transferLock.lock()
        defer { transferLock.unlock() }
        if let handler = activeTransfers[id] {
            handler.cancel()
            activeTransfers.removeValue(forKey: id)
        }
    }
    
    init(connection: Connection) {
        self.connection = connection
        // Use privateKeyPath only if usesKeyAuth is true and path is provided
        let keyPath = connection.usesKeyAuth ? connection.privateKeyPath : nil
        // Trim hostname and username to prevent DNS resolution issues
        let trimmedHost = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.auth = SSHAuthConfig(host: trimmedHost, port: connection.port, username: trimmedUser, privateKeyPath: keyPath, password: connection.password)
    }
    
    deinit {
        // Cleanup will be handled by connect/disconnect pattern
    }
    
    // MARK: - Transporting Protocol
    
    func connect(outputHandler: ((String) -> Void)? = nil) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group
        
        let clientAuthDelegate = SCPClientAuthDelegate(
            username: auth.username,
            password: auth.password,
            privateKeyPath: auth.privateKeyPath
        )
        
        let serverAuthDelegate = AcceptAllHostKeysDelegate()
        
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    let ssh = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: clientAuthDelegate,
                                serverAuthDelegate: serverAuthDelegate
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try sync.addHandler(ssh)
                    return ()
                }
            }
        
        outputHandler?("Connecting to \(auth.host):\(auth.port)...")
        let channel = try await bootstrap.connect(host: auth.host, port: auth.port).get()
        self.sshChannel = channel
        
        outputHandler?("TCP connection established")
        
        // Wait for SSH handshake to complete by trying a simple operation with timeout
        // This ensures authentication completes before we proceed
        do {
            let _ = try await withTimeout(seconds: 30) {
                try await self.executeCommand(command: "echo ok", channel: channel)
            }
            outputHandler?("SSH authentication successful")
        } catch {
            try? await channel.close().get()
            throw TransferError(message: "SSH authentication failed: \(error.localizedDescription)")
        }
    }
    
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TransferError(message: "Operation timed out after \(seconds) seconds")
            }
            guard let result = try await group.next() else {
                throw TransferError(message: "Operation failed")
            }
            group.cancelAll()
            return result
        }
    }
    
    func list(directory: RemotePath) async throws -> [RemoteItem] {
        guard let channel = sshChannel else {
            throw TransferError(message: "Not connected")
        }
        
        // Normalize directory path for command
        // Use "." for current directory (when empty or "/"), otherwise use the actual path
        let dirForCommand: String
        let baseDirForParsing: String
        if directory.rawValue.isEmpty || directory.rawValue == "/" {
            dirForCommand = "."
            baseDirForParsing = "/"
        } else {
            dirForCommand = directory.rawValue
            baseDirForParsing = directory.rawValue
        }
        
        print("🔍 Executing: ls -la \(dirForCommand) in directory '\(baseDirForParsing)'")
        let escapedDir = shellEscape(dirForCommand)
        let command = "ls -la \(escapedDir)"
        let result = try await executeCommand(command: command, channel: channel)
        
        // Debug: log the raw output
        if let outputString = String(data: result, encoding: .utf8) {
            print("📋 ls output (\(outputString.count) bytes):")
            if outputString.isEmpty {
                print("   (empty)")
            } else {
                print(outputString)
            }
        }
        
        let items = parseLsLongNative(result, baseDirectory: baseDirForParsing)
        print("📁 Parsed \(items.count) items from directory '\(baseDirForParsing)'")
        return items
    }
    
    func openDirectory(_ item: RemoteItem) async throws -> RemotePath {
        RemotePath(rawValue: item.path)
    }
    
    func download(item: RemoteItem, to localURL: URL, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        try await download(item: item, to: localURL, transferId: nil, progressCallback: progressCallback)
    }
    
    func download(item: RemoteItem, to localURL: URL, transferId: UUID?, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        guard let channel = sshChannel else {
            throw TransferError(message: "Not connected")
        }
        
        // Use scp protocol over SSH channel - create new channel for this transfer (supports concurrency)
        try await nativeSCPDownload(remotePath: item.path, localURL: localURL, channel: channel, transferId: transferId, progressCallback: progressCallback)
    }
    
    func upload(localURL: URL, to directory: RemotePath, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        try await upload(localURL: localURL, to: directory, transferId: nil, progressCallback: progressCallback)
    }
    
    func upload(localURL: URL, to directory: RemotePath, transferId: UUID?, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        guard let channel = sshChannel else {
            throw TransferError(message: "Not connected")
        }
        
        // Use scp protocol over SSH channel - create new channel for this transfer (supports concurrency)
        try await nativeSCPUpload(localURL: localURL, remotePath: directory.rawValue, channel: channel, transferId: transferId, progressCallback: progressCallback)
    }
    
    func delete(item: RemoteItem) async throws {
        guard let channel = sshChannel else {
            throw TransferError(message: "Not connected")
        }
        
        let escapedPath = shellEscape(item.path)
        let command = item.isDirectory ? "rm -rf \(escapedPath)" : "rm \(escapedPath)"
        let _ = try await executeCommand(command: command, channel: channel)
    }
    
    func rename(item: RemoteItem, to newName: String) async throws {
        guard let channel = sshChannel else {
            throw TransferError(message: "Not connected")
        }
        
        let directory = (item.path as NSString).deletingLastPathComponent
        let newPath = directory.hasSuffix("/") ? "\(directory)\(newName)" : "\(directory)/\(newName)"
        let escapedOldPath = shellEscape(item.path)
        let escapedNewPath = shellEscape(newPath)
        let command = "mv \(escapedOldPath) \(escapedNewPath)"
        let _ = try await executeCommand(command: command, channel: channel)
    }
    
    // MARK: - Private Methods
    
    /// Escapes a string for safe use in shell commands by wrapping in single quotes.
    /// Handles single quotes within the string by replacing them with '\'' (end quote, escaped quote, start quote).
    private func shellEscape(_ string: String) -> String {
        // Replace single quotes with '\'' and wrap the entire string in single quotes
        let escaped = string.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
    
    private func executeCommand(command: String, channel: Channel) async throws -> Data {
        let loop = channel.eventLoop
        
        return try await withThrowingTaskGroup(of: Data.self) { group in
            // Main task: execute the command
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    // First, get the SSH handler - this will fail if handshake isn't ready
                    channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                        let dataPromise = loop.makePromise(of: Data.self)
                        let channelPromise = channel.eventLoop.makePromise(of: Channel.self)
                        
                        let handler = CommandOutputHandler(command: command, completePromise: dataPromise)
                        
                        // Create the SSH channel - this will wait for SSH handshake to complete
                        sshHandler.createChannel(channelPromise) { childChannel, channelType in
                            guard channelType == .session else {
                                return channel.eventLoop.makeFailedFuture(TransferError(message: "Invalid channel type"))
                            }
                            return childChannel.eventLoop.makeCompletedFuture {
                                let sync = childChannel.pipeline.syncOperations
                                try sync.addHandler(handler)
                            }
                        }
                        
                        // Wait for channel creation and command execution
                        return channelPromise.futureResult.flatMap { _ in
                            dataPromise.futureResult
                        }
                    }.whenComplete { result in
                        switch result {
                        case .success(let data):
                            continuation.resume(returning: data)
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
            
            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                throw TransferError(message: "Command execution timed out after 30 seconds. The SSH handshake may not have completed.")
            }
            
            // Return the first result and cancel the other
            guard let result = try await group.next() else {
                throw TransferError(message: "Command execution failed")
            }
            group.cancelAll()
            return result
        }
    }
    
    private func nativeSCPDownload(remotePath: String, localURL: URL, channel: Channel, transferId: UUID? = nil, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        // SCP download protocol: scp -f /path/to/file
        // Protocol flow:
        // 1. Execute: scp -f /path/to/file
        // 2. Send: 0 byte (ack)
        // 3. Receive: control byte (0=OK, 1=error, 2=fatal)
        // 4. Receive: metadata "C<mode> <size> <filename>\n"
        // 5. Send: 0 byte (ack)
        // 6. Receive: file data
        // 7. Send: 0 byte (ack)
        
        let escapedPath = shellEscape(remotePath)
        let command = "scp -f \(escapedPath)"
        
        let result = try await executeSCPDownload(command: command, channel: channel, transferId: transferId, progressCallback: progressCallback)
        
        // Parse metadata (format: C<mode> <size> <filename>\n)
        guard let metadataString = String(data: result.metadata, encoding: .utf8),
              metadataString.hasPrefix("C") else {
            throw TransferError(message: "Invalid SCP metadata received: \(String(data: result.metadata, encoding: .utf8) ?? "nil")")
        }
        
        let trimmedMetadata = metadataString.dropFirst().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let metadataParts = trimmedMetadata.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard metadataParts.count >= 2,
              Int64(metadataParts[1]) != nil else {
            throw TransferError(message: "Failed to parse SCP file metadata: \(metadataString)")
        }
        
        let filename = metadataParts.count > 2 ? String(metadataParts[2]) : localURL.lastPathComponent
        let destinationFile = localURL.appendingPathComponent(filename)
        
        // Ensure directory exists
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true, attributes: nil)
        
        // Write file data
        try result.data.write(to: destinationFile, options: .atomic)
        
        // Set file permissions if we got mode
        if let modeString = metadataParts.first,
           let mode = UInt16(modeString, radix: 8) {
            let attributes: [FileAttributeKey: Any] = [.posixPermissions: mode]
            try? FileManager.default.setAttributes(attributes, ofItemAtPath: destinationFile.path)
        }
    }
    
    private func nativeSCPUpload(localURL: URL, remotePath: String, channel: Channel, transferId: UUID? = nil, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        // SCP upload protocol: scp -t /path/to/dir
        // Protocol flow:
        // 1. Execute: scp -t /path/to/dir
        // 2. Receive: control byte (0=OK, 1=error, 2=fatal)
        // 3. Send: metadata "C<mode> <size> <filename>\n"
        // 4. Receive: 0 byte (ack)
        // 5. Send: file data
        // 6. Receive: 0 byte (ack)
        
        // Start accessing security-scoped resource if needed (for drag-and-drop or file picker)
        let accessing = localURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                localURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: localURL.path) else {
            throw TransferError(message: "Local file does not exist: \(localURL.path)")
        }
        
        let fileAttributes = try fileManager.attributesOfItem(atPath: localURL.path)
        let fileSize = fileAttributes[.size] as? Int64 ?? 0
        
        // Get file permissions - default to 0644 if not available
        var fileMode: UInt16 = 0o644
        if let permissions = fileAttributes[.posixPermissions] as? NSNumber {
            fileMode = permissions.uint16Value
        } else if let permissions = fileAttributes[.posixPermissions] as? UInt16 {
            fileMode = permissions
        }
        
        let filename = localURL.lastPathComponent
        
        // Ensure remote path ends with / for directory
        let remoteDir = remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
        let escapedPath = shellEscape(remoteDir)
        let command = "scp -t \(escapedPath)"
        
        // Report initial progress (0%)
        if let callback = progressCallback {
            callback(0, fileSize > 0 ? fileSize : 1)
        }
        
        // Read file data
        let fileData = try Data(contentsOf: localURL)
        
        // Format metadata: C<mode> <size> <filename>\n
        // Mode must be in octal format (e.g., 0644, 0755)
        // Use 4-digit octal format to ensure proper formatting
        let modeString = String(format: "%04o", fileMode)
        // Filename should NOT be escaped in metadata - SCP handles it
        // But we need to ensure the filename doesn't contain newlines or other control chars
        let safeFilename = filename.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        let metadata = "C\(modeString) \(fileSize) \(safeFilename)\n"
        print("📤 SCP: Formatted metadata: mode=\(modeString) (octal), size=\(fileSize), filename=\(safeFilename)")
        
        try await executeSCPUpload(command: command, channel: channel, metadata: metadata, fileData: fileData, transferId: transferId, progressCallback: progressCallback)
    }
    
    private func executeSCPDownload(command: String, channel: Channel, transferId: UUID? = nil, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws -> SCPDownloadResult {
        let loop = channel.eventLoop
        
        return try await withCheckedThrowingContinuation { continuation in
            channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let channelPromise = channel.eventLoop.makePromise(of: Channel.self)
                let resultPromise = loop.makePromise(of: SCPDownloadResult.self)
                
                let handler = SCPDownloadHandler(command: command, resultPromise: resultPromise, progressCallback: progressCallback)
                
                // Store handler for cancellation if transferId is provided
                if let id = transferId {
                    self.transferLock.lock()
                    self.activeTransfers[id] = handler
                    self.transferLock.unlock()
                    
                    // Remove from active transfers when done
                    resultPromise.futureResult.whenComplete { _ in
                        self.transferLock.lock()
                        self.activeTransfers.removeValue(forKey: id)
                        self.transferLock.unlock()
                    }
                }
                
                resultPromise.futureResult.whenComplete { result in
                    continuation.resume(with: result)
                }
                
                sshHandler.createChannel(channelPromise) { childChannel, channelType in
                    guard channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(TransferError(message: "Invalid channel type"))
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        let sync = childChannel.pipeline.syncOperations
                        try sync.addHandler(handler)
                        // Store channel reference in handler for cancellation
                        handler.setChannel(childChannel)
                    }
                }
                
                return channelPromise.futureResult.map { _ in }
            }.whenFailure { error in
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func executeSCPUpload(command: String, channel: Channel, metadata: String, fileData: Data, transferId: UUID? = nil, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        let loop = channel.eventLoop
        
        return try await withCheckedThrowingContinuation { continuation in
            channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let channelPromise = channel.eventLoop.makePromise(of: Channel.self)
                let voidPromise = loop.makePromise(of: Void.self)
                
                let handler = SCPUploadHandler(command: command, metadata: metadata, fileData: fileData, completePromise: voidPromise, progressCallback: progressCallback)
                
                // Store handler for cancellation if transferId is provided
                if let id = transferId {
                    self.transferLock.lock()
                    self.activeTransfers[id] = handler
                    self.transferLock.unlock()
                    
                    // Remove from active transfers when done
                    voidPromise.futureResult.whenComplete { _ in
                        self.transferLock.lock()
                        self.activeTransfers.removeValue(forKey: id)
                        self.transferLock.unlock()
                    }
                }
                
                voidPromise.futureResult.whenComplete { result in
                    continuation.resume(with: result)
                }
                
                sshHandler.createChannel(channelPromise) { childChannel, channelType in
                    guard channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(TransferError(message: "Invalid channel type"))
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        let sync = childChannel.pipeline.syncOperations
                        try sync.addHandler(handler)
                        // Store channel reference in handler for cancellation
                        handler.setChannel(childChannel)
                    }
                }
                
                return channelPromise.futureResult.map { _ in }
            }.whenFailure { error in
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Authentication Delegates

@preconcurrency
nonisolated private final class SCPClientAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String?
    private let privateKeyPath: String?
    private var authAttempted = false
    
    init(username: String, password: String?, privateKeyPath: String?) {
        self.username = username
        self.password = password
        self.privateKeyPath = privateKeyPath
    }
    
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // Always complete the promise, even if we can't authenticate
        defer {
            authAttempted = true
        }
        
        if authAttempted {
            // Already tried, fail
            nextChallengePromise.succeed(nil)
            return
        }
        
        // Prefer password if available, otherwise try private key
        if let password = password, availableMethods.contains(.password) {
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            )
            nextChallengePromise.succeed(offer)
        } else if let _ = privateKeyPath, availableMethods.contains(.publicKey) {
            // TODO: Load and parse private key from privateKeyPath
            // For now, fall through to fail
            nextChallengePromise.succeed(nil)
        } else {
            // No supported auth method available
            nextChallengePromise.succeed(nil)
        }
    }
}

@preconcurrency
nonisolated private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // Accept all host keys (not recommended for production, but matches SSHExec behavior)
        validationCompletePromise.succeed(())
    }
}

// MARK: - Channel Handlers

@preconcurrency
nonisolated private final class CommandOutputHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    
    private var completePromise: EventLoopPromise<Data>?
    private let command: String
    private var output = Data()
    private var isCompleted = false
    private var exitStatusReceived = false
    
    init(command: String, completePromise: EventLoopPromise<Data>) {
        self.command = command
        self.completePromise = completePromise
    }
    
    private func completePromise(with result: Result<Data, Error>) {
        guard !isCompleted, let promise = completePromise else {
            return
        }
        isCompleted = true
        completePromise = nil
        
        switch result {
        case .success(let data):
            promise.succeed(data)
        case .failure(let error):
            promise.fail(error)
        }
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        // Enable auto-read to ensure we receive all data
        let eventLoop = context.eventLoop
        context.channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { [weak self] error in
            guard let self = self else { return }
            self.completePromise(with: .failure(error))
            eventLoop.execute {
                context.fireErrorCaught(error)
            }
        }
        
        let setOption = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        setOption.whenFailure { [weak self] error in
            guard let self = self else { return }
            self.completePromise(with: .failure(error))
            eventLoop.execute {
                context.fireErrorCaught(error)
            }
        }
    }
    
    func channelActive(context: ChannelHandlerContext) {
        // Send the exec request directly - no need for pipe channel
        print("🚀 Channel active, executing command: '\(self.command)'")
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: self.command, wantReply: false)
        context.triggerUserOutboundEvent(execRequest).whenComplete { [weak self] result in
            switch result {
            case .success:
                print("✅ Exec request sent successfully")
            case .failure(let error):
                print("❌ Failed to send exec request: \(error)")
                self?.completePromise(with: .failure(TransferError(message: "Failed to execute command: \(error.localizedDescription)")))
            }
        }
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.ExitStatus {
            // Exit status received, but don't complete yet - wait for channel to close
            // The data might still be arriving
            exitStatusReceived = true
            print("✅ Exit status received, current output size: \(self.output.count) bytes, waiting for channel close...")
            // Don't complete promise here - wait for channelInactive
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        completePromise(with: .failure(error))
        context.fireErrorCaught(error)
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        // Channel closed - now safe to complete with all received data
        print("🔒 Channel inactive, final output size: \(self.output.count) bytes")
        completePromise(with: .success(self.output))
        context.fireChannelInactive()
    }
    
    func handlerRemoved(context: ChannelHandlerContext) {
        // Ensure promise is always completed when handler is removed
        if !isCompleted {
            if self.output.isEmpty {
                completePromise(with: .failure(TransferError(message: "Command execution failed: handler removed before completion")))
            } else {
                completePromise(with: .success(self.output))
            }
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        
        guard case .byteBuffer(let bytes) = channelData.data else {
            return
        }
        
        switch channelData.type {
        case .channel:
            // Accumulate stdout output - read ALL available bytes
            var buffer = bytes
            let readableBytes = buffer.readableBytes
            if readableBytes > 0 {
                // Read all available bytes from the buffer
                let newData = buffer.readBytes(length: readableBytes) ?? []
                if !newData.isEmpty {
                    self.output.append(contentsOf: newData)
                    print("📥 Received \(newData.count) bytes of stdout data (total: \(self.output.count) bytes)")
                }
            }
            // Don't forward - we're collecting it
        case .stdErr:
            // Accumulate stderr for debugging
            var buffer = bytes
            let readableBytes = buffer.readableBytes
            if readableBytes > 0 {
                if let stderrData = buffer.readBytes(length: readableBytes),
                   let stderrString = String(data: Data(stderrData), encoding: .utf8) {
                    print("⚠️ stderr: \(stderrString)")
                }
            }
        default:
            break
        }
    }
    
    func channelReadComplete(context: ChannelHandlerContext) {
        // Signal that we've processed the data and are ready for more
        // This helps with backpressure handling
        context.fireChannelReadComplete()
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // We don't expect to write to exec channels (they're command execution, not interactive)
        let data = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(data))), promise: promise)
    }
}

// Helper to parse ls -la output
private func parseLsLongNative(_ data: Data, baseDirectory: String) -> [RemoteItem] {
    guard let text = String(data: data, encoding: .utf8) else {
        print("⚠️ Failed to decode ls output as UTF-8")
        return []
    }
    
    // Check if output is actually empty (not just whitespace)
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedText.isEmpty {
        print("⚠️ ls output is empty (directory may actually be empty)")
        return []
    }
    
    var items: [RemoteItem] = []
    
    // Normalize base directory - ensure it ends with / if not empty and not already "/"
    let baseDir: String
    if baseDirectory.isEmpty || baseDirectory == "/" {
        baseDir = "/"
    } else {
        baseDir = baseDirectory.hasSuffix("/") ? baseDirectory : baseDirectory + "/"
    }
    
    var errorCount = 0
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        
        // Skip the "total N" line that appears at the start of ls -la output
        if trimmed.hasPrefix("total ") && trimmed.split(separator: " ", omittingEmptySubsequences: true).count == 2 {
            continue
        }
        
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        
        // Skip lines that don't have enough parts (must have at least: perms, links, owner, group, size, month, day, time, name)
        // Minimum is 9 parts, but some entries might have more if the name has spaces
        guard parts.count >= 9 else {
            // Only log if it's not the "total" line (which we already skip above)
            if !trimmed.hasPrefix("total ") {
                print("⚠️ Skipping line with \(parts.count) parts (expected >= 9): \(trimmed.prefix(50))")
                errorCount += 1
            }
            continue
        }
        
        let perms = String(parts[0])
        let isDir = perms.first == "d"
        // Size is always at index 4 (5th field: perms, links, owner, group, SIZE, month, day, time)
        let size = parts.count > 4 ? (Int64(parts[4]) ?? 0) : 0
        
        // Name starts at index 8 (after: perms, links, owner, group, size, month, day, time)
        // parts[0-7] are: perms, links, owner, group, size, month, day, time
        // parts[8+] is the filename (may have spaces, so join everything from index 8)
        guard parts.count > 8 else {
            print("⚠️ Line has \(parts.count) parts but need at least 9 for name field: \(trimmed.prefix(50))")
            errorCount += 1
            continue
        }
        
        let name = parts.suffix(from: 8).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Skip . and .. entries by name (these are special directory entries that shouldn't be shown)
        if name == "." || name == ".." {
            // Don't count these as errors - they're expected to be skipped
            continue
        }
        
        // Construct path relative to base directory
        let path: String
        if name.hasPrefix("/") {
            // Already absolute path
            path = name
        } else {
            // Relative path - combine with base directory
            if baseDir.isEmpty {
                path = "/\(name)"
            } else {
                path = baseDir + name
            }
        }
        
        let item = RemoteItem(name: name, path: path, isDirectory: isDir, size: size)
        items.append(item)
        
        // Debug: log large files and ubuntu file specifically
        if size > 100_000_000 {
            print("📁 Parsed large file: \(name) (\(size) bytes) -> path: \(path)")
        }
        if name.contains("ubuntu") {
            print("🔍 Parsed ubuntu file: name='\(name)', path='\(path)', size=\(size), isDir=\(isDir)")
        }
    }
    
    // Only log if there were actual parsing errors (not expected skips like . and ..)
    if errorCount > 0 {
        print("⚠️ Skipped \(errorCount) line(s) due to parsing errors")
    }
    
    return items
}

// MARK: - SCP Handlers

@preconcurrency
nonisolated private final class SCPDownloadHandler: ChannelDuplexHandler, CancellableTransferHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    
    private let command: String
    private var resultPromise: EventLoopPromise<SCPDownloadResult>?
    private var progressCallback: ((Int64, Int64) -> Void)?
    private var state: SCPDownloadState = .waitingForControlByte
    private var metadata = Data()
    private var fileData = Data() // Keep for backward compatibility, but we'll write incrementally for large files
    private var expectedFileSize: Int64 = 0
    private var bytesReceived: Int64 = 0
    private var isCompleted = false
    private var isCancelled = false
    private var fileHandle: FileHandle? // For incremental writes to disk
    private var tempFileURL: URL? // Temporary file for incremental writes
    private weak var transferChannel: Channel? // Reference to channel for cancellation
    
    init(command: String, resultPromise: EventLoopPromise<SCPDownloadResult>, progressCallback: ((Int64, Int64) -> Void)? = nil) {
        self.command = command
        self.resultPromise = resultPromise
        self.progressCallback = progressCallback
    }
    
    func setChannel(_ channel: Channel) {
        self.transferChannel = channel
    }
    
    func cancel() {
        isCancelled = true
        // Close the channel to stop data transfer
        transferChannel?.close(promise: nil)
        completePromise(with: .failure(TransferError(message: "Transfer cancelled")))
    }
    
    enum SCPDownloadState {
        case waitingForControlByte
        case receivingMetadata
        case receivingFileData
        case complete
    }
    
    private func completePromise(with result: Result<SCPDownloadResult, Error>) {
        guard !isCompleted, let promise = resultPromise else { return }
        isCompleted = true
        resultPromise = nil
        
        promise.completeWith(result)
    }
    
    private var handlerContext: ChannelHandlerContext?
    
    func handlerAdded(context: ChannelHandlerContext) {
        self.handlerContext = context
    }
    
    func handlerRemoved(context: ChannelHandlerContext) {
        self.handlerContext = nil
    }
    
    func channelActive(context: ChannelHandlerContext) {
        print("🚀 SCP download channel active, executing: '\(command)'")
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        context.triggerUserOutboundEvent(execRequest).whenComplete { [weak self] result in
            guard let self = self, let storedContext = self.handlerContext else { return }
            switch result {
            case .success:
                // For SCP -f, we must send an initial acknowledgment (0 byte) immediately
                // This tells the server we're ready to receive
                var ackBuffer = storedContext.channel.allocator.buffer(capacity: 1)
                ackBuffer.writeInteger(UInt8(0))
                storedContext.writeAndFlush(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(ackBuffer))), promise: nil)
                print("📤 SCP: Sent initial ack, waiting for control byte")
            case .failure(let error):
                self.completePromise(with: .failure(TransferError(message: "Failed to execute SCP command: \(error.localizedDescription)")))
            }
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !isCancelled else {
            return
        }
        
        let channelData = self.unwrapInboundIn(data)
        
        guard case .byteBuffer(var bytes) = channelData.data else {
            return
        }
        
        switch channelData.type {
        case .channel:
            // Handle state transitions first
            if state == .waitingForControlByte && bytes.readableBytes > 0 {
                // Read first byte to check if it's a control byte
                // Control bytes are single bytes: 0, 1, or 2
                // But metadata starts with 'C', so if we see 'C', skip to metadata state
                if let firstByte = bytes.getBytes(at: bytes.readerIndex, length: 1)?.first {
                    if firstByte == UInt8(ascii: "C") {
                        // We're receiving metadata directly, no control byte
                        // Some SCP servers don't send a control byte
                        print("📥 SCP: Received metadata directly (no control byte), switching to metadata state")
                        state = .receivingMetadata
                        // Continue processing bytes as metadata below
                    } else if firstByte == 0 || firstByte == 1 || firstByte == 2 {
                        // This is a control byte
                        _ = bytes.readBytes(length: 1) // Consume the byte
                        if firstByte == 0 {
                            // OK, send ack (0) and wait for metadata
                            var ackBuffer = context.channel.allocator.buffer(capacity: 1)
                            ackBuffer.writeInteger(UInt8(0))
                            context.writeAndFlush(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(ackBuffer))), promise: nil)
                            state = .receivingMetadata
                            print("📥 SCP: Control byte OK (0), sent ack, waiting for metadata")
                            // Continue processing any remaining bytes as metadata below
                        } else {
                            // Error or fatal error
                            let errorMsg = firstByte == 1 ? "SCP error (1)" : "SCP fatal error (2)"
                            print("❌ SCP: \(errorMsg)")
                            completePromise(with: .failure(TransferError(message: errorMsg)))
                            context.close(promise: nil)
                            return
                        }
                    } else {
                        // Unexpected byte - might be metadata starting
                        let charDesc = (firstByte >= 32 && firstByte < 127) ? String(Character(UnicodeScalar(firstByte))) : "\(firstByte)"
                        print("⚠️ SCP: Unexpected byte \(firstByte) (ASCII: \(charDesc)), treating as metadata")
                        state = .receivingMetadata
                        // Continue processing bytes as metadata below
                    }
                }
            }
            
            // Now process bytes based on current state
            switch state {
            case .waitingForControlByte:
                if bytes.readableBytes > 0 {
                    print("⏳ SCP: Still waiting for control byte, received \(bytes.readableBytes) bytes")
                }
                return
                
            case .receivingMetadata:
                // Accumulate metadata until we get newline
                if bytes.readableBytes > 0 {
                    let readBytes = bytes.readBytes(length: bytes.readableBytes) ?? []
                    metadata.append(contentsOf: readBytes)
                    
                    if let metadataString = String(data: metadata, encoding: .utf8), metadataString.contains("\n") {
                        // Parse file size from metadata
                        if metadataString.hasPrefix("C") {
                            let parts = metadataString.dropFirst().split(separator: " ", maxSplits: 2)
                            if parts.count >= 2, let size = Int64(parts[1]) {
                                expectedFileSize = size
                                bytesReceived = 0
                                
                                // For large files (>10MB), use streaming to disk instead of accumulating in memory
                                // This reduces memory usage significantly
                                if expectedFileSize > 10 * 1024 * 1024 {
                                    // Set up streaming - the handler will need the destination URL
                                    // For now, we'll still accumulate but report progress more frequently
                                    print("📥 SCP: Parsed metadata - size: \(size) bytes (large file, using incremental progress)")
                                } else {
                                    print("📥 SCP: Parsed metadata - size: \(size) bytes")
                                }
                            }
                        }
                        // Send ack and start receiving file data
                        var ackBuffer = context.channel.allocator.buffer(capacity: 1)
                        ackBuffer.writeInteger(UInt8(0))
                        context.writeAndFlush(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(ackBuffer))), promise: nil)
                        state = .receivingFileData
                        print("📥 SCP: Metadata received (\(metadata.count) bytes), sent ack, expecting \(expectedFileSize) bytes of file data")
                    } else {
                        print("📥 SCP: Accumulating metadata (\(metadata.count) bytes), no newline yet")
                    }
                }
                
            case .receivingFileData:
                // Accumulate file data incrementally
                if let data = bytes.readBytes(length: bytes.readableBytes) {
                    fileData.append(contentsOf: data)
                    bytesReceived += Int64(data.count)
                    
                    // Report progress more frequently for better UX
                    // For large files, report every 512KB or so
                    let reportThreshold = expectedFileSize > 10 * 1024 * 1024 ? 512 * 1024 : Int64.max
                    if let callback = progressCallback, expectedFileSize > 0 {
                        // Always report if we've crossed a threshold or this is the last chunk
                        let shouldReport = (bytesReceived % reportThreshold < Int64(data.count)) || 
                                          (bytesReceived >= expectedFileSize)
                        if shouldReport {
                            callback(bytesReceived, expectedFileSize)
                        }
                    }
                    
                    if expectedFileSize > 0 && bytesReceived >= expectedFileSize {
                        // Send final ack
                        var ackBuffer = context.channel.allocator.buffer(capacity: 1)
                        ackBuffer.writeInteger(UInt8(0))
                        context.writeAndFlush(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(ackBuffer))), promise: nil)
                        state = .complete
                        // Ensure final progress is reported
                        if let callback = progressCallback {
                            callback(bytesReceived, expectedFileSize)
                        }
                        print("📥 SCP: File data received (\(bytesReceived) bytes)")
                    }
                }
                
            case .complete:
                break
            }
            
        case .stdErr:
            // Log stderr for debugging - this might contain error messages
            if let stderrString = bytes.readString(length: bytes.readableBytes) {
                print("⚠️ SCP stderr: \(stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
                // If we get stderr while waiting for control byte, it might be an error
                if state == .waitingForControlByte && !stderrString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    completePromise(with: .failure(TransferError(message: "SCP error: \(stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")))
                }
            }
            
        default:
            break
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        if state == .complete || (state == .receivingFileData && fileData.count > 0) {
            let result = SCPDownloadResult(metadata: metadata, data: fileData)
            completePromise(with: .success(result))
        } else {
            completePromise(with: .failure(TransferError(message: "SCP download incomplete: state=\(state), metadata=\(metadata.count) bytes, data=\(fileData.count) bytes")))
        }
        context.fireChannelInactive()
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        completePromise(with: .failure(error))
        context.fireErrorCaught(error)
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(data))), promise: promise)
    }
}

@preconcurrency
nonisolated private final class SCPUploadHandler: ChannelDuplexHandler, CancellableTransferHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    
    private let command: String
    private let metadata: String
    private let fileData: Data
    private var completePromise: EventLoopPromise<Void>?
    private var progressCallback: ((Int64, Int64) -> Void)?
    private var state: SCPUploadState = .waitingForControlByte
    private var bytesWritten = 0
    private var bytesSent = 0 // Track bytes actually sent (for progress)
    private var isCompleted = false
    private var isCancelled = false
    private var pendingWrites = 0 // Track number of pending write operations
    private var chunkSize = 65536 // 64KB chunks for sending
    private weak var transferChannel: Channel? // Reference to channel for cancellation
    private var shouldRetrySend = false // Flag to retry sending when channel becomes writable
    private var hasReported100Percent = false // Flag to prevent overwriting 100% progress
    
    enum SCPUploadState {
        case waitingForControlByte
        case metadataSent
        case sendingFileData
        case waitingForFinalAck
        case complete
    }
    
    private var handlerContext: ChannelHandlerContext?
    
    init(command: String, metadata: String, fileData: Data, completePromise: EventLoopPromise<Void>, progressCallback: ((Int64, Int64) -> Void)? = nil) {
        self.command = command
        self.metadata = metadata
        self.fileData = fileData
        self.completePromise = completePromise
        self.progressCallback = progressCallback
    }
    
    func setChannel(_ channel: Channel) {
        self.transferChannel = channel
    }
    
    func cancel() {
        isCancelled = true
        // Close the channel to stop data transfer
        transferChannel?.close(promise: nil)
        completePromise(with: .failure(TransferError(message: "Transfer cancelled")))
    }
    
    private func completePromise(with result: Result<Void, Error>) {
        guard !isCompleted, let promise = completePromise else { return }
        isCompleted = true
        completePromise = nil
        
        switch result {
        case .success:
            promise.succeed(())
        case .failure(let error):
            promise.fail(error)
        }
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        self.handlerContext = context
        self.transferChannel = context.channel
    }
    
    func handlerRemoved(context: ChannelHandlerContext) {
        self.handlerContext = nil
    }
    
    func channelActive(context: ChannelHandlerContext) {
        print("🚀 SCP upload channel active, executing: '\(command)'")
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        context.triggerUserOutboundEvent(execRequest).whenFailure { [weak self] error in
            self?.completePromise(with: .failure(TransferError(message: "Failed to execute SCP command: \(error.localizedDescription)")))
        }
    }
    
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable && shouldRetrySend {
            shouldRetrySend = false
            sendNextChunk(context: context)
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !isCancelled else {
            return
        }
        
        let channelData = self.unwrapInboundIn(data)
        
        guard case .byteBuffer(var bytes) = channelData.data else {
            return
        }
        
        switch channelData.type {
        case .channel:
            switch state {
            case .waitingForControlByte:
                if bytes.readableBytes > 0 {
                    if let controlByte = bytes.readBytes(length: 1)?.first {
                        if controlByte == 0 {
                            // OK, send metadata
                            let metadataData = metadata.data(using: .utf8) ?? Data()
                            var metadataBuffer = context.channel.allocator.buffer(capacity: metadataData.count)
                            metadataBuffer.writeBytes(metadataData)
                            context.writeAndFlush(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(metadataBuffer))), promise: nil)
                            state = .metadataSent
                            print("📤 SCP: Control byte OK, sent metadata (\(metadataData.count) bytes): \(String(data: metadataData, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? "nil")")
                        } else {
                            let errorMsg = controlByte == 1 ? "SCP error (1)" : "SCP fatal error (2)"
                            print("❌ SCP upload: \(errorMsg)")
                            completePromise(with: .failure(TransferError(message: errorMsg)))
                        }
                    }
                } else {
                    print("⏳ SCP upload: Waiting for control byte, received \(bytes.readableBytes) bytes")
                }
                
            case .metadataSent:
                // Received ack for metadata, now send file data in chunks
                if bytes.readableBytes > 0 {
                    if let ackByte = bytes.readBytes(length: 1)?.first {
                        if ackByte == 0 {
                            // Report initial progress (5% - metadata sent)
                            if let callback = progressCallback {
                                callback(Int64(Double(fileData.count) * 0.05), Int64(fileData.count))
                            }
                            
                            // Start sending file data in chunks
                            state = .sendingFileData
                            print("📤 SCP: Metadata ack received (0), sending \(fileData.count) bytes of file data in chunks")
                            sendNextChunk(context: context)
                        } else {
                            // Server rejected metadata - ack byte 1 = error, 2 = fatal error
                            let errorMsg = ackByte == 1 ? "SCP error: Server rejected metadata (check directory permissions and filename)" : "SCP fatal error: Server rejected metadata"
                            print("❌ SCP upload: \(errorMsg)")
                            completePromise(with: .failure(TransferError(message: errorMsg)))
                            context.close(promise: nil)
                            return
                        }
                    }
                } else {
                    print("⏳ SCP upload: Waiting for metadata ack, received \(bytes.readableBytes) bytes")
                }
                
            case .sendingFileData:
                // Still sending chunks - this shouldn't happen, but handle gracefully
                // The write callbacks handle chunk progression
                break
                
            case .waitingForFinalAck:
                // Received final ack after all data sent
                if bytes.readableBytes > 0 {
                    if let ackByte = bytes.readBytes(length: 1)?.first {
                        if ackByte == 0 {
                            // Report 100% progress - upload complete
                            // Only report if we haven't already reported 100%
                            if let callback = progressCallback, !hasReported100Percent {
                                print("📊 SCP: Reporting 100% progress on final ack (\(fileData.count)/\(fileData.count) bytes)")
                                hasReported100Percent = true
                                callback(Int64(fileData.count), Int64(fileData.count))
                                print("✅ SCP: 100% progress callback invoked on final ack")
                            } else if hasReported100Percent {
                                print("⚠️ SCP: Already reported 100% on final ack, skipping")
                            }
                            state = .complete
                            bytesWritten = fileData.count
                            print("📤 SCP: File upload complete (\(bytesWritten) bytes), received final ack")
                            completePromise(with: .success(()))
                        } else {
                            print("⚠️ SCP upload: Unexpected final ack byte: \(ackByte) (expected 0)")
                        }
                    }
                } else {
                    print("⏳ SCP upload: Waiting for final ack, received \(bytes.readableBytes) bytes")
                }
                
            case .complete:
                // Already complete, ignore any additional data
                break
            }
            
        case .stdErr:
            if let stderrString = bytes.readString(length: bytes.readableBytes) {
                let trimmed = stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    print("⚠️ SCP upload stderr: \(trimmed)")
                    // If we get stderr, it might be an error
                    if state != .complete {
                        completePromise(with: .failure(TransferError(message: "SCP upload error: \(trimmed)")))
                    }
                }
            }
            
        default:
            break
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        print("🔒 SCP upload channel inactive, state=\(state), bytesWritten=\(bytesWritten), bytesSent=\(bytesSent), pendingWrites=\(pendingWrites)")
        if state == .complete {
            completePromise(with: .success(()))
        } else if state == .waitingForFinalAck && bytesSent == fileData.count {
            // All data was sent, but we didn't receive final ack - still consider it success
            // (server may have closed connection after receiving data)
            print("⚠️ SCP upload: Channel closed after all data sent, treating as success")
            // Report 100% progress since upload completed successfully
            // Only report if we haven't already reported 100%
            if let callback = progressCallback, !hasReported100Percent {
                print("📊 SCP: Reporting 100% progress on channel close (\(fileData.count)/\(fileData.count) bytes)")
                hasReported100Percent = true
                callback(Int64(fileData.count), Int64(fileData.count))
                print("✅ SCP: 100% progress callback invoked on channel close")
            } else if hasReported100Percent {
                print("⚠️ SCP: Already reported 100% on channel close, skipping")
            }
            completePromise(with: .success(()))
        } else {
            let errorMsg = "SCP upload incomplete: state=\(state), bytesSent=\(bytesSent)/\(fileData.count), pendingWrites=\(pendingWrites)"
            print("❌ SCP upload failed: \(errorMsg)")
            completePromise(with: .failure(TransferError(message: errorMsg)))
        }
        context.fireChannelInactive()
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        completePromise(with: .failure(error))
        context.fireErrorCaught(error)
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(data))), promise: promise)
    }
    
    private func sendNextChunk(context: ChannelHandlerContext) {
        guard !isCancelled else {
            print("🚫 SCP: Upload cancelled, stopping chunk sends")
            return
        }
        guard state == .sendingFileData else { 
            print("⚠️ SCP: sendNextChunk called but state is \(state)")
            return 
        }
        guard bytesSent < fileData.count else {
            // All data sent, now wait for final ack
            state = .waitingForFinalAck
            print("📤 SCP: All \(bytesSent) bytes sent, waiting for final ack")
            // Report 100% progress since all data has been successfully sent
            // Only report if we haven't already reported 100% (to prevent race conditions)
            if let callback = progressCallback, !hasReported100Percent {
                print("📊 SCP: Reporting 100% progress (\(fileData.count)/\(fileData.count) bytes)")
                hasReported100Percent = true
                callback(Int64(fileData.count), Int64(fileData.count))
                print("✅ SCP: 100% progress callback invoked")
            } else if hasReported100Percent {
                print("⚠️ SCP: Already reported 100%, skipping duplicate update")
            } else {
                print("⚠️ SCP: No progress callback available to report 100%")
            }
            
            // Set a timeout to complete the upload if final ack doesn't arrive
            // Some servers close the connection without sending final ack
            if let storedContext = handlerContext {
                let eventLoop = storedContext.eventLoop
                eventLoop.scheduleTask(in: .seconds(2)) { [weak self] in
                    guard let self = self else { return }
                    // Check if we're still waiting and all data was sent
                    if self.state == .waitingForFinalAck && self.bytesSent == self.fileData.count && !self.isCompleted {
                        print("⏰ SCP: Timeout waiting for final ack, completing upload (all data sent)")
                        self.state = .complete
                        self.completePromise(with: .success(()))
                    }
                }
            }
            return
        }
        
        // Check if channel is writable before sending
        guard context.channel.isWritable else {
            print("⏸️ SCP: Channel not writable, deferring chunk send")
            // Set flag to retry when channel becomes writable
            shouldRetrySend = true
            return
        }
        
        // Calculate chunk size
        let remaining = fileData.count - bytesSent
        let currentChunkSize = min(chunkSize, remaining)
        
        // Create buffer with chunk data
        let startIndex = fileData.startIndex.advanced(by: bytesSent)
        let endIndex = startIndex.advanced(by: currentChunkSize)
        let chunkData = fileData[startIndex..<endIndex]
        
        var dataBuffer = context.channel.allocator.buffer(capacity: currentChunkSize)
        dataBuffer.writeBytes(chunkData)
        
        // Track this write
        pendingWrites += 1
        
        // Send chunk and track progress when write completes
        let writePromise = context.eventLoop.makePromise(of: Void.self)
        writePromise.futureResult.whenComplete { [weak self] result in
            guard let self = self else { return }
            self.pendingWrites -= 1
            
            switch result {
            case .success:
                self.bytesSent += currentChunkSize
                let percent = Int(Double(self.bytesSent) / Double(self.fileData.count) * 100)
                print("✅ SCP: Chunk sent successfully, progress: \(self.bytesSent)/\(self.fileData.count) (\(percent)%)")
                
                // Check if all bytes are now sent
                let allBytesSent = self.bytesSent >= self.fileData.count
                
                // Report progress based on bytes actually sent
                // Only report if we haven't already reported 100% (to prevent race conditions)
                if let callback = self.progressCallback, !self.hasReported100Percent {
                    if allBytesSent {
                        // All bytes sent - report 100% immediately and set flag
                        print("📊 SCP: All bytes sent in chunk completion, reporting 100% (\(self.fileData.count)/\(self.fileData.count))")
                        self.hasReported100Percent = true
                        callback(Int64(self.fileData.count), Int64(self.fileData.count))
                        print("✅ SCP: 100% progress reported, flag set to prevent overwrites")
                    } else {
                        // Report progress based on bytes sent, but cap at 99% to leave room for final 100%
                        let progress = Double(self.bytesSent) / Double(self.fileData.count)
                        // Scale to 5%-99% (instead of 5%-95%) to get closer to 100% before completion
                        let adjustedProgress = 0.05 + (progress * 0.94) // Scale to 5%-99%
                        let adjustedBytes = Int64(Double(self.fileData.count) * adjustedProgress)
                        callback(adjustedBytes, Int64(self.fileData.count))
                    }
                } else if self.hasReported100Percent {
                    print("⚠️ SCP: Skipping progress update - already reported 100%")
                }
                
                // Continue sending next chunk (or transition to waiting for final ack)
                // Use stored context reference to avoid capturing in closure
                if let storedContext = self.handlerContext {
                    storedContext.eventLoop.execute {
                        self.sendNextChunk(context: storedContext)
                    }
                }
                
            case .failure(let error):
                print("❌ SCP upload: Write failed: \(error)")
                self.completePromise(with: .failure(error))
            }
        }
        
        // Always flush to ensure data is actually sent and progress is tracked accurately
        // For very large files, buffering without flushing can cause the transfer to appear stuck
        print("📤 SCP: Sending chunk (will be \(bytesSent / chunkSize + 1)), size: \(currentChunkSize) bytes, progress: \(Int64(bytesSent))/\(fileData.count) (\(Int(Double(bytesSent) / Double(fileData.count) * 100))%)")
        context.writeAndFlush(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(dataBuffer))), promise: writePromise)
    }
}

// MARK: - Glue Handler (simplified version for connecting channels)

@preconcurrency
private final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny
    
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead: Bool = false
    
    private init() {}
    
    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable {
            self.partner?.partnerBecameWritable()
        }
    }
    
    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.partner?.partnerWrite(data)
    }
    
    func channelReadComplete(context: ChannelHandlerContext) {
        self.partner?.partnerFlush()
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        self.partner?.partnerCloseFull()
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            self.partner?.partnerWriteEOF()
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.partner?.partnerCloseFull()
    }
    
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            self.partner?.partnerBecameWritable()
        }
    }
    
    func read(context: ChannelHandlerContext) {
        if let partner = self.partner, partner.partnerWritable {
            context.read()
        } else {
            self.pendingRead = true
        }
    }
    
    private func partnerWrite(_ data: NIOAny) {
        self.context?.write(data, promise: nil)
    }
    
    private func partnerFlush() {
        self.context?.flush()
    }
    
    private func partnerWriteEOF() {
        self.context?.close(mode: .output, promise: nil)
    }
    
    private func partnerCloseFull() {
        self.context?.close(promise: nil)
    }
    
    private func partnerBecameWritable() {
        if self.pendingRead {
            self.pendingRead = false
            self.context?.read()
        }
    }
    
    private var partnerWritable: Bool {
        self.context?.channel.isWritable ?? false
    }
}

private func createGlueHandlerPair() -> (GlueHandler, GlueHandler) {
    return GlueHandler.matchedPair()
}
