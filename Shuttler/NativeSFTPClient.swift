//
//  NativeSFTPClient.swift
//  Shuttler
//
//  Native SFTP client implementation using SwiftNIO SSH
//

import Foundation
import NIOSSH
import NIOCore
import NIOPosix

nonisolated private enum SFTPProtocol {
    static let initialize: UInt8 = 1
    static let version: UInt8 = 2
    static let open: UInt8 = 3
    static let close: UInt8 = 4
    static let read: UInt8 = 5
    static let write: UInt8 = 6
    static let setstat: UInt8 = 9
    static let opendir: UInt8 = 11
    static let readdir: UInt8 = 12
    static let remove: UInt8 = 13
    static let mkdir: UInt8 = 14
    static let rmdir: UInt8 = 15
    static let stat: UInt8 = 17
    static let rename: UInt8 = 18
    static let status: UInt8 = 101
    static let handle: UInt8 = 102
    static let data: UInt8 = 103
    static let name: UInt8 = 104
    static let attrs: UInt8 = 105
    
    static func packet(
        allocator: ByteBufferAllocator,
        type: UInt8,
        capacity: Int = 0,
        body: ((inout ByteBuffer) -> Void)? = nil
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: capacity + 1)
        payload.writeInteger(type)
        body?(&payload)
        
        var packet = allocator.buffer(capacity: payload.readableBytes + 4)
        packet.writeInteger(UInt32(payload.readableBytes), endianness: .big)
        packet.writeBuffer(&payload)
        return packet
    }
    
    static func writeString(_ value: String, to buffer: inout ByteBuffer) {
        let bytes = Array(value.utf8)
        buffer.writeInteger(UInt32(bytes.count), endianness: .big)
        buffer.writeBytes(bytes)
    }
    
    static func writeData(_ data: Data, to buffer: inout ByteBuffer) {
        buffer.writeInteger(UInt32(data.count), endianness: .big)
        buffer.writeBytes(data)
    }
    
    static func readString(from buffer: inout ByteBuffer) -> String? {
        guard let length = buffer.readInteger(as: UInt32.self),
              Int(length) <= buffer.readableBytes else {
            return nil
        }
        return buffer.readString(length: Int(length))
    }
    
    static func extractPacketPayloads(
        from bytes: ByteBuffer,
        accumulator: inout ByteBuffer?,
        allocator: ByteBufferAllocator
    ) -> [ByteBuffer] {
        var incoming = bytes
        var buffer = accumulator ?? allocator.buffer(capacity: bytes.readableBytes)
        buffer.writeBuffer(&incoming)
        
        var payloads: [ByteBuffer] = []
        while buffer.readableBytes >= 4 {
            guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else {
                break
            }
            let packetLength = Int(length)
            guard buffer.readableBytes >= packetLength + 4 else {
                break
            }
            
            buffer.moveReaderIndex(forwardBy: 4)
            if let payload = buffer.readSlice(length: packetLength) {
                payloads.append(payload)
            }
        }
        
        accumulator = buffer.readableBytes > 0 ? buffer : nil
        return payloads
    }
}

/// Native SFTP client implementation using SwiftNIO SSH
final class NativeSFTPClient: CancellableTransport {
    private let connection: Connection
    private let auth: SSHAuthConfig
    private var eventLoopGroup: EventLoopGroup?
    private var sshChannel: Channel?
    private var sftpChannel: Channel?
    private var sftpRequestId: UInt32 = 0
    private let sftpRequestIdLock = NSLock()
    // Store active transfer handlers for cancellation
    private var activeTransfers: [UUID: any CancellableTransferHandler] = [:]
    private let transferLock = NSLock()
    
    // Method to cancel a transfer (called by RemoteBrowserViewModel)
    func cancelTransfer(id: UUID) {
        transferLock.withLock {
            if let handler = activeTransfers[id] {
                handler.cancel()
                activeTransfers.removeValue(forKey: id)
            }
        }
    }
    
    init(connection: Connection) {
        self.connection = connection
        // Use privateKeyPath only if usesKeyAuth is true and path is provided
        let keyPath = connection.usesKeyAuth ? connection.privateKeyPath : nil
        // Trim hostname and username to prevent DNS resolution issues
        let trimmedHost = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.auth = SSHAuthConfig(host: trimmedHost, port: connection.port, username: trimmedUser, privateKeyPath: keyPath, password: connection.getPassword())
    }
    
    deinit {
        // Cleanup will be handled by connect/disconnect pattern
    }
    
    // MARK: - Transporting Protocol
    
    func connect(outputHandler: ((String) -> Void)? = nil) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group
        
        let clientAuthDelegate = SFTPClientAuthDelegate(
            username: auth.username,
            password: auth.password,
            privateKeyPath: auth.privateKeyPath
        )
        
        let serverAuthDelegate = AcceptAllHostKeysDelegate()
        
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(10))
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
        do {
            let channel = try await bootstrap.connect(host: auth.host, port: auth.port).get()
            self.sshChannel = channel
            
            outputHandler?("TCP connection established")
        
            // Wait for SSH handshake to complete
            do {
                let _ = try await withTimeout(seconds: 30) {
                    try await self.executeCommand(command: "echo ok", channel: channel)
                }
                outputHandler?("SSH authentication successful")
            } catch {
                // Detect interactive MFA/keyboard-interactive requirement
                let msg = error.localizedDescription.lowercased()
                if msg.contains("keyboard-interactive") || msg.contains("duo") || msg.contains("passcode") || msg.contains("verification code") || msg.contains("interactive authentication required") {
                    throw TransferError(message: "This server requires interactive MFA (keyboard-interactive authentication, e.g., Cisco Duo). Native SFTP does not support interactive authentication. Please enable 'Use system SSH transport' in your connection settings or switch to SFTP with system SSH.\nOriginal error: \(error.localizedDescription)")
                }
                try? await channel.close().get()
                throw TransferError(message: "SSH authentication failed: \(error.localizedDescription)")
            }
            
            // Initialize SFTP subsystem
            outputHandler?("Initializing SFTP subsystem...")
            try await withTimeout(seconds: 30) {
                try await self.initializeSFTP(channel: channel)
            }
            outputHandler?("SFTP subsystem ready")
        } catch {
            // Convert NIO errors to user-friendly messages
            let errorMsg: String
            if let nioError = error as? NIOConnectionError {
                let errorStr = String(describing: nioError)
                // Parse the error string to extract useful information
                if errorStr.contains("No route to host") || errorStr.contains("errno: 65") {
                    errorMsg = "No route to host. The server at \(auth.host):\(auth.port) is not reachable. This usually means:\n• The server is on a private network that requires VPN access\n• A firewall is blocking the connection\n• The server is not currently available\n\nPlease check your network connection and VPN status."
                } else if errorStr.contains("Connection refused") || errorStr.contains("errno: 61") {
                    errorMsg = "Connection refused by server at \(auth.host):\(auth.port). The server is reachable but not accepting connections. Please check if the SSH service is running."
                } else if errorStr.contains("Connection timed out") || errorStr.contains("errno: 60") {
                    errorMsg = "Connection timed out while connecting to \(auth.host):\(auth.port). The server did not respond. Please check your network connection and firewall settings."
                } else if errorStr.contains("dns") || errorStr.contains("DNS") {
                    errorMsg = "DNS lookup failed for host: \(auth.host). Please check the hostname and your network connection."
                } else {
                    errorMsg = "Connection failed: \(nioError.localizedDescription). Please check the host (\(auth.host)) and port (\(auth.port))."
                }
            } else {
                errorMsg = error.localizedDescription
            }
            // Detect interactive MFA/keyboard-interactive requirement in general errors
            let lowercaseMsg = errorMsg.lowercased()
            if lowercaseMsg.contains("keyboard-interactive") || lowercaseMsg.contains("duo") || lowercaseMsg.contains("passcode") || lowercaseMsg.contains("verification code") || lowercaseMsg.contains("interactive authentication required") {
                throw TransferError(message: "This server requires interactive MFA (keyboard-interactive authentication, e.g., Cisco Duo). Native SFTP does not support interactive authentication. Please enable 'Use system SSH transport' in your connection settings or switch to SFTP with system SSH.\nOriginal error: \(errorMsg)")
            }
            throw TransferError(message: "SFTP connection failed: \(errorMsg)")
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
    
    private func initializeSFTP(channel: Channel) async throws {
        let loop = channel.eventLoop
        
        return try await withCheckedThrowingContinuation { continuation in
            channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let channelPromise = channel.eventLoop.makePromise(of: Channel.self)
                let initPromise = loop.makePromise(of: Void.self)
                
                let handler = SFTPInitHandler(initPromise: initPromise)
                
                sshHandler.createChannel(channelPromise) { childChannel, channelType in
                    guard channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(TransferError(message: "Invalid channel type"))
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        let sync = childChannel.pipeline.syncOperations
                        try sync.addHandler(handler)
                        
                        // Request SFTP subsystem
                        let subsystemRequest = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
                        childChannel.triggerUserOutboundEvent(subsystemRequest).whenComplete { result in
                            switch result {
                            case .success:
                                handler.sendInit()
                            case .failure(let error):
                                initPromise.fail(error)
                            }
                        }
                    }
                }
                
                initPromise.futureResult.whenComplete { result in
                    continuation.resume(with: result)
                }
                
                return channelPromise.futureResult.map { sftpChannel in
                    self.sftpChannel = sftpChannel
                }
            }.whenFailure { error in
                continuation.resume(throwing: error)
            }
        }
    }
    
    func list(directory: RemotePath) async throws -> [RemoteItem] {
        guard let sftpChannel = sftpChannel else {
            throw TransferError(message: "SFTP not initialized")
        }
        
        let dir = directory.rawValue.isEmpty ? "/" : directory.rawValue
        return try await sftpListDirectory(path: dir, channel: sftpChannel)
    }
    
    func openDirectory(_ item: RemoteItem) async throws -> RemotePath {
        RemotePath(rawValue: item.path)
    }
    
    func directoryExists(_ path: String) async throws -> Bool {
        guard let sftpChannel = sftpChannel else {
            throw TransferError(message: "SFTP not initialized")
        }
        
        let normalizedPath = path.isEmpty ? "/" : path
        do {
            let (_, isDirectory) = try await sftpStat(path: normalizedPath, requestId: nextRequestId(), channel: sftpChannel)
            return isDirectory
        } catch {
            // If stat fails, directory doesn't exist
            return false
        }
    }
    
    func download(item: RemoteItem, to localURL: URL, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        try await download(item: item, to: localURL, transferId: nil, progressCallback: progressCallback)
    }
    
    func download(item: RemoteItem, to localURL: URL, transferId: UUID?, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        guard let sftpChannel = sftpChannel else {
            throw TransferError(message: "SFTP not initialized")
        }
        
        try await sftpDownload(remotePath: item.path, localURL: localURL, channel: sftpChannel, transferId: transferId, progressCallback: progressCallback)
    }
    
    func upload(localURL: URL, to directory: RemotePath, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        try await upload(localURL: localURL, to: directory, transferId: nil, progressCallback: progressCallback)
    }
    
    func upload(localURL: URL, to directory: RemotePath, transferId: UUID?, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        guard let sftpChannel = sftpChannel else {
            throw TransferError(message: "SFTP not initialized")
        }
        
        let fileName = localURL.lastPathComponent
        let remotePath = directory.rawValue.hasSuffix("/") ? "\(directory.rawValue)\(fileName)" : "\(directory.rawValue)/\(fileName)"
        
        try await sftpUpload(localURL: localURL, remotePath: remotePath, channel: sftpChannel, transferId: transferId, progressCallback: progressCallback)
    }
    
    func delete(item: RemoteItem) async throws {
        guard let sftpChannel = sftpChannel else {
            throw TransferError(message: "SFTP not initialized")
        }
        
        try await sftpDelete(path: item.path, isDirectory: item.isDirectory, channel: sftpChannel)
    }
    
    func rename(item: RemoteItem, to newName: String) async throws {
        guard let sftpChannel = sftpChannel else {
            throw TransferError(message: "SFTP not initialized")
        }
        
        let directory = (item.path as NSString).deletingLastPathComponent
        let newPath = directory.hasSuffix("/") ? "\(directory)\(newName)" : "\(directory)/\(newName)"
        
        try await sftpRename(oldPath: item.path, newPath: newPath, channel: sftpChannel)
    }
    
    func createDirectory(name: String, in directory: RemotePath) async throws {
        guard let sftpChannel = sftpChannel else {
            throw TransferError(message: "SFTP not initialized")
        }
        
        let baseDir = directory.rawValue
        let newPath = baseDir.hasSuffix("/") ? "\(baseDir)\(name)" : "\(baseDir)/\(name)"
        
        try await sftpMkdir(path: newPath, channel: sftpChannel)
    }
    
    func copy(item: RemoteItem, to destination: RemotePath) async throws {
        guard sftpChannel != nil else {
            throw TransferError(message: "SFTP not initialized")
        }
        
        // Use SFTP copy (if supported) or download/upload
        // For now, use download/upload for reliability
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        try await download(item: item, to: tempDir)
        let localFile = tempDir.appendingPathComponent(item.name)
        try await upload(localURL: localFile, to: destination)
    }
    
    func move(item: RemoteItem, to destination: RemotePath) async throws {
        guard let sftpChannel = sftpChannel else {
            throw TransferError(message: "SFTP not initialized")
        }
        
        // Use SFTP rename for move (more efficient than copy+delete)
        let destinationPath = destination.rawValue.hasSuffix("/") 
            ? "\(destination.rawValue)\(item.name)" 
            : "\(destination.rawValue)/\(item.name)"
        try await sftpRename(oldPath: item.path, newPath: destinationPath, channel: sftpChannel)
    }
    
    func duplicate(item: RemoteItem) async throws {
        guard sftpChannel != nil else {
            throw TransferError(message: "SFTP not initialized")
        }
        
        // Find a unique name in the same directory
        let directory = RemotePath(rawValue: (item.path as NSString).deletingLastPathComponent)
        let items = try await list(directory: directory)
        let baseName = (item.name as NSString).deletingPathExtension
        let ext = (item.name as NSString).pathExtension
        var counter = 1
        var finalName: String
        repeat {
            if !ext.isEmpty {
                finalName = "\(baseName) copy \(counter).\(ext)"
            } else {
                finalName = "\(baseName) copy \(counter)"
            }
            counter += 1
        } while items.contains(where: { $0.name == finalName })
        
        // Copy to same directory with new name by copying to a temp path then renaming
        // First, copy to a temporary name
        let tempName = "\(item.name).tmp.\(UUID().uuidString.prefix(8))"
        let tempPath = directory.rawValue.hasSuffix("/") 
            ? "\(directory.rawValue)\(tempName)" 
            : "\(directory.rawValue)/\(tempName)"
        let tempItem = RemoteItem(name: tempName, path: tempPath, isDirectory: item.isDirectory, size: item.size, permissions: item.permissions)
        
        // Copy to temp location
        try await copy(item: item, to: RemotePath(rawValue: tempPath))
        
        // Rename temp to final name
        try await rename(item: tempItem, to: finalName)
    }
    
    func changePermissions(item: RemoteItem, permissions: String) async throws {
        guard let sftpChannel = sftpChannel else {
            throw TransferError(message: "SFTP not initialized")
        }
        
        // Convert permissions string to UInt32 (supports both octal "755" and symbolic "rwxr-xr-x")
        let perms: UInt32
        if let octal = UInt32(permissions, radix: 8) {
            perms = octal
        } else {
            // Parse symbolic format (e.g., "rwxr-xr-x")
            throw TransferError(message: "Only octal permissions (e.g., '755') are currently supported")
        }
        
        try await sftpSetPermissions(path: item.path, permissions: perms, channel: sftpChannel)
    }
    
    // MARK: - Private Methods
    
    private func executeCommand(command: String, channel: Channel) async throws -> Data {
        let loop = channel.eventLoop
        
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                        let dataPromise = loop.makePromise(of: Data.self)
                        let channelPromise = channel.eventLoop.makePromise(of: Channel.self)
                        
                        let handler = CommandOutputHandler(command: command, completePromise: dataPromise)
                        
                        sshHandler.createChannel(channelPromise) { childChannel, channelType in
                            guard channelType == .session else {
                                return channel.eventLoop.makeFailedFuture(TransferError(message: "Invalid channel type"))
                            }
                            return childChannel.eventLoop.makeCompletedFuture {
                                let sync = childChannel.pipeline.syncOperations
                                try sync.addHandler(handler)
                            }
                        }
                        
                        return channelPromise.futureResult.flatMap { _ in
                            dataPromise.futureResult
                        }
                    }.whenComplete { result in
                        continuation.resume(with: result)
                    }
                }
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw TransferError(message: "Command execution timed out")
            }
            
            guard let result = try await group.next() else {
                throw TransferError(message: "Command execution failed")
            }
            group.cancelAll()
            return result
        }
    }
    
    private func nextRequestId() -> UInt32 {
        return sftpRequestIdLock.withLock {
            sftpRequestId += 1
            return sftpRequestId
        }
    }
    
    private func readStatusCode(from buffer: inout ByteBuffer, requestId: UInt32) throws -> UInt32 {
        guard let responseRequestId = buffer.readInteger(as: UInt32.self) else {
            throw TransferError(message: "Invalid SFTP status response")
        }
        guard responseRequestId == requestId else {
            throw TransferError(message: "Request ID mismatch")
        }
        guard let statusCode = buffer.readInteger(as: UInt32.self) else {
            throw TransferError(message: "Invalid SFTP status code")
        }
        return statusCode
    }
    
    private func sftpStatusMessage(from buffer: inout ByteBuffer) -> String {
        SFTPProtocol.readString(from: &buffer) ?? "Unknown error"
    }
    
    private func validateOKStatus(from buffer: inout ByteBuffer, requestId: UInt32) throws {
        let statusCode = try readStatusCode(from: &buffer, requestId: requestId)
        guard statusCode == 0 else {
            throw TransferError(message: "SFTP error: \(sftpStatusMessage(from: &buffer)) (code: \(statusCode))")
        }
    }
    
    private func readAttributes(from buffer: inout ByteBuffer) -> (size: UInt64, isDirectory: Bool, permissions: String?) {
        guard let flags = buffer.readInteger(as: UInt32.self) else {
            return (0, false, nil)
        }
        
        var size: UInt64 = 0
        var permissionsValue: UInt32?
        
        if (flags & 0x00000001) != 0 { // SSH_FILEXFER_ATTR_SIZE
            size = buffer.readInteger(as: UInt64.self) ?? 0
        }
        if (flags & 0x00000002) != 0 { // SSH_FILEXFER_ATTR_UIDGID
            _ = buffer.readInteger(as: UInt32.self) // UID
            _ = buffer.readInteger(as: UInt32.self) // GID
        }
        if (flags & 0x00000004) != 0 { // SSH_FILEXFER_ATTR_PERMISSIONS
            permissionsValue = buffer.readInteger(as: UInt32.self)
        }
        if (flags & 0x00000008) != 0 { // SSH_FILEXFER_ATTR_ACMODTIME
            _ = buffer.readInteger(as: UInt32.self) // atime
            _ = buffer.readInteger(as: UInt32.self) // mtime
        }
        if (flags & 0x80000000) != 0 { // SSH_FILEXFER_ATTR_EXTENDED
            let extendedCount = buffer.readInteger(as: UInt32.self) ?? 0
            for _ in 0..<extendedCount {
                if let typeLength = buffer.readInteger(as: UInt32.self) {
                    _ = buffer.readBytes(length: Int(typeLength))
                }
                if let dataLength = buffer.readInteger(as: UInt32.self) {
                    _ = buffer.readBytes(length: Int(dataLength))
                }
            }
        }
        
        let isDirectory = permissionsValue.map { ($0 & 0o170000) == 0o040000 } ?? false
        let permissions = permissionsValue.map { String(format: "%03o", $0 & 0o777) }
        return (size, isDirectory, permissions)
    }
    
    // MARK: - SFTP Protocol Implementation
    
    private func sftpListDirectory(path: String, channel: Channel) async throws -> [RemoteItem] {
        // SFTP protocol: SSH_FXP_OPENDIR -> SSH_FXP_READDIR -> SSH_FXP_CLOSE
        let requestId = nextRequestId()
        
        // Open directory
        let handle = try await sftpOpenDirectory(path: path, requestId: requestId, channel: channel)
        defer {
            // Close handle (best effort)
            Task {
                try? await sftpClose(handle: handle, requestId: nextRequestId(), channel: channel)
            }
        }
        
        // Read directory entries
        var items: [RemoteItem] = []
        var hasMore = true
        let basePath = path.hasSuffix("/") ? path : path + "/"
        
        while hasMore {
            let entries = try await sftpReadDirectory(handle: handle, basePath: basePath, requestId: nextRequestId(), channel: channel)
            if entries.isEmpty {
                hasMore = false
            } else {
                items.append(contentsOf: entries)
                // Some servers return all entries at once, others paginate
                // If we get fewer than a reasonable batch, assume we're done
                if entries.count < 100 {
                    hasMore = false
                }
            }
        }
        
        return items
    }
    
    private func sftpOpenDirectory(path: String, requestId: UInt32, channel: Channel) async throws -> Data {
        // SSH_FXP_OPENDIR (11) - request_id, path
        let buffer = SFTPProtocol.packet(allocator: channel.allocator, type: SFTPProtocol.opendir, capacity: 8 + path.utf8.count) { payload in
            payload.writeInteger(requestId, endianness: .big)
            SFTPProtocol.writeString(path, to: &payload)
        }
        
        return try await sftpSendRequest(buffer: buffer, requestId: requestId, channel: channel) { responseBuffer in
            // Response: SSH_FXP_HANDLE (102) - request_id, handle
            var buffer = responseBuffer
            guard buffer.readableBytes >= 5 else {
                throw TransferError(message: "Invalid SFTP response length")
            }
            let packetType = buffer.readInteger(as: UInt8.self) ?? 0
            let responseRequestId = buffer.readInteger(as: UInt32.self) ?? 0
            
            guard packetType == SFTPProtocol.handle else {
                if packetType == SFTPProtocol.status {
                    var statusBuffer = responseBuffer
                    _ = statusBuffer.readInteger(as: UInt8.self)
                    let statusCode = try self.readStatusCode(from: &statusBuffer, requestId: requestId)
                    let errorMessage = self.sftpStatusMessage(from: &statusBuffer)
                    throw TransferError(message: "SFTP error: \(errorMessage) (code: \(statusCode))")
                }
                throw TransferError(message: "Unexpected SFTP packet type: \(packetType)")
            }
            
            guard responseRequestId == requestId else {
                throw TransferError(message: "Request ID mismatch")
            }
            
            let handleLength = buffer.readInteger(as: UInt32.self) ?? 0
            guard handleLength > 0, let handle = buffer.readBytes(length: Int(handleLength)) else {
                throw TransferError(message: "Invalid handle in SFTP response")
            }
            
            return Data(handle)
        }
    }
    
    private func sftpReadDirectory(handle: Data, basePath: String, requestId: UInt32, channel: Channel) async throws -> [RemoteItem] {
        // SSH_FXP_READDIR (12) - request_id, handle
        let buffer = SFTPProtocol.packet(allocator: channel.allocator, type: SFTPProtocol.readdir, capacity: 8 + handle.count) { payload in
            payload.writeInteger(requestId, endianness: .big)
            SFTPProtocol.writeData(handle, to: &payload)
        }
        
        return try await sftpSendRequest(buffer: buffer, requestId: requestId, channel: channel) { responseBuffer in
            // Response: SSH_FXP_NAME (104) - request_id, count, entries...
            var buffer = responseBuffer
            guard buffer.readableBytes >= 5 else {
                throw TransferError(message: "Invalid SFTP response length")
            }
            let packetType = buffer.readInteger(as: UInt8.self) ?? 0
            let responseRequestId = buffer.readInteger(as: UInt32.self) ?? 0
            
            guard responseRequestId == requestId else {
                throw TransferError(message: "Request ID mismatch")
            }
            
            if packetType == SFTPProtocol.status {
                let statusCode = buffer.readInteger(as: UInt32.self) ?? 0
                if statusCode == 1 { // SSH_FX_EOF
                    return [] // End of directory
                }
                let errorMessage = self.sftpStatusMessage(from: &buffer)
                throw TransferError(message: "SFTP error: \(errorMessage) (code: \(statusCode))")
            }
            
            guard packetType == SFTPProtocol.name else {
                throw TransferError(message: "Unexpected SFTP packet type: \(packetType)")
            }
            
            let count = buffer.readInteger(as: UInt32.self) ?? 0
            var items: [RemoteItem] = []
            
            for _ in 0..<count {
                // Read filename
                let filenameLength = buffer.readInteger(as: UInt32.self) ?? 0
                guard let filename = buffer.readString(length: Int(filenameLength)) else {
                    continue
                }
                guard filename != "." && filename != ".." else {
                    _ = SFTPProtocol.readString(from: &buffer)
                    _ = self.readAttributes(from: &buffer)
                    continue
                }
                
                // Skip longname (display name)
                let longnameLength = buffer.readInteger(as: UInt32.self) ?? 0
                _ = buffer.readBytes(length: Int(longnameLength))
                
                let attributes = self.readAttributes(from: &buffer)
                
                // Build path
                let itemPath = basePath + filename
                
                items.append(RemoteItem(name: filename, path: itemPath, isDirectory: attributes.isDirectory, size: Int64(attributes.size), permissions: attributes.permissions))
            }
            
            return items
        }
    }
    
    private func sftpClose(handle: Data, requestId: UInt32, channel: Channel) async throws {
        // SSH_FXP_CLOSE (4) - request_id, handle
        let buffer = SFTPProtocol.packet(allocator: channel.allocator, type: SFTPProtocol.close, capacity: 8 + handle.count) { payload in
            payload.writeInteger(requestId, endianness: .big)
            SFTPProtocol.writeData(handle, to: &payload)
        }
        
        _ = try await sftpSendRequest(buffer: buffer, requestId: requestId, channel: channel) { responseBuffer in
            // Response: SSH_FXP_STATUS (101) - request_id, status_code
            var buffer = responseBuffer
            let packetType = buffer.readInteger(as: UInt8.self) ?? 0
            guard packetType == SFTPProtocol.status else {
                return () // Ignore unexpected responses
            }
            try self.validateOKStatus(from: &buffer, requestId: requestId)
            return ()
        }
    }
    
    private func sftpDownload(remotePath: String, localURL: URL, channel: Channel, transferId: UUID?, progressCallback: ((Int64, Int64) -> Void)?) async throws {
        // SFTP protocol: SSH_FXP_OPEN -> SSH_FXP_READ -> SSH_FXP_CLOSE
        let requestId = nextRequestId()
        
        // Open file for reading
        let handle = try await sftpOpenFile(path: remotePath, flags: 0x00000001, requestId: requestId, channel: channel) // SSH_FXF_READ
        defer {
            Task {
                try? await sftpClose(handle: handle, requestId: nextRequestId(), channel: channel)
            }
        }
        
        // Get file attributes to determine size
        let attrs = try await sftpStat(path: remotePath, requestId: nextRequestId(), channel: channel)
        let fileSize = attrs.size
        
        // Read file data
        let destinationFile = localURL.appendingPathComponent((remotePath as NSString).lastPathComponent)
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true, attributes: nil)
        
        let fileHandle = try FileHandle(forWritingTo: destinationFile)
        defer { try? fileHandle.close() }
        
        var offset: UInt64 = 0
        let chunkSize: UInt32 = 32768 // 32KB chunks
        
        while offset < fileSize {
            let chunk = try await sftpReadFile(handle: handle, offset: offset, length: chunkSize, requestId: nextRequestId(), channel: channel)
            if chunk.isEmpty {
                break // EOF
            }
            
            fileHandle.write(Data(chunk))
            offset += UInt64(chunk.count)
            
            // Report progress
            if let callback = progressCallback {
                callback(Int64(offset), Int64(fileSize))
            }
            
            // Check for cancellation
            if let id = transferId {
                let isCancelled = transferLock.withLock {
                    activeTransfers[id] != nil
                }
                if isCancelled {
                    throw TransferError(message: "Transfer cancelled")
                }
            }
        }
    }
    
    private func sftpUpload(localURL: URL, remotePath: String, channel: Channel, transferId: UUID?, progressCallback: ((Int64, Int64) -> Void)?) async throws {
        // Start accessing security-scoped resource if needed
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
        
        // Report initial progress
        if let callback = progressCallback {
            callback(0, fileSize > 0 ? fileSize : 1)
        }
        
        // Open file for writing (create or truncate)
        let requestId = nextRequestId()
        let handle = try await sftpOpenFile(path: remotePath, flags: 0x00000002 | 0x00000008, requestId: requestId, channel: channel) // SSH_FXF_WRITE | SSH_FXF_CREAT
        defer {
            Task {
                try? await sftpClose(handle: handle, requestId: nextRequestId(), channel: channel)
            }
        }
        
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer {
            try? fileHandle.close()
        }
        
        // Stream file data in chunks so large uploads do not allocate the whole file.
        var offset: UInt64 = 0
        let chunkSize: UInt32 = 32768 // 32KB chunks
        var bytesWritten: Int64 = 0
        
        while offset < UInt64(fileSize) {
            let chunk = try fileHandle.read(upToCount: Int(chunkSize)) ?? Data()
            if chunk.isEmpty {
                break
            }
            
            try await sftpWriteFile(handle: handle, offset: offset, data: chunk, requestId: nextRequestId(), channel: channel)
            
            offset += UInt64(chunk.count)
            bytesWritten = Int64(offset)
            
            // Report progress
            if let callback = progressCallback {
                callback(bytesWritten, fileSize)
            }
            
            // Check for cancellation
            if let id = transferId {
                let isCancelled = transferLock.withLock {
                    activeTransfers[id] != nil
                }
                if isCancelled {
                    throw TransferError(message: "Transfer cancelled")
                }
            }
        }
        
        // Report 100% progress
        if let callback = progressCallback {
            callback(fileSize, fileSize)
        }
    }
    
    private func sftpDelete(path: String, isDirectory: Bool, channel: Channel) async throws {
        let requestId = nextRequestId()
        
        if isDirectory {
            // SSH_FXP_RMDIR (15) - request_id, path
            let buffer = SFTPProtocol.packet(allocator: channel.allocator, type: SFTPProtocol.rmdir, capacity: 8 + path.utf8.count) { payload in
                payload.writeInteger(requestId, endianness: .big)
                SFTPProtocol.writeString(path, to: &payload)
            }
            
            _ = try await sftpSendRequest(buffer: buffer, requestId: requestId, channel: channel) { responseBuffer in
                var buffer = responseBuffer
                let packetType = buffer.readInteger(as: UInt8.self) ?? 0
                if packetType == SFTPProtocol.status {
                    try self.validateOKStatus(from: &buffer, requestId: requestId)
                }
                return ()
            }
        } else {
            // SSH_FXP_REMOVE (13) - request_id, path
            let buffer = SFTPProtocol.packet(allocator: channel.allocator, type: SFTPProtocol.remove, capacity: 8 + path.utf8.count) { payload in
                payload.writeInteger(requestId, endianness: .big)
                SFTPProtocol.writeString(path, to: &payload)
            }
            
            _ = try await sftpSendRequest(buffer: buffer, requestId: requestId, channel: channel) { responseBuffer in
                var buffer = responseBuffer
                let packetType = buffer.readInteger(as: UInt8.self) ?? 0
                if packetType == SFTPProtocol.status {
                    try self.validateOKStatus(from: &buffer, requestId: requestId)
                }
                return ()
            }
        }
    }
    
    private func sftpRename(oldPath: String, newPath: String, channel: Channel) async throws {
        // SSH_FXP_RENAME (18) - request_id, oldpath, newpath
        let requestId = nextRequestId()
        let buffer = SFTPProtocol.packet(allocator: channel.allocator, type: SFTPProtocol.rename, capacity: 12 + oldPath.utf8.count + newPath.utf8.count) { payload in
            payload.writeInteger(requestId, endianness: .big)
            SFTPProtocol.writeString(oldPath, to: &payload)
            SFTPProtocol.writeString(newPath, to: &payload)
        }
        
        _ = try await sftpSendRequest(buffer: buffer, requestId: requestId, channel: channel) { responseBuffer in
            var buffer = responseBuffer
            let packetType = buffer.readInteger(as: UInt8.self) ?? 0
            if packetType == SFTPProtocol.status {
                try self.validateOKStatus(from: &buffer, requestId: requestId)
            }
            return ()
        }
    }
    
    private func sftpMkdir(path: String, channel: Channel) async throws {
        // SSH_FXP_MKDIR (14) - request_id, path, attrs
        let requestId = nextRequestId()
        let buffer = SFTPProtocol.packet(allocator: channel.allocator, type: SFTPProtocol.mkdir, capacity: 12 + path.utf8.count) { payload in
            payload.writeInteger(requestId, endianness: .big)
            SFTPProtocol.writeString(path, to: &payload)
            payload.writeInteger(UInt32(0), endianness: .big) // attrs flags (empty)
        }
        
        _ = try await sftpSendRequest(buffer: buffer, requestId: requestId, channel: channel) { responseBuffer in
            var buffer = responseBuffer
            let packetType = buffer.readInteger(as: UInt8.self) ?? 0
            if packetType == SFTPProtocol.status {
                try self.validateOKStatus(from: &buffer, requestId: requestId)
            }
            return ()
        }
    }
    
    private func sftpSetPermissions(path: String, permissions: UInt32, channel: Channel) async throws {
        // SSH_FXP_SETSTAT (9) - request_id, path, attrs
        let requestId = nextRequestId()
        let buffer = SFTPProtocol.packet(allocator: channel.allocator, type: SFTPProtocol.setstat, capacity: 16 + path.utf8.count) { payload in
            payload.writeInteger(requestId, endianness: .big)
            SFTPProtocol.writeString(path, to: &payload)
            payload.writeInteger(UInt32(0x00000004), endianness: .big) // SSH_FILEXFER_ATTR_PERMISSIONS flag
            payload.writeInteger(permissions, endianness: .big)
        }
        
        _ = try await sftpSendRequest(buffer: buffer, requestId: requestId, channel: channel) { responseBuffer in
            var buffer = responseBuffer
            let packetType = buffer.readInteger(as: UInt8.self) ?? 0
            if packetType == SFTPProtocol.status {
                try self.validateOKStatus(from: &buffer, requestId: requestId)
            }
            return ()
        }
    }
    
    private func sftpOpenFile(path: String, flags: UInt32, requestId: UInt32, channel: Channel) async throws -> Data {
        // SSH_FXP_OPEN (3) - request_id, filename, pflags, attrs
        let buffer = SFTPProtocol.packet(allocator: channel.allocator, type: SFTPProtocol.open, capacity: 16 + path.utf8.count) { payload in
            payload.writeInteger(requestId, endianness: .big)
            SFTPProtocol.writeString(path, to: &payload)
            payload.writeInteger(flags, endianness: .big) // pflags
            payload.writeInteger(UInt32(0), endianness: .big) // attrs (empty)
        }
        
        return try await sftpSendRequest(buffer: buffer, requestId: requestId, channel: channel) { responseBuffer in
            var buffer = responseBuffer
            let packetType = buffer.readInteger(as: UInt8.self) ?? 0
            let responseRequestId = buffer.readInteger(as: UInt32.self) ?? 0
            
            guard packetType == SFTPProtocol.handle else {
                if packetType == SFTPProtocol.status {
                    var statusBuffer = responseBuffer
                    _ = statusBuffer.readInteger(as: UInt8.self)
                    let statusCode = try self.readStatusCode(from: &statusBuffer, requestId: requestId)
                    let errorMessage = self.sftpStatusMessage(from: &statusBuffer)
                    throw TransferError(message: "SFTP error: \(errorMessage) (code: \(statusCode))")
                }
                throw TransferError(message: "Unexpected SFTP packet type: \(packetType)")
            }
            
            guard responseRequestId == requestId else {
                throw TransferError(message: "Request ID mismatch")
            }
            
            let handleLength = buffer.readInteger(as: UInt32.self) ?? 0
            guard handleLength > 0, let handle = buffer.readBytes(length: Int(handleLength)) else {
                throw TransferError(message: "Invalid handle in SFTP response")
            }
            
            return Data(handle)
        }
    }
    
    private func sftpReadFile(handle: Data, offset: UInt64, length: UInt32, requestId: UInt32, channel: Channel) async throws -> [UInt8] {
        // SSH_FXP_READ (5) - request_id, handle, offset, length
        let buffer = SFTPProtocol.packet(allocator: channel.allocator, type: SFTPProtocol.read, capacity: 20 + handle.count) { payload in
            payload.writeInteger(requestId, endianness: .big)
            SFTPProtocol.writeData(handle, to: &payload)
            payload.writeInteger(offset, endianness: .big)
            payload.writeInteger(length, endianness: .big)
        }
        
        return try await sftpSendRequest(buffer: buffer, requestId: requestId, channel: channel) { responseBuffer in
            var buffer = responseBuffer
            let packetType = buffer.readInteger(as: UInt8.self) ?? 0
            let responseRequestId = buffer.readInteger(as: UInt32.self) ?? 0
            
            guard responseRequestId == requestId else {
                throw TransferError(message: "Request ID mismatch")
            }
            
            if packetType == SFTPProtocol.status {
                let statusCode = buffer.readInteger(as: UInt32.self) ?? 0
                if statusCode == 1 { // SSH_FX_EOF
                    return [] // End of file
                }
                let errorMessage = self.sftpStatusMessage(from: &buffer)
                throw TransferError(message: "SFTP error: \(errorMessage) (code: \(statusCode))")
            }
            
            guard packetType == SFTPProtocol.data else {
                throw TransferError(message: "Unexpected SFTP packet type: \(packetType)")
            }
            
            let dataLength = buffer.readInteger(as: UInt32.self) ?? 0
            guard let data = buffer.readBytes(length: Int(dataLength)) else {
                return []
            }
            
            return data
        }
    }
    
    private func sftpWriteFile(handle: Data, offset: UInt64, data: Data, requestId: UInt32, channel: Channel) async throws {
        // SSH_FXP_WRITE (6) - request_id, handle, offset, data
        let buffer = SFTPProtocol.packet(allocator: channel.allocator, type: SFTPProtocol.write, capacity: 20 + handle.count + data.count) { payload in
            payload.writeInteger(requestId, endianness: .big)
            SFTPProtocol.writeData(handle, to: &payload)
            payload.writeInteger(offset, endianness: .big)
            SFTPProtocol.writeData(data, to: &payload)
        }
        
        _ = try await sftpSendRequest(buffer: buffer, requestId: requestId, channel: channel) { responseBuffer in
            var buffer = responseBuffer
            let packetType = buffer.readInteger(as: UInt8.self) ?? 0
            if packetType == SFTPProtocol.status {
                try self.validateOKStatus(from: &buffer, requestId: requestId)
            }
            return ()
        }
    }
    
    private func sftpStat(path: String, requestId: UInt32, channel: Channel) async throws -> (size: UInt64, isDirectory: Bool) {
        // SSH_FXP_STAT (17) - request_id, path
        let buffer = SFTPProtocol.packet(allocator: channel.allocator, type: SFTPProtocol.stat, capacity: 8 + path.utf8.count) { payload in
            payload.writeInteger(requestId, endianness: .big)
            SFTPProtocol.writeString(path, to: &payload)
        }
        
        return try await sftpSendRequest(buffer: buffer, requestId: requestId, channel: channel) { responseBuffer in
            var buffer = responseBuffer
            let packetType = buffer.readInteger(as: UInt8.self) ?? 0
            let responseRequestId = buffer.readInteger(as: UInt32.self) ?? 0
            
            guard responseRequestId == requestId else {
                throw TransferError(message: "Request ID mismatch")
            }
            
            if packetType == SFTPProtocol.status {
                let statusCode = buffer.readInteger(as: UInt32.self) ?? 0
                let errorMessage = self.sftpStatusMessage(from: &buffer)
                throw TransferError(message: "SFTP error: \(errorMessage) (code: \(statusCode))")
            }
            
            guard packetType == SFTPProtocol.attrs else {
                throw TransferError(message: "Unexpected SFTP packet type: \(packetType)")
            }
            
            let attributes = self.readAttributes(from: &buffer)
            return (size: attributes.size, isDirectory: attributes.isDirectory)
        }
    }
    
    private func sftpSendRequest<T>(buffer: ByteBuffer, requestId: UInt32, channel: Channel, handler: @escaping (ByteBuffer) throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            // Get or create the SFTP response handler
            channel.pipeline.handler(type: SFTPResponseHandler.self).whenComplete { result in
                switch result {
                case .success(let existingHandler):
                    // Handler exists, use it
                    existingHandler.addRequest(requestId: requestId) { responseBuffer in
                        do {
                            let result = try handler(responseBuffer)
                            continuation.resume(returning: result)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                    
                    // Send request
                    channel.writeAndFlush(buffer).whenFailure { error in
                        continuation.resume(throwing: error)
                    }
                    
                case .failure:
                    // Handler doesn't exist, create it
                    let responseHandler = SFTPResponseHandler()
                    channel.pipeline.addHandler(responseHandler, position: .last).whenComplete { addResult in
                        switch addResult {
                        case .success:
                            responseHandler.addRequest(requestId: requestId) { responseBuffer in
                                do {
                                    let result = try handler(responseBuffer)
                                    continuation.resume(returning: result)
                                } catch {
                                    continuation.resume(throwing: error)
                                }
                            }
                            
                            // Send request
                            channel.writeAndFlush(buffer).whenFailure { error in
                                continuation.resume(throwing: error)
                            }
                            
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Authentication Delegates

@preconcurrency
nonisolated private final class SFTPClientAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String?
    private let privateKeyPath: String?
    private var authAttempted = false
    
    // #region agent log helper
    private func debugLogAuth(location: String, message: String, data: [String: Any], hypothesisId: String) {
        let logPath = "/Users/anewman/Library/CloudStorage/OneDrive-sbfoods.com/Documents/XCode Projects/Shuttler/Shuttler/.cursor/debug.log"
        let payload: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: logPath) else { return }
        handle.seekToEndOfFile()
        handle.write(jsonData)
        handle.write(Data("\n".utf8))
        try? handle.close()
    }
    // #endregion
    
    init(username: String, password: String?, privateKeyPath: String?) {
        self.username = username
        self.password = password
        self.privateKeyPath = privateKeyPath
    }
    
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        defer {
            authAttempted = true
        }

        // #region agent log
        debugLogAuth(
            location: "NativeSFTPClient:SFTPClientAuthDelegate",
            message: "next_auth_type",
            data: [
                "availableMethods": String(describing: availableMethods),
                "hasPassword": password != nil,
                "hasKey": privateKeyPath != nil,
                "authAttempted": authAttempted
            ],
            hypothesisId: "H2"
        )
        // #endregion
        
        if authAttempted {
            // #region agent log
            debugLogAuth(
                location: "NativeSFTPClient:SFTPClientAuthDelegate",
                message: "auth_already_attempted",
                data: [:],
                hypothesisId: "H2"
            )
            // #endregion
            nextChallengePromise.succeed(nil)
            return
        }
        
        if let password = password, availableMethods.contains(.password) {
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            )
            // #region agent log
            debugLogAuth(
                location: "NativeSFTPClient:SFTPClientAuthDelegate",
                message: "using_password_offer",
                data: ["availableMethods": String(describing: availableMethods)],
                hypothesisId: "H2"
            )
            // #endregion
            nextChallengePromise.succeed(offer)
        } else if let keyPath = privateKeyPath, availableMethods.contains(.publicKey) {
            // Try to load private key
            // Note: For now, key loading is limited - use system SSH transport for key auth
            // Proper implementation requires OpenSSH format parser
            do {
                // Use a local loader instance to avoid actor isolation issues
                let privateKey = try SSHKeyLoader().loadPrivateKey(from: keyPath)
                let offer = NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .privateKey(.init(privateKey: privateKey))
                )
                // #region agent log
                debugLogAuth(
                    location: "NativeSFTPClient:SFTPClientAuthDelegate",
                    message: "using_key_offer",
                    data: ["availableMethods": String(describing: availableMethods)],
                    hypothesisId: "H2"
                )
                // #endregion
                nextChallengePromise.succeed(offer)
            } catch {
                print("⚠️ Failed to load private key: \(error.localizedDescription)")
                // Fall through to fail authentication
                // #region agent log
                debugLogAuth(
                    location: "NativeSFTPClient:SFTPClientAuthDelegate",
                    message: "key_load_failed",
                    data: ["error": error.localizedDescription],
                    hypothesisId: "H2"
                )
                // #endregion
                nextChallengePromise.succeed(nil)
            }
        } else {
            // #region agent log
            debugLogAuth(
                location: "NativeSFTPClient:SFTPClientAuthDelegate",
                message: "no_supported_methods",
                data: ["availableMethods": String(describing: availableMethods)],
                hypothesisId: "H2"
            )
            // #endregion
            nextChallengePromise.succeed(nil)
        }
    }
}

// MARK: - SFTP Channel Handlers

@preconcurrency
nonisolated private final class SFTPInitHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    
    private var initPromise: EventLoopPromise<Void>?
    private var initReceived = false
    private var inboundBuffer: ByteBuffer?
    private weak var handlerContext: ChannelHandlerContext?
    
    init(initPromise: EventLoopPromise<Void>) {
        self.initPromise = initPromise
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        handlerContext = context
    }
    
    func sendInit() {
        guard let context = handlerContext else {
            initPromise?.fail(TransferError(message: "SFTP handler was not ready"))
            initPromise = nil
            return
        }
        
        // SFTP init: send SSH_FXP_INIT (1) with version
        let buffer = SFTPProtocol.packet(allocator: context.channel.allocator, type: SFTPProtocol.initialize, capacity: 4) { payload in
            payload.writeInteger(UInt32(3), endianness: .big) // SFTP version 3
        }
        context.writeAndFlush(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        
        guard case .byteBuffer(let bytes) = channelData.data else {
            return
        }
        
        switch channelData.type {
        case .channel:
            let packets = SFTPProtocol.extractPacketPayloads(
                from: bytes,
                accumulator: &inboundBuffer,
                allocator: context.channel.allocator
            )
            
            for var packet in packets where !initReceived {
                let packetType = packet.readInteger(as: UInt8.self) ?? 0
                if packetType == SFTPProtocol.version {
                    let version = packet.readInteger(as: UInt32.self) ?? 0
                    print("📡 SFTP: Server version \(version)")
                    initReceived = true
                    initPromise?.succeed(())
                    initPromise = nil
                    context.pipeline.removeHandler(self, promise: nil)
                }
            }
        default:
            break
        }
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(data))), promise: promise)
    }
}

@preconcurrency
nonisolated private final class SFTPResponseHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    
    private var pendingRequests: [UInt32: (ByteBuffer) -> Void] = [:]
    private let lock = NSLock()
    private var inboundBuffer: ByteBuffer?
    
    func addRequest(requestId: UInt32, handler: @escaping (ByteBuffer) -> Void) {
        lock.withLock {
            pendingRequests[requestId] = handler
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        
        guard case .byteBuffer(let bytes) = channelData.data else {
            return
        }
        
        switch channelData.type {
        case .channel:
            let packets = SFTPProtocol.extractPacketPayloads(
                from: bytes,
                accumulator: &inboundBuffer,
                allocator: context.channel.allocator
            )
            
            for packet in packets where packet.readableBytes >= 5 {
                // Read request ID from response
                let readerIndex = packet.readerIndex
                _ = packet.getInteger(at: readerIndex, as: UInt8.self) ?? 0 // packetType - not used here
                let responseRequestId = packet.getInteger(at: readerIndex + 1, as: UInt32.self) ?? 0
                
                let handler = lock.withLock {
                    pendingRequests.removeValue(forKey: responseRequestId)
                }
                
                if let handler = handler {
                    // Create a copy of the buffer for the handler
                    let responseBuffer = packet
                    handler(responseBuffer)
                }
            }
        default:
            break
        }
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(data))), promise: promise)
    }
}
