//
//  Transfers.swift
//  Shuttler
//
//  Transport abstraction and protocol-specific placeholders.
//

import Foundation

// Local debug logger (mirrors SSHTransport debugLog) to trace transport selection
private func debugLog(location: String, message: String, data: [String: Any] = [:], hypothesisId: String = "") {
    let primaryLogPath = "/Users/anewman/Library/CloudStorage/OneDrive-sbfoods.com/Documents/XCode Projects/Shuttler/Shuttler/.cursor/debug.log"
    let secondaryLogPath = "/Users/anewman/Library/Containers/FinalReality.Shuttler/Data/Documents/debug.log"
    let logPaths = [primaryLogPath, secondaryLogPath]
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    var logEntry: [String: Any] = [
        "location": location,
        "message": message,
        "timestamp": timestamp,
        "sessionId": "debug-session",
        "runId": "run1"
    ]
    if !data.isEmpty {
        var safeData: [String: Any] = [:]
        for (k, v) in data {
            if JSONSerialization.isValidJSONObject([k: v]) {
                safeData[k] = v
            } else {
                safeData[k] = String(describing: v)
            }
        }
        logEntry["data"] = safeData
    }
    if !hypothesisId.isEmpty { logEntry["hypothesisId"] = hypothesisId }
    
    guard
        let logData = try? JSONSerialization.data(withJSONObject: logEntry),
        let logLine = String(data: logData, encoding: .utf8)
    else {
        print("🔍 DEBUG: Failed to serialize log entry")
        return
    }
    
    let consoleMsg = "[\(location)] \(message)" + (data.isEmpty ? "" : " \(data)")
    print("🔍 DEBUG: \(consoleMsg)")
    
    for logPath in logPaths {
        let logURL = URL(fileURLWithPath: logPath)
        let logDir = logURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true, attributes: nil)
            if FileManager.default.fileExists(atPath: logPath) {
                let fh = try FileHandle(forWritingTo: logURL)
                defer { fh.closeFile() }
                fh.seekToEndOfFile()
                if let lineData = (logLine + "\n").data(using: .utf8) { fh.write(lineData) }
            } else {
                try (logLine + "\n").write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("🔍 DEBUG: Failed to write log file: \(error.localizedDescription), path: \(logPath)")
        }
    }
}

struct TransferError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RemotePath: Hashable, Codable {
    var rawValue: String
}

protocol Transporting {
    func connect(outputHandler: ((String) -> Void)?) async throws
    func list(directory: RemotePath) async throws -> [RemoteItem]
    func openDirectory(_ item: RemoteItem) async throws -> RemotePath
    func download(item: RemoteItem, to localURL: URL, progressCallback: ((Int64, Int64) -> Void)?) async throws
    func upload(localURL: URL, to directory: RemotePath, progressCallback: ((Int64, Int64) -> Void)?) async throws
    func delete(item: RemoteItem) async throws
    func rename(item: RemoteItem, to newName: String) async throws
    func createDirectory(name: String, in directory: RemotePath) async throws
    func copy(item: RemoteItem, to destination: RemotePath) async throws
    func move(item: RemoteItem, to destination: RemotePath) async throws
    func duplicate(item: RemoteItem) async throws
    func changePermissions(item: RemoteItem, permissions: String) async throws
}

// Optional protocol for transports that support cancellation
protocol CancellableTransport: Transporting {
    func cancelTransfer(id: UUID)
    func download(item: RemoteItem, to localURL: URL, transferId: UUID?, progressCallback: ((Int64, Int64) -> Void)?) async throws
    func upload(localURL: URL, to directory: RemotePath, transferId: UUID?, progressCallback: ((Int64, Int64) -> Void)?) async throws
}

// Protocol extension to provide default implementation with nil outputHandler
extension Transporting {
    func connect() async throws {
        try await connect(outputHandler: nil)
    }
    
    func connect(outputHandler: ((String) -> Void)?) async throws {
        try await connect(outputHandler: outputHandler)
    }
    
    // Default implementations for copy, move, duplicate, and chmod
    // These can be overridden by specific transport implementations for better performance
    func copy(item: RemoteItem, to destination: RemotePath) async throws {
        // Default: download and re-upload
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        try await download(item: item, to: tempDir, progressCallback: nil)
        let localFile = tempDir.appendingPathComponent(item.name)
        try await upload(localURL: localFile, to: destination, progressCallback: nil)
    }
    
    func move(item: RemoteItem, to destination: RemotePath) async throws {
        // Default: copy then delete
        try await copy(item: item, to: destination)
        try await delete(item: item)
    }
    
    func duplicate(item: RemoteItem) async throws {
        // Default: copy to same directory with " copy" suffix
        let directory = RemotePath(rawValue: (item.path as NSString).deletingLastPathComponent)
        let baseName = (item.name as NSString).deletingPathExtension
        let ext = (item.name as NSString).pathExtension
        var newName = "\(baseName) copy"
        if !ext.isEmpty {
            newName = "\(newName).\(ext)"
        }
        // Find a unique name
        var counter = 1
        var finalName = newName
        let items = try await list(directory: directory)
        while items.contains(where: { $0.name == finalName }) {
            counter += 1
            if !ext.isEmpty {
                finalName = "\(baseName) copy \(counter).\(ext)"
            } else {
                finalName = "\(baseName) copy \(counter)"
            }
        }
        let destinationPath = directory.rawValue.hasSuffix("/") 
            ? "\(directory.rawValue)\(finalName)" 
            : "\(directory.rawValue)/\(finalName)"
        try await copy(item: item, to: RemotePath(rawValue: destinationPath))
    }
    
    func changePermissions(item: RemoteItem, permissions: String) async throws {
        // Default: throw not implemented - should be overridden by transports that support it
        throw TransferError(message: "Changing permissions is not supported by this transport")
    }
}

final class TransportFactory {
    static func make(for connection: Connection) -> Transporting {
        let transportType: String
        switch connection.protocolType {
        case .ftp:
            transportType = "NativeFTPClient"
        case .sftp:
            transportType = connection.useSystemSSHTransport ? "SFTPClient(system)" : "NativeSFTPClient"
        case .scp:
            transportType = connection.useSystemSSHTransport ? "SCPClient(system)" : "NativeSCPClient"
        }
        
        // #region agent log
        debugLog(
            location: "Transfers.swift:TransportFactory",
            message: "Selecting transport",
            data: [
                "protocol": "\(connection.protocolType)",
                "useSystemSSHTransport": connection.useSystemSSHTransport,
                "transportType": transportType,
                "connectionId": connection.id.uuidString
            ],
            hypothesisId: "H1"
        )
        // #endregion
        
        switch connection.protocolType {
        case .ftp: return NativeFTPClient(connection: connection) // Use native implementation
        case .sftp: 
            // For SFTP, use system SSH transport if explicitly requested (for MFA support)
            if connection.useSystemSSHTransport {
                return SFTPClient(connection: connection)
            }
            return NativeSFTPClient(connection: connection) // Use native implementation
        case .scp: 
            // For SCP, use system SSH transport if explicitly requested (for MFA/keyboard-interactive support)
            // System SSH transport supports MFA/Duo via expect scripts
            if connection.useSystemSSHTransport {
                return SCPClient(connection: connection)
            }
            return NativeSCPClient(connection: connection) // Use native NIOSSH implementation (works better for 99% of cases)
        }
    }
}

final class FTPClient: Transporting {
    private let connection: Connection
    init(connection: Connection) { self.connection = connection }

    func connect(outputHandler: ((String) -> Void)? = nil) async throws {
        // Test FTP connection by attempting to list the root directory
        // This reuses the list() method which we know works
        // Note: FTP doesn't support interactive prompts like Duo
        outputHandler?("Connecting to FTP server...")
        do {
            _ = try await list(directory: RemotePath(rawValue: "/"))
        } catch {
            // Re-throw with a clearer message if it's a connection error
            if let transferError = error as? TransferError {
                throw TransferError(message: "FTP connection failed: \(transferError.message)")
            }
            throw TransferError(message: "FTP connection failed: \(error.localizedDescription)")
        }
    }

    func list(directory: RemotePath) async throws -> [RemoteItem] {
        guard let password = connection.getPassword() else {
            throw TransferError(message: "FTP requires a password")
        }
        let dir = directory.rawValue.isEmpty ? "/" : directory.rawValue
        // Don't embed credentials in URL when using -u flag (causes conflicts)
        let url = "ftp://\(connection.host):\(connection.port)\(dir)"
        // Use -l flag to get detailed listing (like ls -l) instead of --list-only
        // Use -u for authentication (handles special chars in password better)
        // Use --show-error to ensure errors are shown even in silent mode
        // Use -P - to use passive mode (required by many FTP servers)
        let args = ["-s", "--show-error", "-P", "-", "-u", "\(connection.username):\(password)", "-l", url]
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = args
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            // Capture error from stderr
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            // Also check stdout in case error went there
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let outputText = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            // Combine error messages
            var errorMessage = "Exit code: \(process.terminationStatus)"
            if !errorText.isEmpty {
                errorMessage += " - \(errorText)"
            }
            if !outputText.isEmpty && errorText.isEmpty {
                errorMessage += " - \(outputText)"
            }
            
            throw TransferError(message: "FTP list failed: \(errorMessage)")
        }
        
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        
        var items: [RemoteItem] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            
            // Parse FTP LIST output (detailed format like ls -l)
            // Format: permissions links owner group size month day time/year name
            // Example: -rw-r--r-- 1 anewman anewman 24692375 Dec 5 18:15 FL0694-BC-HP-2.8.5.0.4724.fl
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            
            guard parts.count >= 4 else {
                // Too few parts, skip or treat as simple name
                let name = trimmed
                let path = dir.hasSuffix("/") ? "\(dir)\(name)" : "\(dir)/\(name)"
                items.append(RemoteItem(name: String(name), path: path, isDirectory: false, size: 0, permissions: nil))
                continue
            }
            
            let perms = String(parts[0])
            let isDir = perms.first == "d"
            
            // Extract permissions string (convert symbolic to octal)
            let permissionsString: String?
            if perms.count >= 10 {
                let permsOnly = String(perms.dropFirst()) // Remove type char
                if permsOnly.count == 9 {
                    func charToValue(_ char: Character) -> Int {
                        switch char {
                        case "r": return 4
                        case "w": return 2
                        case "x", "s", "t": return 1
                        default: return 0
                        }
                    }
                    let owner = permsOnly.prefix(3)
                    let group = permsOnly.dropFirst(3).prefix(3)
                    let other = permsOnly.suffix(3)
                    let ownerVal = owner.map(charToValue).reduce(0, +)
                    let groupVal = group.map(charToValue).reduce(0, +)
                    let otherVal = other.map(charToValue).reduce(0, +)
                    let octal = ownerVal * 100 + groupVal * 10 + otherVal
                    permissionsString = String(format: "%o", octal)
                } else {
                    permissionsString = nil
                }
            } else {
                permissionsString = nil
            }
            
            // Try to find the size field - it's usually a large number before the date
            // Date typically starts with a 3-letter month name
            var size: Int64 = 0
            var nameStartIndex = parts.count - 1
            
            // Look for size field (usually index 4, but can vary)
            for i in 4..<min(parts.count, 9) {
                if let parsedSize = Int64(parts[i]) {
                    // Check if next field looks like a month (3 letters) or if we're near the end
                    if i + 1 < parts.count {
                        let nextPart = String(parts[i + 1])
                        // If next is a month name (3 letters) or a day (1-2 digits), this is likely the size
                        if (nextPart.count == 3 && nextPart.allSatisfy({ $0.isLetter })) || 
                           (nextPart.count <= 2 && nextPart.allSatisfy({ $0.isNumber })) {
                            size = parsedSize
                            // Name starts after: perms, links, owner, group, size, month, day, time
                            // That's typically index 8, but find the last numeric/time field
                            nameStartIndex = i + 4 // size, month, day, time, then name
                            break
                        }
                    } else if i == parts.count - 1 {
                        // Last field, might be size if it's a number
                        size = parsedSize
                        nameStartIndex = i
                        break
                    }
                }
            }
            
            // Fallback: try index 4 (standard position)
            if size == 0 && parts.count > 4 {
                if let parsedSize = Int64(parts[4]) {
                    size = parsedSize
                    // Assume standard format: perms links owner group size month day time name
                    nameStartIndex = min(8, parts.count - 1)
                }
            }
            
            // Extract name - everything from nameStartIndex to end
            if nameStartIndex < parts.count {
                let nameParts = parts.suffix(from: nameStartIndex)
                let name = nameParts.joined(separator: " ")
                let path = dir.hasSuffix("/") ? "\(dir)\(name)" : "\(dir)/\(name)"
                items.append(RemoteItem(name: String(name), path: path, isDirectory: isDir, size: size, permissions: permissionsString))
            } else {
                // Fallback: use last part as name
                let name = String(parts.last ?? "")
                let path = dir.hasSuffix("/") ? "\(dir)\(name)" : "\(dir)/\(name)"
                items.append(RemoteItem(name: name, path: path, isDirectory: isDir, size: size, permissions: permissionsString))
            }
        }
        
        return items
    }

    func openDirectory(_ item: RemoteItem) async throws -> RemotePath {
        RemotePath(rawValue: item.path)
    }

    func download(item: RemoteItem, to localURL: URL, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        guard let password = connection.getPassword() else {
            throw TransferError(message: "FTP requires a password")
        }
        let destination = localURL.appendingPathComponent(item.name)
        let url = "ftp://\(connection.username):\(password)@\(connection.host):\(connection.port)\(item.path)"
        let args = ["-o", destination.path, url]
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = args
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw TransferError(message: "FTP download failed")
        }
    }

    func upload(localURL: URL, to directory: RemotePath, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        guard let password = connection.getPassword() else {
            throw TransferError(message: "FTP requires a password")
        }
        let fileName = localURL.lastPathComponent
        let remotePath = directory.rawValue.hasSuffix("/") ? "\(directory.rawValue)\(fileName)" : "\(directory.rawValue)/\(fileName)"
        let url = "ftp://\(connection.username):\(password)@\(connection.host):\(connection.port)\(remotePath)"
        let args = ["-T", localURL.path, url]
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = args
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw TransferError(message: "FTP upload failed")
        }
    }
    
    func delete(item: RemoteItem) async throws {
        guard let password = connection.getPassword() else {
            throw TransferError(message: "FTP requires a password")
        }
        let url = "ftp://\(connection.username):\(password)@\(connection.host):\(connection.port)\(item.path)"
        let command = item.isDirectory ? "RMD" : "DELE"
        let args = ["-Q", "\(command) \(item.path)", url]
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = args
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw TransferError(message: "FTP delete failed")
        }
    }
    
    func rename(item: RemoteItem, to newName: String) async throws {
        guard let password = connection.getPassword() else {
            throw TransferError(message: "FTP requires a password")
        }
        let url = "ftp://\(connection.username):\(password)@\(connection.host):\(connection.port)"
        let directory = (item.path as NSString).deletingLastPathComponent
        let newPath = directory.hasSuffix("/") ? "\(directory)\(newName)" : "\(directory)/\(newName)"
        let args = ["-Q", "RNFR \(item.path)", "-Q", "RNTO \(newPath)", url]
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = args
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw TransferError(message: "FTP rename failed")
        }
    }
    
    func createDirectory(name: String, in directory: RemotePath) async throws {
        guard let password = connection.getPassword() else {
            throw TransferError(message: "FTP requires a password")
        }
        let baseDir = directory.rawValue
        let newPath = baseDir.hasSuffix("/") ? "\(baseDir)\(name)" : "\(baseDir)/\(name)"
        let url = "ftp://\(connection.username):\(password)@\(connection.host):\(connection.port)"
        let args = ["-Q", "MKD \(newPath)", url]
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = args
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw TransferError(message: "FTP create directory failed")
        }
    }
    
    func copy(item: RemoteItem, to destination: RemotePath) async throws {
        // FTP doesn't support native copy, use download/upload
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        try await download(item: item, to: tempDir, progressCallback: nil)
        let localFile = tempDir.appendingPathComponent(item.name)
        try await upload(localURL: localFile, to: destination, progressCallback: nil)
    }
    
    func move(item: RemoteItem, to destination: RemotePath) async throws {
        // FTP doesn't support native move, use copy+delete
        try await copy(item: item, to: destination)
        try await delete(item: item)
    }
    
    func duplicate(item: RemoteItem) async throws {
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
        
        // Copy to same directory with new name
        try await copy(item: item, to: directory)
        // Rename the copied file
        let copiedItem = RemoteItem(name: item.name, path: directory.rawValue.hasSuffix("/") ? "\(directory.rawValue)\(item.name)" : "\(directory.rawValue)/\(item.name)", isDirectory: item.isDirectory, size: item.size, permissions: item.permissions)
        try await rename(item: copiedItem, to: finalName)
    }
    
    func changePermissions(item: RemoteItem, permissions: String) async throws {
        // FTP typically doesn't support chmod via standard commands
        // Some FTP servers support SITE CHMOD, but it's not universal
        throw TransferError(message: "Changing permissions is not supported via FTP")
    }
}

// MARK: - Mocks

private func mockItems() -> [RemoteItem] {
    return [
        RemoteItem(name: "Documents", path: "/home/user/Documents", isDirectory: true, size: 0, permissions: "755"),
        RemoteItem(name: "notes.txt", path: "/home/user/notes.txt", isDirectory: false, size: 1_024, permissions: "644"),
        RemoteItem(name: "archive.zip", path: "/home/user/archive.zip", isDirectory: false, size: 5_242_880, permissions: "644")
    ]
}
