//
//  Transfers.swift
//  Shuttler
//
//  Transport abstraction and protocol-specific placeholders.
//

import Foundation

struct TransferError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RemotePath: Hashable, Codable {
    var rawValue: String
}

protocol Transporting {
    func connect() async throws
    func list(directory: RemotePath) async throws -> [RemoteItem]
    func openDirectory(_ item: RemoteItem) async throws -> RemotePath
    func download(item: RemoteItem, to localURL: URL) async throws
    func upload(localURL: URL, to directory: RemotePath) async throws
}

final class TransportFactory {
    static func make(for connection: Connection) -> Transporting {
        switch connection.protocolType {
        case .ftp: return FTPClient(connection: connection)
        case .sftp: return SFTPClient(connection: connection)
        case .scp: return SCPClient(connection: connection)
        }
    }
}

final class FTPClient: Transporting {
    private let connection: Connection
    init(connection: Connection) { self.connection = connection }

    func connect() async throws {
        // TODO: Implement real FTP connection
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func list(directory: RemotePath) async throws -> [RemoteItem] {
        // TODO: Replace with real FTP LIST
        return mockItems()
    }

    func openDirectory(_ item: RemoteItem) async throws -> RemotePath {
        RemotePath(rawValue: item.path)
    }

    func download(item: RemoteItem, to localURL: URL) async throws {
        // TODO: Implement FTP download
        throw TransferError(message: "FTP download not implemented")
    }

    func upload(localURL: URL, to directory: RemotePath) async throws {
        // TODO: Implement FTP upload
        throw TransferError(message: "FTP upload not implemented")
    }
}

final class SFTPClient: Transporting {
    private let connection: Connection
    init(connection: Connection) { self.connection = connection }

    func connect() async throws {
        // TODO: Implement real SFTP connection
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func list(directory: RemotePath) async throws -> [RemoteItem] {
        // TODO: Replace with real SFTP listing
        return mockItems()
    }

    func openDirectory(_ item: RemoteItem) async throws -> RemotePath {
        RemotePath(rawValue: item.path)
    }

    func download(item: RemoteItem, to localURL: URL) async throws {
        throw TransferError(message: "SFTP download not implemented")
    }

    func upload(localURL: URL, to directory: RemotePath) async throws {
        throw TransferError(message: "SFTP upload not implemented")
    }
}

final class SCPClient: Transporting {
    private let connection: Connection
    init(connection: Connection) { self.connection = connection }

    func connect() async throws {
        // TODO: Implement real SCP connection
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func list(directory: RemotePath) async throws -> [RemoteItem] {
        // SCP does not list by itself; typically uses SSH. Placeholder for now.
        return mockItems()
    }

    func openDirectory(_ item: RemoteItem) async throws -> RemotePath {
        RemotePath(rawValue: item.path)
    }

    func download(item: RemoteItem, to localURL: URL) async throws {
        throw TransferError(message: "SCP download not implemented")
    }

    func upload(localURL: URL, to directory: RemotePath) async throws {
        throw TransferError(message: "SCP upload not implemented")
    }
}

// MARK: - Mocks

private func mockItems() -> [RemoteItem] {
    return [
        RemoteItem(name: "Documents", path: "/home/user/Documents", isDirectory: true, size: 0),
        RemoteItem(name: "notes.txt", path: "/home/user/notes.txt", isDirectory: false, size: 1_024),
        RemoteItem(name: "archive.zip", path: "/home/user/archive.zip", isDirectory: false, size: 5_242_880)
    ]
}
