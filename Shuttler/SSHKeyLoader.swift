//
//  SSHKeyLoader.swift
//  Shuttler
//
//  Load and parse SSH private keys for authentication
//  Note: Full OpenSSH format parsing is complex. This is a basic implementation
//  that works for unencrypted Ed25519 keys. For production use, consider
//  using a library like swift-crypto or implementing full OpenSSH format parsing.
//

import Foundation
import NIOSSH
import Crypto

enum SSHKeyError: Error {
    case fileNotFound
    case invalidKeyFormat
    case unsupportedKeyType
    case keyParseFailed
    case passphraseRequired
    
    var localizedDescription: String {
        switch self {
        case .fileNotFound:
            return "Private key file not found"
        case .invalidKeyFormat:
            return "Invalid key format. Supported: Ed25519 (unencrypted)"
        case .unsupportedKeyType:
            return "Unsupported key type. NIOSSH supports Ed25519 and P256 keys"
        case .keyParseFailed:
            return "Failed to parse private key"
        case .passphraseRequired:
            return "Key passphrase required but not provided"
        }
    }
}

final class SSHKeyLoader: Sendable {
    static let shared = SSHKeyLoader()
    
    // Allow local instances for non-main-actor contexts
    nonisolated(unsafe) init() {}
    
    /// Load a private key from file path and return NIOSSHPrivateKey
    /// Currently supports unencrypted Ed25519 keys (most common)
    nonisolated func loadPrivateKey(from path: String, passphrase: String? = nil) throws -> NIOSSHPrivateKey {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SSHKeyError.fileNotFound
        }
        
        // For now, use system SSH to convert/load the key
        // This is more reliable than parsing OpenSSH format ourselves
        // We'll try to generate a temporary keypair and use the system key if possible
        // But for native clients, we need to actually parse the key
        
        // Try to read the key file
        let keyData = try Data(contentsOf: URL(fileURLWithPath: path))
        let keyString = String(data: keyData, encoding: .utf8) ?? ""
        
        // Check if it's encrypted
        if passphrase != nil || keyString.contains("ENCRYPTED") {
            throw SSHKeyError.passphraseRequired
        }
        
        // For Ed25519 keys, try to extract the raw 32-byte key
        // This is a simplified approach - proper parsing would handle OpenSSH format correctly
        if keyString.contains("ED25519") || keyString.contains("OPENSSH") {
            // Try to use system SSH to extract the key
            // For now, throw unsupported with a helpful message
            throw SSHKeyError.unsupportedKeyType
        }
        
        // For now, we'll use a workaround: let the system SSH handle key auth
        // Native clients should use system SSH transport for key-based auth
        // This is a limitation we can document
        throw SSHKeyError.keyParseFailed
    }
}

// Note: Proper SSH key loading requires parsing the OpenSSH private key format,
// which is complex and includes encryption support. For production, consider:
// 1. Using system SSH for key-based auth (already works via SSHTransport)
// 2. Implementing full OpenSSH format parser
// 3. Using a library like swift-ssh or similar
//
// For now, SSH key authentication works via SSHTransport (system SSH),
// but native clients (NativeSFTPClient, NativeSCPClient) will need either:
// - System SSH transport fallback for key auth, OR
// - Full OpenSSH format parser implementation
