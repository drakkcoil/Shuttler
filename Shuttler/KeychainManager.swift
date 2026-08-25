//
//  KeychainManager.swift
//  Shuttler
//
//  Secure password storage using macOS Keychain
//

import Foundation
import Security

enum KeychainError: Error {
    case itemNotFound
    case unexpectedData
    case unhandledError(status: OSStatus)
    case duplicateItem
    case invalidParameter
}

final class KeychainManager {
    static let shared = KeychainManager()
    
    private let serviceName = "com.shuttler.connections"
    
    private init() {}
    
    /// Store a password in the Keychain for a connection
    func storePassword(_ password: String, forConnectionId connectionId: UUID) throws {
        guard let passwordData = password.data(using: .utf8) else {
            throw KeychainError.invalidParameter
        }
        
        let account = connectionId.uuidString
        
        // Delete existing item if it exists
        deletePassword(forConnectionId: connectionId)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            if status == errSecDuplicateItem {
                throw KeychainError.duplicateItem
            }
            throw KeychainError.unhandledError(status: status)
        }
    }
    
    /// Retrieve a password from the Keychain for a connection
    func retrievePassword(forConnectionId connectionId: UUID) throws -> String? {
        let account = connectionId.uuidString
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status != errSecItemNotFound else {
            return nil
        }
        
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
        
        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        
        return password
    }
    
    /// Delete a password from the Keychain for a connection
    func deletePassword(forConnectionId connectionId: UUID) {
        let account = connectionId.uuidString
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        
        SecItemDelete(query as CFDictionary)
    }
    
    /// Update an existing password in the Keychain
    func updatePassword(_ password: String, forConnectionId connectionId: UUID) throws {
        guard let passwordData = password.data(using: .utf8) else {
            throw KeychainError.invalidParameter
        }
        
        let account = connectionId.uuidString
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        
        let attributes: [String: Any] = [
            kSecValueData as String: passwordData
        ]
        
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
        
        // If item not found, create it
        if status == errSecItemNotFound {
            try storePassword(password, forConnectionId: connectionId)
        }
    }
    
    /// Check if a password exists for a connection
    func hasPassword(forConnectionId connectionId: UUID) -> Bool {
        do {
            return try retrievePassword(forConnectionId: connectionId) != nil
        } catch {
            return false
        }
    }
    
    /// Migrate plain text password from Connection model to Keychain
    func migratePasswordIfNeeded(_ password: String?, forConnectionId connectionId: UUID) {
        guard let password = password, !password.isEmpty else {
            return
        }
        
        // Only migrate if password doesn't already exist in Keychain
        if !hasPassword(forConnectionId: connectionId) {
            do {
                try storePassword(password, forConnectionId: connectionId)
                print("✅ Migrated password to Keychain for connection \(connectionId.uuidString.prefix(8))")
            } catch {
                print("⚠️ Failed to migrate password to Keychain: \(error)")
            }
        }
    }
}

