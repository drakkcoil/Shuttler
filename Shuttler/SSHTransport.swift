//
//  SSHTransport.swift
//  Shuttler
//
//  Implements SFTP and SCP using system ssh/sftp/scp via Process.
//

import Foundation

// MARK: - Helpers

struct SSHAuthConfig {
    let host: String
    let port: Int
    let username: String
    let privateKeyPath: String?
}

enum SSHExec {
    static func sshArgs(_ auth: SSHAuthConfig, extra: [String]) -> [String] {
        var args: [String] = ["-o", "BatchMode=yes", "-p", String(auth.port)]
        if let key = auth.privateKeyPath, !key.isEmpty { args += ["-i", key] }
        args += ["\(auth.username)@\(auth.host)"]
        args += extra
        return args
    }

    static func sftpArgs(_ auth: SSHAuthConfig, extra: [String]) -> [String] {
        var args: [String] = ["-oBatchMode=yes", "-P", String(auth.port)]
        if let key = auth.privateKeyPath, !key.isEmpty { args += ["-i", key] }
        args += ["\(auth.username)@\(auth.host)"]
        args += extra
        return args
    }

    static func scpArgs(_ auth: SSHAuthConfig, extra: [String]) -> [String] {
        var args: [String] = ["-oBatchMode=yes", "-P", String(auth.port)]
        if let key = auth.privateKeyPath, !key.isEmpty { args += ["-i", key] }
        args += extra
        return args
    }
}

@discardableResult
private func runProcess(launchPath: String, arguments: [String], input: Data? = nil, timeout: TimeInterval = 30) throws -> (status: Int32, stdout: Data, stderr: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    if let input = input {
        let inPipe = Pipe()
        process.standardInput = inPipe
        try process.run()
        inPipe.fileHandleForWriting.write(input)
        inPipe.fileHandleForWriting.closeFile()
    } else {
        try process.run()
    }

    let group = DispatchGroup()
    group.enter()
    process.terminationHandler = { _ in group.leave() }

    let deadline = DispatchTime.now() + timeout
    if group.wait(timeout: deadline) == .timedOut {
        process.terminate()
        throw TransferError(message: "Command timed out")
    }

    let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
    let stderr = errPipe.fileHandleForReading.readDataToEndOfFile()

    return (process.terminationStatus, stdout, stderr)
}

private func parseLsLong(_ data: Data) -> [RemoteItem] {
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    var items: [RemoteItem] = []
    for line in text.split(separator: "\n") {
        // crude parser for lines like: drwxr-xr-x  2 user group    4096 Jan  1 12:00 Documents
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 9 else { continue }
        let perms = parts[0]
        let isDir = perms.first == "d"
        // size typically at index 4, but may vary; attempt to find a numeric field
        let sizeField = parts.first { Int64($0) != nil }
        let size = sizeField.flatMap { Int64($0) } ?? 0
        let name = parts.suffix(from: 8).joined(separator: " ")
        let item = RemoteItem(name: name, path: name.hasPrefix("/") ? name : "/\(name)", isDirectory: isDir, size: size)
        items.append(item)
    }
    return items
}

// MARK: - SFTP

final class SFTPClient: Transporting {
    private let connection: Connection
    private let auth: SSHAuthConfig

    init(connection: Connection) {
        self.connection = connection
        self.auth = SSHAuthConfig(host: connection.host, port: connection.port, username: connection.username, privateKeyPath: connection.privateKeyPath)
    }

    func connect() async throws {
        // Use ssh to test connectivity quickly
        let args = SSHExec.sshArgs(auth, extra: ["echo", "ok"])
        let result = try runProcess(launchPath: "/usr/bin/ssh", arguments: args)
        guard result.status == 0 else {
            throw TransferError(message: String(data: result.stderr, encoding: .utf8) ?? "SFTP connect failed")
        }
    }

    func list(directory: RemotePath) async throws -> [RemoteItem] {
        // Prefer using ssh to run ls -la for listing
        let dir = directory.rawValue.isEmpty ? "." : directory.rawValue
        let args = SSHExec.sshArgs(auth, extra: ["ls", "-la", dir])
        let result = try runProcess(launchPath: "/usr/bin/ssh", arguments: args)
        guard result.status == 0 else {
            throw TransferError(message: String(data: result.stderr, encoding: .utf8) ?? "SFTP list failed")
        }
        return parseLsLong(result.stdout)
    }

    func openDirectory(_ item: RemoteItem) async throws -> RemotePath {
        RemotePath(rawValue: item.path)
    }

    func download(item: RemoteItem, to localURL: URL) async throws {
        let remote = "\(auth.username)@\(auth.host):\(item.path)"
        var args = SSHExec.scpArgs(auth, extra: ["-r"]) // -r to handle directories
        args += [remote, localURL.path]
        let result = try runProcess(launchPath: "/usr/bin/scp", arguments: args, timeout: 60 * 60)
        guard result.status == 0 else {
            throw TransferError(message: String(data: result.stderr, encoding: .utf8) ?? "SFTP download failed")
        }
    }

    func upload(localURL: URL, to directory: RemotePath) async throws {
        let remote = "\(auth.username)@\(auth.host):\(directory.rawValue)"
        var args = SSHExec.scpArgs(auth, extra: ["-r"]) // -r to handle directories
        args += [localURL.path, remote]
        let result = try runProcess(launchPath: "/usr/bin/scp", arguments: args, timeout: 60 * 60)
        guard result.status == 0 else {
            throw TransferError(message: String(data: result.stderr, encoding: .utf8) ?? "SFTP upload failed")
        }
    }
}

// MARK: - SCP

final class SCPClient: Transporting {
    private let connection: Connection
    private let auth: SSHAuthConfig

    init(connection: Connection) {
        self.connection = connection
        self.auth = SSHAuthConfig(host: connection.host, port: connection.port, username: connection.username, privateKeyPath: connection.privateKeyPath)
    }

    func connect() async throws {
        let args = SSHExec.sshArgs(auth, extra: ["echo", "ok"])
        let result = try runProcess(launchPath: "/usr/bin/ssh", arguments: args)
        guard result.status == 0 else {
            throw TransferError(message: String(data: result.stderr, encoding: .utf8) ?? "SCP connect failed")
        }
    }

    func list(directory: RemotePath) async throws -> [RemoteItem] {
        // SCP has no native list; use ssh ls
        let dir = directory.rawValue.isEmpty ? "." : directory.rawValue
        let args = SSHExec.sshArgs(auth, extra: ["ls", "-la", dir])
        let result = try runProcess(launchPath: "/usr/bin/ssh", arguments: args)
        guard result.status == 0 else {
            throw TransferError(message: String(data: result.stderr, encoding: .utf8) ?? "SCP list failed")
        }
        return parseLsLong(result.stdout)
    }

    func openDirectory(_ item: RemoteItem) async throws -> RemotePath {
        RemotePath(rawValue: item.path)
    }

    func download(item: RemoteItem, to localURL: URL) async throws {
        let remote = "\(auth.username)@\(auth.host):\(item.path)"
        var args = SSHExec.scpArgs(auth, extra: ["-r"]) // -r to handle directories
        args += [remote, localURL.path]
        let result = try runProcess(launchPath: "/usr/bin/scp", arguments: args, timeout: 60 * 60)
        guard result.status == 0 else {
            throw TransferError(message: String(data: result.stderr, encoding: .utf8) ?? "SCP download failed")
        }
    }

    func upload(localURL: URL, to directory: RemotePath) async throws {
        let remote = "\(auth.username)@\(auth.host):\(directory.rawValue)"
        var args = SSHExec.scpArgs(auth, extra: ["-r"]) // -r to handle directories
        args += [localURL.path, remote]
        let result = try runProcess(launchPath: "/usr/bin/scp", arguments: args, timeout: 60 * 60)
        guard result.status == 0 else {
            throw TransferError(message: String(data: result.stderr, encoding: .utf8) ?? "SCP upload failed")
        }
    }
}
