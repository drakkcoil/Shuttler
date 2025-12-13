//
//  Models.swift
//  Shuttler
//
//  Core models and persistence for connections and remote items.
//

import Foundation
import SwiftUI

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
    var id: UUID = UUID()
    var name: String
    var protocolType: ProtocolType
    var host: String
    var port: Int
    var username: String
    var password: String? = nil
    var usesKeyAuth: Bool = false
    var privateKeyPath: String? = nil

    static func example() -> Connection {
        Connection(name: "My Server", protocolType: .sftp, host: "example.com", port: ProtocolType.sftp.defaultPort, username: "user")
    }
}

struct RemoteItem: Codable, Equatable {
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64

    var sizeString: String {
        if isDirectory { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
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
        let dir = appSupport.appendingPathComponent("Shuttler", conformingTo: .directory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
    }()

    init() {
        load()
    }

    func add(_ connection: Connection) {
        connections.append(connection)
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

    private func load() {
        do {
            let data = try Data(contentsOf: saveURL)
            let decoded = try JSONDecoder().decode([Connection].self, from: data)
            self.connections = decoded
        } catch {
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
