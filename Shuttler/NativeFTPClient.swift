//
//  NativeFTPClient.swift
//  Shuttler
//
//  Native FTP client implementation using SwiftNIO
//

import Foundation
import NIOCore
import NIOPosix
#if canImport(Darwin)
import Darwin
#endif

/// Native FTP client implementation using SwiftNIO
final class NativeFTPClient: CancellableTransport {
    private let connection: Connection
    private var eventLoopGroup: EventLoopGroup?
    private var controlChannel: Channel?
    private var dataChannel: Channel?
    private var passivePort: Int?
    private var passiveAddress: String?
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
    }
    
    deinit {
        // Cleanup will be handled by connect/disconnect pattern
    }
    
    // MARK: - Transporting Protocol
    
    // Helper function to resolve hostname to IP address using getaddrinfo
    private func resolveHostname(_ hostname: String) async throws -> String {
        var hints = addrinfo()
        hints.ai_family = AF_INET // Prefer IPv4
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = 0
        
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        defer {
            if let result = result {
                freeaddrinfo(result)
            }
        }
        
        guard status == 0, let addrInfo = result else {
            // Try without hints if first attempt fails
            var hints2 = addrinfo()
            var result2: UnsafeMutablePointer<addrinfo>?
            let status2 = getaddrinfo(hostname, nil, &hints2, &result2)
            defer {
                if let result2 = result2 {
                    freeaddrinfo(result2)
                }
            }
            
            guard status2 == 0, let addrInfo2 = result2 else {
                throw TransferError(message: "Failed to resolve hostname: \(hostname) (getaddrinfo returned \(status2))")
            }
            result = result2
            return try extractIP(from: addrInfo2)
        }
        
        return try extractIP(from: addrInfo)
    }
    
    private func extractIP(from addrInfo: UnsafeMutablePointer<addrinfo>) throws -> String {
        var current: UnsafeMutablePointer<addrinfo>? = addrInfo
        while let curr = current {
            var ipBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(curr.pointee.ai_addr, socklen_t(curr.pointee.ai_addrlen), &ipBuffer, socklen_t(ipBuffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ipString = String(cString: ipBuffer)
                // Prefer IPv4 addresses
                if !ipString.hasPrefix("::") && !ipString.hasPrefix("fe80") {
                    return ipString
                }
            }
            current = curr.pointee.ai_next
        }
        
        // If no preferred address found, try first one again
        var ipBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addrInfo.pointee.ai_addr, socklen_t(addrInfo.pointee.ai_addrlen), &ipBuffer, socklen_t(ipBuffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            return String(cString: ipBuffer)
        }
        
        throw TransferError(message: "Failed to extract IP from resolved address")
    }
    
    func connect(outputHandler: ((String) -> Void)? = nil) async throws {
        guard let password = connection.getPassword() else {
            throw TransferError(message: "FTP requires a password")
        }
        
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group
        
        let trimmedHost = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
        
        outputHandler?("Connecting to \(trimmedHost):\(connection.port)...")
        
        // Try to resolve hostname to IP first, then connect directly to IP
        // This might bypass some sandbox routing issues with hostname resolution
        let connectHost: String
        do {
            let resolvedIP = try await resolveHostname(trimmedHost)
            connectHost = resolvedIP
        } catch {
            // If resolution fails, use hostname and let SwiftNIO handle it
            connectHost = trimmedHost
        }
        
        // Create minimal bootstrap
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(10))
            .channelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    let handler = FTPControlHandler(username: self.connection.username, password: password, outputHandler: outputHandler)
                    try sync.addHandler(handler)
                    return ()
                }
            }
        
        do {
            // Connect directly to IP address instead of hostname
            let channel = try await bootstrap.connect(host: connectHost, port: connection.port).get()
            self.controlChannel = channel
        
            outputHandler?("TCP connection established")
            
            // Wait for FTP greeting and authentication
            try await withTimeout(seconds: 30) {
                try await self.waitForFTPReady(channel: channel)
            }
            
            outputHandler?("FTP authentication successful")
        } catch {
            
            // Convert NIO errors to user-friendly messages
            let errorMsg: String
            if let nioError = error as? NIOConnectionError {
                let errorStr = String(describing: nioError)
                // Parse the error string to extract useful information
                if errorStr.contains("No route to host") || errorStr.contains("errno: 65") {
                    errorMsg = "No route to host. SwiftNIO cannot connect to \(trimmedHost):\(connection.port) in the sandboxed app environment. This is a known limitation with SwiftNIO and macOS app sandbox restrictions for private network connections.\n\nIf you need to connect to this server, please:\n• Ensure you're connected to the same network as the server\n• Try using a system FTP client (like ncftp) to verify connectivity\n• Consider using SFTP instead, which uses a different connection mechanism\n\nNote: System tools can connect to this server, but SwiftNIO in sandboxed apps has routing limitations."
                } else if errorStr.contains("Connection refused") || errorStr.contains("errno: 61") {
                    errorMsg = "Connection refused by server at \(trimmedHost):\(connection.port). The server is reachable but not accepting connections. Please check if the FTP service is running."
                } else if errorStr.contains("Connection timed out") || errorStr.contains("errno: 60") {
                    errorMsg = "Connection timed out while connecting to \(trimmedHost):\(connection.port). The server did not respond. Please check your network connection and firewall settings."
                } else if errorStr.contains("dns") || errorStr.contains("DNS") {
                    errorMsg = "DNS lookup failed for host: \(trimmedHost). Please check the hostname and your network connection."
                } else {
                    errorMsg = "Connection failed: \(nioError.localizedDescription). Please check the host (\(trimmedHost)) and port (\(connection.port))."
                }
            } else {
                // For other errors, provide the error description
                errorMsg = error.localizedDescription
            }
            throw TransferError(message: "FTP connection failed: \(errorMsg)")
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
    
    private func waitForFTPReady(channel: Channel) async throws {
        let handler = channel.pipeline.handler(type: FTPControlHandler.self)
        try await handler.flatMap { (ftpHandler: FTPControlHandler) -> EventLoopFuture<Void> in
            guard let promise = ftpHandler.readyPromise else {
                return channel.eventLoop.makeFailedFuture(TransferError(message: "FTP handler not ready"))
            }
            return promise.futureResult
        }.get()
    }
    
    func list(directory: RemotePath) async throws -> [RemoteItem] {
        guard let controlChannel = controlChannel else {
            throw TransferError(message: "Not connected")
        }
        
        let dir = directory.rawValue.isEmpty ? "/" : directory.rawValue
        
        // Enter passive mode
        try await enterPassiveMode(channel: controlChannel)
        
        // Open data connection
        guard let dataPort = passivePort, let dataAddress = passiveAddress else {
            throw TransferError(message: "Failed to get passive mode information")
        }
        
        let dataChannel = try await openDataConnection(host: dataAddress, port: dataPort)
        defer {
            Task {
                try? await dataChannel.close().get()
            }
        }
        
        // Send LIST command
        try await sendFTPCommand(command: "LIST \(dir)", channel: controlChannel)
        
        // Wait for initial response (150 Opening data connection, or 125 Data connection already open)
        // Some servers send this, others go straight to data transfer
        let initialResponse = try await waitForFTPResponse(channel: controlChannel, expectedCode: nil)
        let initialCode = Int(initialResponse.prefix(3)) ?? 0
        // Check for error codes (4xx, 5xx)
        if initialCode >= 400 {
            throw TransferError(message: "FTP error: \(initialResponse)")
        }
        
        // If we got 226 immediately, transfer is complete (empty directory)
        if initialCode == 226 {
            return [] // Empty directory
        }
        
        // Read directory listing from data channel
        let listingData = try await readDataChannel(channel: dataChannel)
        
        // Wait for transfer complete response (226)
        _ = try await waitForFTPResponse(channel: controlChannel, expectedCode: 226) // Transfer complete
        
        // Parse listing
        return parseFTPListing(listingData, baseDirectory: dir)
    }
    
    func openDirectory(_ item: RemoteItem) async throws -> RemotePath {
        RemotePath(rawValue: item.path)
    }
    
    func directoryExists(_ path: String) async throws -> Bool {
        guard controlChannel != nil else {
            throw TransferError(message: "Not connected")
        }
        
        let dir = path.isEmpty ? "/" : path
        
        // Try to list the directory - if it succeeds, the directory exists
        do {
            _ = try await list(directory: RemotePath(rawValue: dir))
            return true
        } catch {
            // If listing fails, directory doesn't exist or is not accessible
            return false
        }
    }
    
    func download(item: RemoteItem, to localURL: URL, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        try await download(item: item, to: localURL, transferId: nil, progressCallback: progressCallback)
    }
    
    func download(item: RemoteItem, to localURL: URL, transferId: UUID?, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        guard let controlChannel = controlChannel else {
            throw TransferError(message: "Not connected")
        }
        
        // Enter passive mode
        try await enterPassiveMode(channel: controlChannel)
        
        guard let dataPort = passivePort, let dataAddress = passiveAddress else {
            throw TransferError(message: "Failed to get passive mode information")
        }
        
        let dataChannel = try await openDataConnection(host: dataAddress, port: dataPort)
        defer {
            Task {
                try? await dataChannel.close().get()
            }
        }
        
        // Send RETR command
        try await sendFTPCommand(command: "RETR \(item.path)", channel: controlChannel)
        
        // Wait for initial response (150 Opening data connection, or 125 Data connection already open)
        let initialResponse = try await waitForFTPResponse(channel: controlChannel, expectedCode: nil)
        let initialCode = Int(initialResponse.prefix(3)) ?? 0
        // Check for error codes (4xx, 5xx)
        if initialCode >= 400 {
            throw TransferError(message: "FTP error: \(initialResponse)")
        }
        // If we got 150 or 125, proceed. If we got something else (like 226), that's also okay
        
        // Capture the response promise for the 226 response BEFORE reading data
        // The 226 response may arrive quickly after the data channel closes, so we need to
        // capture the promise before starting the data transfer to avoid a race condition
        let handler = controlChannel.pipeline.handler(type: FTPControlHandler.self)
        let completionResponseFuture = try await handler.flatMap { (ftpHandler: FTPControlHandler) -> EventLoopFuture<EventLoopFuture<(code: Int, message: String)>> in
            guard let promise = ftpHandler.responsePromise else {
                return controlChannel.eventLoop.makeFailedFuture(TransferError(message: "FTP handler not ready"))
            }
            return controlChannel.eventLoop.makeSucceededFuture(promise.futureResult)
        }.get()
        
        // Read file data from data channel
        let destinationFile = localURL.appendingPathComponent(item.name)
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true, attributes: nil)
        
        // Create empty file if it doesn't exist, or truncate if it does (FileHandle(forWritingTo:) requires file to exist)
        if FileManager.default.fileExists(atPath: destinationFile.path) {
            // Remove existing file to ensure clean write
            try? FileManager.default.removeItem(at: destinationFile)
        }
        FileManager.default.createFile(atPath: destinationFile.path, contents: nil, attributes: nil)
        
        let fileHandle = try FileHandle(forWritingTo: destinationFile)
        defer { try? fileHandle.close() }
        
        var bytesReceived: Int64 = 0
        
        try await readDataChannelStreaming(channel: dataChannel) { chunk in
            fileHandle.write(chunk)
            bytesReceived += Int64(chunk.count)
            
            if let callback = progressCallback, item.size > 0 {
                callback(bytesReceived, item.size)
            }
            
            // Check for cancellation
            if let id = transferId {
                let isCancelled = self.transferLock.withLock {
                    self.activeTransfers[id] != nil
                }
                if isCancelled {
                    throw TransferError(message: "Transfer cancelled")
                }
            }
        }
        
        // Wait for transfer complete response using the captured promise
        _ = try await completionResponseFuture.flatMapThrowing { (code, message) in
            guard code == 226 else {
                throw TransferError(message: "FTP error: Expected code 226, got \(code): \(message)")
            }
            return (code, message)
        }.get()
        
        // Report final progress
        if let callback = progressCallback {
            callback(bytesReceived, item.size > 0 ? item.size : bytesReceived)
        }
    }
    
    func upload(localURL: URL, to directory: RemotePath, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        try await upload(localURL: localURL, to: directory, transferId: nil, progressCallback: progressCallback)
    }
    
    func upload(localURL: URL, to directory: RemotePath, transferId: UUID?, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        guard let controlChannel = controlChannel else {
            throw TransferError(message: "Not connected")
        }
        
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
        
        let fileData = try Data(contentsOf: localURL)
        let fileSize = Int64(fileData.count)
        
        // Report initial progress
        if let callback = progressCallback {
            callback(0, fileSize > 0 ? fileSize : 1)
        }
        
        let fileName = localURL.lastPathComponent
        let remotePath = directory.rawValue.hasSuffix("/") ? "\(directory.rawValue)\(fileName)" : "\(directory.rawValue)/\(fileName)"
        
        // Enter passive mode
        try await enterPassiveMode(channel: controlChannel)
        
        guard let dataPort = passivePort, let dataAddress = passiveAddress else {
            throw TransferError(message: "Failed to get passive mode information")
        }
        
        let dataChannel = try await openDataConnection(host: dataAddress, port: dataPort)
        defer {
            Task {
                try? await dataChannel.close().get()
            }
        }
        
        // Send STOR command
        try await sendFTPCommand(command: "STOR \(remotePath)", channel: controlChannel)
        
        // Wait for initial response (150 Opening data connection, or 125 Data connection already open)
        let initialResponse = try await waitForFTPResponse(channel: controlChannel, expectedCode: nil)
        let initialCode = Int(initialResponse.prefix(3)) ?? 0
        // Check for error codes (4xx, 5xx)
        if initialCode >= 400 {
            throw TransferError(message: "FTP error: \(initialResponse)")
        }
        // If we got 150 or 125, proceed. If we got something else (like 226), that's also okay
        
        // Write file data to data channel
        var bytesWritten: Int64 = 0
        let chunkSize = 32768 // 32KB chunks
        
        for offset in stride(from: 0, to: fileData.count, by: chunkSize) {
            let chunkEnd = min(offset + chunkSize, fileData.count)
            let chunk = fileData[offset..<chunkEnd]
            
            var buffer = dataChannel.allocator.buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            try await dataChannel.writeAndFlush(buffer).get()
            
            bytesWritten += Int64(chunk.count)
            
            // Report progress
            if let callback = progressCallback {
                callback(bytesWritten, fileSize)
            }
            
            // Check for cancellation
            if let id = transferId {
                let isCancelled = self.transferLock.withLock {
                    self.activeTransfers[id] != nil
                }
                if isCancelled {
                    throw TransferError(message: "Transfer cancelled")
                }
            }
        }
        
        // Close data channel output
        try await dataChannel.close(mode: .output).get()
        
        // Wait for transfer complete response
        _ = try await waitForFTPResponse(channel: controlChannel, expectedCode: 226)
        
        // Report 100% progress
        if let callback = progressCallback {
            callback(fileSize, fileSize)
        }
    }
    
    func delete(item: RemoteItem) async throws {
        guard let controlChannel = controlChannel else {
            throw TransferError(message: "Not connected")
        }
        
        let command = item.isDirectory ? "RMD" : "DELE"
        try await sendFTPCommand(command: "\(command) \(item.path)", channel: controlChannel)
        _ = try await waitForFTPResponse(channel: controlChannel, expectedCode: 250) // Requested file action okay
    }
    
    func rename(item: RemoteItem, to newName: String) async throws {
        guard let controlChannel = controlChannel else {
            throw TransferError(message: "Not connected")
        }
        
        let directory = (item.path as NSString).deletingLastPathComponent
        let newPath = directory.hasSuffix("/") ? "\(directory)\(newName)" : "\(directory)/\(newName)"
        
        // RNFR (rename from)
        try await sendFTPCommand(command: "RNFR \(item.path)", channel: controlChannel)
        _ = try await waitForFTPResponse(channel: controlChannel, expectedCode: 350) // File exists, ready for destination name
        
        // RNTO (rename to)
        try await sendFTPCommand(command: "RNTO \(newPath)", channel: controlChannel)
        _ = try await waitForFTPResponse(channel: controlChannel, expectedCode: 250) // Requested file action okay
    }
    
    func createDirectory(name: String, in directory: RemotePath) async throws {
        guard let controlChannel = controlChannel else {
            throw TransferError(message: "Not connected")
        }
        
        let baseDir = directory.rawValue
        let newPath = baseDir.hasSuffix("/") ? "\(baseDir)\(name)" : "\(baseDir)/\(name)"
        
        // MKD (make directory)
        try await sendFTPCommand(command: "MKD \(newPath)", channel: controlChannel)
        _ = try await waitForFTPResponse(channel: controlChannel, expectedCode: 257) // Pathname created
    }
    
    // MARK: - Private Methods
    
    private func enterPassiveMode(channel: Channel) async throws {
        // Get the current response promise's future BEFORE sending the command to avoid race condition
        // The response might arrive very quickly and fulfill the promise before waitForFTPResponse is called
        let handler = channel.pipeline.handler(type: FTPControlHandler.self)
        let responseFuture = try await handler.flatMap { (ftpHandler: FTPControlHandler) -> EventLoopFuture<EventLoopFuture<(code: Int, message: String)>> in
            guard let promise = ftpHandler.responsePromise else {
                return channel.eventLoop.makeFailedFuture(TransferError(message: "FTP handler not ready"))
            }
            return channel.eventLoop.makeSucceededFuture(promise.futureResult)
        }.get()
        
        // Send PASV command
        try await sendFTPCommand(command: "PASV", channel: channel)
        
        // Wait for response with passive mode information using the future we captured
        // Format: "227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)"
        let (_, message) = try await responseFuture.flatMapThrowing { (code, message) in
            guard code == 227 else {
                throw TransferError(message: "FTP error: Expected code 227, got \(code): \(message)")
            }
            return (code, message)
        }.get()
        
        let response = message
        
        // Parse passive mode response
        // Extract IP and port from response like "227 Entering Passive Mode (192,168,1,1,234,56)"
        if let openParen = response.range(of: "("),
           let closeParen = response.range(of: ")", range: openParen.upperBound..<response.endIndex) {
            let numbers = String(response[openParen.upperBound..<closeParen.lowerBound])
            let parts = numbers.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            
            if parts.count == 6 {
                passiveAddress = "\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3])"
                passivePort = parts[4] * 256 + parts[5]
            }
        }
        
        guard passivePort != nil, passiveAddress != nil else {
            throw TransferError(message: "Failed to parse passive mode response: \(response)")
        }
    }
    
    private func openDataConnection(host: String, port: Int) async throws -> Channel {
        let bootstrap = ClientBootstrap(group: eventLoopGroup!)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        
        return try await bootstrap.connect(host: host, port: port).get()
    }
    
    private func sendFTPCommand(command: String, channel: Channel) async throws {
        let handler = channel.pipeline.handler(type: FTPControlHandler.self)
        return try await handler.flatMap { ftpHandler in
            // Create new promise for this command
            let newPromise = channel.eventLoop.makePromise(of: Void.self)
            ftpHandler.commandSentPromise = newPromise
            
            var buffer = channel.allocator.buffer(capacity: command.count + 2)
            buffer.writeString(command)
            buffer.writeString("\r\n")
            return channel.writeAndFlush(buffer).flatMap {
                // Complete promise when write finishes
                newPromise.succeed(())
                return newPromise.futureResult
            }
        }.get()
    }
    
    private func waitForFTPResponse(channel: Channel, expectedCode: Int? = nil) async throws -> String {
        let handler = channel.pipeline.handler(type: FTPControlHandler.self)
        return try await handler.flatMap { (ftpHandler: FTPControlHandler) -> EventLoopFuture<String> in
            guard let promise = ftpHandler.responsePromise else {
                return channel.eventLoop.makeFailedFuture(TransferError(message: "FTP handler not ready"))
            }
            return promise.futureResult.flatMapThrowing { (code, message) in
                if let expected = expectedCode, code != expected {
                    throw TransferError(message: "FTP error: Expected code \(expected), got \(code): \(message)")
                }
                return message
            }
        }.get()
    }
    
    private func readDataChannel(channel: Channel) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let handler = FTPDataHandler()
            channel.pipeline.addHandler(handler, position: .last).flatMap { _ in
                guard let promise = handler.dataPromise else {
                    return channel.eventLoop.makeFailedFuture(TransferError(message: "FTP data handler not ready"))
                }
                // Wait for the promise to complete (when channel closes)
                return promise.futureResult
            }.whenComplete { result in
                continuation.resume(with: result)
            }
        }
    }
    
    private func readDataChannelStreaming(channel: Channel, callback: @escaping (Data) throws -> Void) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let handler = FTPStreamingDataHandler(callback: callback)
            channel.pipeline.addHandler(handler, position: .last).flatMap { _ in
                guard let promise = handler.completePromise else {
                    return channel.eventLoop.makeFailedFuture(TransferError(message: "FTP streaming handler not ready"))
                }
                return promise.futureResult
            }.whenComplete { result in
                continuation.resume(with: result)
            }
        }
    }
    
    private func parseFTPListing(_ data: Data, baseDirectory: String) -> [RemoteItem] {
        guard let text = String(data: data, encoding: .utf8) else {
            print("❌ FTP Parse: Failed to decode data as UTF-8 (size: \(data.count) bytes)")
            return []
        }
        
        print("📋 FTP Parse: Parsing \(data.count) bytes, \(text.count) characters")
        
        // Normalize line endings: replace \r\n with \n, then split
        // FTP servers typically send \r\n line endings
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedText.split(separator: "\n", omittingEmptySubsequences: true)
        print("📋 FTP Parse: Found \(lines.count) lines after normalization")
        
        var items: [RemoteItem] = []
        let baseDir = baseDirectory.hasSuffix("/") ? baseDirectory : baseDirectory + "/"
        
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                print("📋 FTP Parse: Line \(index) is empty, skipping")
                continue
            }
            
            print("📋 FTP Parse: Processing line \(index): \(trimmed.prefix(80))")
            
            // Parse FTP LIST output (detailed format like ls -l)
            // Format: permissions links owner group size month day time/year name
            // Example: -rw-r--r-- 1 adam adam 13312 Mar 28  2016 2016-03-28_ds_crm.sql
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            
            guard parts.count >= 4 else {
                print("📋 FTP Parse: Line \(index) has too few parts (\(parts.count)), skipping")
                continue
            }
            
            let perms = String(parts[0])
            let isDir = perms.first == "d"
            
            // Try to find size field (usually at index 4)
            var size: Int64 = 0
            var nameStartIndex = parts.count - 1
            
            // Look for size starting at index 4 (after perms, links, owner, group)
            for i in 4..<min(parts.count, 10) {
                if let parsedSize = Int64(parts[i]) {
                    // Check if next part looks like a date (month name or number)
                    if i + 1 < parts.count {
                        let nextPart = String(parts[i + 1])
                        // Month names are 3 letters, or could be a day number
                        if (nextPart.count == 3 && nextPart.allSatisfy({ $0.isLetter })) ||
                           (nextPart.count <= 2 && nextPart.allSatisfy({ $0.isNumber })) {
                            size = parsedSize
                            // Name starts after: perms links owner group size month day [time] name
                            // That's typically 3 more fields after size (month, day, time/year)
                            nameStartIndex = min(i + 3, parts.count - 1)
                            // But if there's a time field, it might be 4 fields
                            if i + 3 < parts.count {
                                let timeOrYear = String(parts[i + 3])
                                // If it looks like a time (HH:MM) or year (4 digits), name is next
                                if timeOrYear.contains(":") || (timeOrYear.count == 4 && timeOrYear.allSatisfy({ $0.isNumber })) {
                                    nameStartIndex = min(i + 4, parts.count - 1)
                                }
                            }
                            break
                        }
                    } else if i == parts.count - 1 {
                        // Last part, might be size if format is unusual
                        size = parsedSize
                        nameStartIndex = i
                        break
                    }
                }
            }
            
            // Fallback: try index 4 as size (standard position)
            if size == 0 && parts.count > 4 {
                if let parsedSize = Int64(parts[4]) {
                    size = parsedSize
                    // Assume standard format: perms links owner group size month day time name
                    nameStartIndex = min(8, parts.count - 1)
                }
            }
            
            if nameStartIndex < parts.count {
                let nameParts = parts.suffix(from: nameStartIndex)
                let name = nameParts.joined(separator: " ")
                let path = baseDir + name
                print("📋 FTP Parse: Parsed item: name=\(name), isDir=\(isDir), size=\(size)")
                items.append(RemoteItem(name: String(name), path: path, isDirectory: isDir, size: size, permissions: nil))
            } else {
                print("📋 FTP Parse: Line \(index) - could not determine name start index (parts.count=\(parts.count), nameStartIndex=\(nameStartIndex))")
            }
        }
        
        print("📋 FTP Parse: Successfully parsed \(items.count) items from \(lines.count) lines")
        return items
    }
}

// MARK: - FTP Handlers

@preconcurrency
nonisolated private final class FTPControlHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    private let username: String
    private let password: String
    private let outputHandler: ((String) -> Void)?
    private var buffer = Data()
    private var isAuthenticated = false
    private var greetingReceived = false
    private var passwordSent = false
    private var waitingForInteractiveResponse = false
    private weak var eventLoop: EventLoop?
    private var channelContext: ChannelHandlerContext?
    
    var readyPromise: EventLoopPromise<Void>?
    var commandSentPromise: EventLoopPromise<Void>?
    var responsePromise: EventLoopPromise<(code: Int, message: String)>?
    
    init(username: String, password: String, outputHandler: ((String) -> Void)? = nil) {
        self.username = username
        self.password = password
        self.outputHandler = outputHandler
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        self.eventLoop = context.eventLoop
        self.channelContext = context
        self.readyPromise = context.eventLoop.makePromise()
        self.commandSentPromise = context.eventLoop.makePromise()
        self.responsePromise = context.eventLoop.makePromise()
        // Complete initial commandSentPromise immediately (no command sent yet)
        self.commandSentPromise?.succeed(())
    }
    
    func handlerRemoved(context: ChannelHandlerContext) {
        // Complete any pending promises to prevent leaks
        readyPromise?.fail(TransferError(message: "FTP handler removed"))
        commandSentPromise?.fail(TransferError(message: "FTP handler removed"))
        responsePromise?.fail(TransferError(message: "FTP handler removed"))
        readyPromise = nil
        commandSentPromise = nil
        responsePromise = nil
        channelContext = nil
    }
    
    func channelActive(context: ChannelHandlerContext) {
        // Enable auto-read
        context.channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { [weak self] error in
            self?.readyPromise?.fail(error)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        // Complete any pending promises when channel closes
        if !isAuthenticated {
            readyPromise?.fail(TransferError(message: "FTP connection closed before authentication"))
        }
        commandSentPromise?.fail(TransferError(message: "FTP connection closed"))
        responsePromise?.fail(TransferError(message: "FTP connection closed"))
        context.fireChannelInactive()
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Complete promises on error
        readyPromise?.fail(error)
        commandSentPromise?.fail(error)
        responsePromise?.fail(error)
        context.fireErrorCaught(error)
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)
        
        if let string = buffer.readString(length: buffer.readableBytes) {
            if let stringData = string.data(using: .utf8) {
                self.buffer.append(contentsOf: stringData)
            }
            
            // Process complete lines
            let lineEnding = "\r\n".data(using: .utf8) ?? Data()
            while let lineRange = self.buffer.range(of: lineEnding) {
                let line = String(data: self.buffer[..<lineRange.lowerBound], encoding: .utf8) ?? ""
                self.buffer.removeSubrange(..<lineRange.upperBound)
                
                processFTPLine(line, context: context)
            }
        }
    }
    
    private func processFTPLine(_ line: String, context: ChannelHandlerContext) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        print("📥 FTP: \(trimmed)")
        
        // Parse FTP response code (3 digits)
        if trimmed.count >= 3, let code = Int(trimmed.prefix(3)) {
            let message = String(trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces))
            
            if !greetingReceived {
                // Server greeting
                greetingReceived = true
                // Send USER command
                sendCommand(command: "USER \(username)", context: context)
            } else if !isAuthenticated {
                if code == 331 { // User name okay, need password
                    if passwordSent {
                        requestInteractiveResponse(prompt: ftpPrompt(from: message, fallback: "Enter the additional FTP authentication response."), command: "PASS", context: context)
                    } else {
                        passwordSent = true
                        sendCommand(command: "PASS \(password)", context: context)
                    }
                } else if code == 332 { // Need account or second-factor response
                    requestInteractiveResponse(prompt: ftpPrompt(from: message, fallback: "Enter the FTP account or verification response."), command: "ACCT", context: context)
                } else if code == 230 { // User logged in
                    isAuthenticated = true
                    readyPromise?.succeed(())
                } else {
                    readyPromise?.fail(TransferError(message: "FTP authentication failed: \(message)"))
                }
            } else {
                // Regular command response
                responsePromise?.succeed((code: code, message: message))
                
                // Create new promise for next response
                let newPromise = context.eventLoop.makePromise(of: (code: Int, message: String).self)
                responsePromise = newPromise
            }
        }
    }
    
    private func ftpPrompt(from message: String, fallback: String) -> String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMessage.isEmpty {
            return fallback
        }
        return "FTP server prompt:\n\(trimmedMessage)"
    }
    
    private func requestInteractiveResponse(prompt: String, command: String, context: ChannelHandlerContext) {
        guard !waitingForInteractiveResponse else { return }
        guard let outputHandler else {
            readyPromise?.fail(TransferError(message: "FTP server requested an additional authentication response, but no interactive prompt is available. If your FTP server uses MFA, enter the complete password or password plus one-time code in the connection password field, or use SFTP/SCP for keyboard-interactive MFA."))
            context.close(promise: nil)
            return
        }
        
        waitingForInteractiveResponse = true
        let responseFile = FileManager.default.temporaryDirectory.appendingPathComponent("shuttler_ftp_response_\(UUID().uuidString).txt").path
        outputHandler(promptBridgeLine(prompt: prompt, responseFile: responseFile))
        pollForInteractiveResponse(responseFile: responseFile, command: command, remainingAttempts: 960)
    }
    
    private func pollForInteractiveResponse(responseFile: String, command: String, remainingAttempts: Int) {
        guard let context = channelContext else {
            readyPromise?.fail(TransferError(message: "FTP connection closed while waiting for authentication response."))
            return
        }
        
        if FileManager.default.fileExists(atPath: responseFile),
           let response = try? String(contentsOfFile: responseFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !response.isEmpty {
            try? FileManager.default.removeItem(atPath: responseFile)
            waitingForInteractiveResponse = false
            sendCommand(command: "\(command) \(response)", context: context)
            return
        }
        
        guard remainingAttempts > 0 else {
            waitingForInteractiveResponse = false
            readyPromise?.fail(TransferError(message: "Timed out waiting for FTP authentication response."))
            context.close(promise: nil)
            return
        }
        
        context.eventLoop.scheduleTask(in: .milliseconds(250)) { [weak self] in
            self?.pollForInteractiveResponse(responseFile: responseFile, command: command, remainingAttempts: remainingAttempts - 1)
        }
    }
    
    private func promptBridgeLine(prompt: String, responseFile: String) -> String {
        let safePrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "PROMPT::{\"prompt\":\"\(safePrompt)\",\"responseFile\":\"\(responseFile)\"}"
    }
    
    private func sendCommand(command: String, context: ChannelHandlerContext) {
        // Complete current promise and create new one for this command
        commandSentPromise?.succeed(())
        let newPromise = context.eventLoop.makePromise(of: Void.self)
        commandSentPromise = newPromise
        
        var buffer = context.channel.allocator.buffer(capacity: command.count + 2)
        buffer.writeString(command)
        buffer.writeString("\r\n")
        context.writeAndFlush(self.wrapOutboundOut(buffer)).whenComplete { result in
            // Complete promise when write finishes
            switch result {
            case .success:
                newPromise.succeed(())
            case .failure(let error):
                newPromise.fail(error)
            }
        }
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(data), promise: promise)
    }
}

@preconcurrency
nonisolated private final class FTPDataHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    var dataPromise: EventLoopPromise<Data>?
    private var data = Data()
    private weak var eventLoop: EventLoop?
    private var isComplete = false
    
    func handlerAdded(context: ChannelHandlerContext) {
        self.eventLoop = context.eventLoop
        self.dataPromise = context.eventLoop.makePromise()
    }
    
    func handlerRemoved(context: ChannelHandlerContext) {
        // Don't complete here - wait for channelInactive to ensure all data is received
        // If handler is removed but channel is still active, data might still be coming
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)
        let bytesRead = buffer.readableBytes
        if let bytes = buffer.readBytes(length: bytesRead) {
            self.data.append(contentsOf: bytes)
            print("📥 FTP Data: Read \(bytesRead) bytes (total: \(self.data.count) bytes)")
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        // Channel closed - all data has been received
        if !isComplete {
            isComplete = true
            print("📥 FTP Data: Channel closed, received \(self.data.count) bytes total")
            dataPromise?.succeed(self.data)
            dataPromise = nil
        }
        context.fireChannelInactive()
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(data), promise: promise)
    }
}

@preconcurrency
nonisolated private final class FTPStreamingDataHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    var completePromise: EventLoopPromise<Void>?
    private let callback: (Data) throws -> Void
    private weak var eventLoop: EventLoop?
    
    init(callback: @escaping (Data) throws -> Void) {
        self.callback = callback
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        self.eventLoop = context.eventLoop
        self.completePromise = context.eventLoop.makePromise()
    }
    
    func handlerRemoved(context: ChannelHandlerContext) {
        // Complete promise to prevent leaks
        completePromise?.succeed(())
        completePromise = nil
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            do {
                try callback(Data(bytes))
            } catch {
                completePromise?.fail(error)
            }
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        completePromise?.succeed(())
        context.fireChannelInactive()
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        completePromise?.fail(error)
        context.fireErrorCaught(error)
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(data), promise: promise)
    }
}
