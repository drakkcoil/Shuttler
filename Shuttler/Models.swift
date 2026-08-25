//
//  Models.swift
//  Shuttler
//
//  Core models and persistence for connections and remote items.
//

import Foundation
import SwiftUI
import Combine

enum ProtocolType: String, CaseIterable, Identifiable, Codable, Equatable {
    case ftp
    case sftp
    case scp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        case .scp: return "SCP"
        }
    }

    var defaultPort: Int {
        switch self {
        case .ftp: return 21
        case .sftp, .scp: return 22
        }
    }

    var iconName: String {
        switch self {
        case .ftp: return "network"
        case .sftp: return "lock.shield"
        case .scp: return "arrow.triangle.swap"
        }
    }

    var tint: Color {
        switch self {
        case .ftp: return .blue
        case .sftp: return .green
        case .scp: return .orange
        }
    }
}

struct Connection: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var protocolType: ProtocolType
    var host: String
    var port: Int
    var username: String
    var password: String?
    var usesKeyAuth: Bool
    var privateKeyPath: String?
    var startingDirectory: String?
    var isFavorite: Bool
    var useSystemSSHTransport: Bool // Use system SSH transport instead of native client (for MFA/keyboard-interactive support)

    // Memberwise initializer
    init(id: UUID = UUID(), name: String, protocolType: ProtocolType, host: String, port: Int, username: String, password: String? = nil, usesKeyAuth: Bool = false, privateKeyPath: String? = nil, startingDirectory: String? = nil, isFavorite: Bool = false, useSystemSSHTransport: Bool = false) {
        self.id = id
        self.name = name
        self.protocolType = protocolType
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.usesKeyAuth = usesKeyAuth
        self.privateKeyPath = privateKeyPath
        self.startingDirectory = startingDirectory
        self.isFavorite = isFavorite
        self.useSystemSSHTransport = useSystemSSHTransport
    }

    // Custom decoding to handle missing fields gracefully
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        protocolType = try container.decode(ProtocolType.self, forKey: .protocolType)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        // Migration: Try to load password from JSON for backward compatibility, then migrate to Keychain
        if let plainPassword = try container.decodeIfPresent(String.self, forKey: .password), !plainPassword.isEmpty {
            password = plainPassword
            // Migrate to Keychain immediately
            KeychainManager.shared.migratePasswordIfNeeded(plainPassword, forConnectionId: id)
            // Clear from memory after migration
            password = nil
        } else {
            password = nil
        }
        usesKeyAuth = try container.decodeIfPresent(Bool.self, forKey: .usesKeyAuth) ?? false
        privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath)
        startingDirectory = try container.decodeIfPresent(String.self, forKey: .startingDirectory)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        useSystemSSHTransport = try container.decodeIfPresent(Bool.self, forKey: .useSystemSSHTransport) ?? false
    }
    
    // Custom encoding - password is NOT encoded to JSON, stored in Keychain instead
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(protocolType, forKey: .protocolType)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        // Password is NOT encoded - it's stored in Keychain
        // This ensures passwords are never persisted in plain text
        try container.encode(usesKeyAuth, forKey: .usesKeyAuth)
        try container.encodeIfPresent(privateKeyPath, forKey: .privateKeyPath)
        try container.encodeIfPresent(startingDirectory, forKey: .startingDirectory)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(useSystemSSHTransport, forKey: .useSystemSSHTransport)
    }
    
    /// Retrieve password from Keychain
    var passwordFromKeychain: String? {
        try? KeychainManager.shared.retrievePassword(forConnectionId: id)
    }

    static func example() -> Connection {
        Connection(name: "My Server", protocolType: .sftp, host: "example.com", port: ProtocolType.sftp.defaultPort, username: "user")
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, protocolType, host, port, username, password // password kept for migration only
        case usesKeyAuth, privateKeyPath, startingDirectory, isFavorite, useSystemSSHTransport
    }
    
    /// Get password - first try Keychain, then fallback to in-memory password (for temporary use)
    func getPassword() -> String? {
        if let keychainPassword = passwordFromKeychain {
            return keychainPassword
        }
        // Fallback to in-memory password (used temporarily during connection setup)
        return password
    }
    
    /// Store password - saves to Keychain
    mutating func setPassword(_ newPassword: String?) {
        password = newPassword // Keep in memory for immediate use
        if let pwd = newPassword {
            do {
                try KeychainManager.shared.storePassword(pwd, forConnectionId: id)
            } catch {
                print("⚠️ Failed to store password in Keychain: \(error)")
            }
        } else {
            // Remove password from Keychain if nil
            KeychainManager.shared.deletePassword(forConnectionId: id)
        }
    }
}

struct RemoteItem: Codable, Equatable, Hashable {
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var permissions: String? // e.g., "rwxr-xr-x" or "755"

    var sizeString: String {
        if isDirectory { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    var permissionsString: String {
        guard let perms = permissions else { return "—" }
        // If it's a 4-digit octal (includes special bits), show only last 3 digits
        // Otherwise, ensure it's formatted as 3 digits
        if perms.count == 4, let octal = UInt32(perms, radix: 8) {
            return String(format: "%03o", octal & 0o777)
        } else if perms.count == 3 {
            return perms
        } else {
            // Try to parse and format as 3-digit octal
            if let octal = UInt32(perms, radix: 8) {
                return String(format: "%03o", octal & 0o777)
            }
            return perms
        }
    }
    
    init(name: String, path: String, isDirectory: Bool, size: Int64, permissions: String? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.permissions = permissions
    }
}

@MainActor
final class ConnectionsStore: ObservableObject {
    @Published private(set) var connections: [Connection] = [] {
        didSet { save() }
    }

    private let saveURL: URL = {
        let fm = FileManager.default
        let appSupport = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("Shuttler", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json", isDirectory: false)
    }()

    init() {
        load()
    }

    func add(_ connection: Connection) {
        connections.append(connection)
    }
    
    func update(_ connection: Connection) {
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx] = connection
        }
    }

    func remove(_ connection: Connection) {
        connections.removeAll { $0.id == connection.id }
    }

    func remove(atOffsets offsets: IndexSet) {
        connections.remove(atOffsets: offsets)
    }

    func connection(id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }
    
    func toggleFavorite(_ connection: Connection) {
        if let idx = connections.firstIndex(of: connection) {
            connections[idx].isFavorite.toggle()
        }
    }
    
    func moveConnections(indices: IndexSet, to newOffset: Int) {
        connections.move(fromOffsets: indices, toOffset: newOffset)
    }
    
    func recordConnection(connectionId: UUID) {
        // Record when a connection is used (for recently connected)
        let recentURL = saveURL.deletingLastPathComponent().appendingPathComponent("recent_connections.json")
        var recentIds: [UUID] = []
        
        // Load existing recent connections
        if let data = try? Data(contentsOf: recentURL),
           let decoded = try? JSONDecoder().decode([UUID].self, from: data) {
            recentIds = decoded
        }
        
        // Remove if already exists (to move to front)
        recentIds.removeAll { $0 == connectionId }
        // Add to front
        recentIds.insert(connectionId, at: 0)
        // Keep only last 10
        recentIds = Array(recentIds.prefix(10))
        
        // Save
        if let data = try? JSONEncoder().encode(recentIds) {
            try? data.write(to: recentURL, options: [.atomic])
        }
    }
    
    func getRecentConnections(maxCount: Int = 5) -> [Connection] {
        let recentURL = saveURL.deletingLastPathComponent().appendingPathComponent("recent_connections.json")
        guard let data = try? Data(contentsOf: recentURL),
              let recentIds = try? JSONDecoder().decode([UUID].self, from: data) else {
            return []
        }
        
        // Return connections in recent order, filtering out any that no longer exist
        return recentIds.compactMap { id in
            connections.first { $0.id == id }
        }.prefix(maxCount).map { $0 }
    }

    private func load() {
        do {
            print("Loading connections from: \(saveURL.path)")
            // Check if file exists first
            guard FileManager.default.fileExists(atPath: saveURL.path) else {
                print("⚠️ Connections file does not exist at \(saveURL.path)")
                self.connections = []
                return
            }
            
            let data = try Data(contentsOf: saveURL)
            print("✅ Loaded connections data: \(data.count) bytes")
            
            let decoded = try JSONDecoder().decode([Connection].self, from: data)
            print("✅ Successfully decoded \(decoded.count) connections: \(decoded.map { $0.name }.joined(separator: ", "))")
            self.connections = decoded
        } catch let decodingError as DecodingError {
            print("❌ Failed to decode connections: \(decodingError)")
            if case .keyNotFound(let key, _) = decodingError {
                print("   Missing key: \(key.stringValue)")
            } else if case .typeMismatch(let type, let context) = decodingError {
                print("   Type mismatch: expected \(type), context: \(context)")
            } else if case .valueNotFound(let type, let context) = decodingError {
                print("   Value not found: \(type), context: \(context)")
            } else if case .dataCorrupted(let context) = decodingError {
                print("   Data corrupted: \(context)")
            }
            self.connections = []
        } catch {
            print("❌ Failed to load connections: \(error)")
            self.connections = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(connections)
            try data.write(to: saveURL, options: [.atomic])
        } catch {
            // Handle save error in the future
            print("Failed to save connections: \(error)")
        }
    }
}

