//
//  ShuttlerTests.swift
//  ShuttlerTests
//
//  Created by Adam Newman on 12/12/25.
//

import XCTest
@testable import Shuttler

final class ShuttlerTests: XCTestCase {

    func testSSHControlPathUsesRelativeSocketName() throws {
        let auth = SSHAuthConfig(
            host: "example.com",
            port: 22,
            username: "user",
            privateKeyPath: nil,
            password: "password"
        )
        let argumentSets = [
            SSHExec.sshArgs(auth, extra: ["echo", "ok"], allowPrompts: true),
            SSHExec.sftpArgs(auth, extra: ["-b", "/tmp/batch"], allowPrompts: true),
            SSHExec.scpArgs(auth, extra: ["-r"])
        ]
        
        for arguments in argumentSets {
            let controlPaths = arguments.filter { $0.hasPrefix("ControlPath=") }
            XCTAssertEqual(controlPaths, ["ControlPath=shuttler-ssh-%C"])
            XCTAssertFalse(controlPaths[0].contains("/tmp"))
            XCTAssertFalse(controlPaths[0].hasPrefix("ControlPath=/"))
        }
    }
    
    @MainActor
    func testStartingTransferRequestsTransferWindow() throws {
        let expectation = expectation(description: "Show transfers notification")
        let token = NotificationCenter.default.addObserver(
            forName: .init("Shuttler.ShowTransfers"),
            object: nil,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(token)
            TransferManager.shared.transfers.removeAll()
        }
        
        let id = TransferManager.shared.start(
            name: "example.iso",
            direction: .upload,
            totalBytes: 1024,
            remotePath: "/remote/example.iso",
            localPath: "/local/example.iso"
        )
        TransferManager.shared.finish(id: id)
        
        wait(for: [expectation], timeout: 1)
    }

}
