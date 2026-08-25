//
//  ConnectionManager.swift
//  Shuttler
//
//  Manages connection state for multiple concurrent connections.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class ConnectionManager: ObservableObject {
    static let shared = ConnectionManager()
    
    // Track connection state per connection ID
    @Published private(set) var connectionStates: [UUID: Bool] = [:]
    
    private init() {}
    
    /// Mark a connection as connected
    func setConnected(_ connectionId: UUID, isConnected: Bool) {
        connectionStates[connectionId] = isConnected
        // Remove disconnected entries to keep the dictionary clean
        if !isConnected {
            connectionStates.removeValue(forKey: connectionId)
        }
    }
    
    /// Check if a connection is connected
    func isConnected(_ connectionId: UUID) -> Bool {
        connectionStates[connectionId] ?? false
    }
    
    /// Get all connected connection IDs
    var connectedConnectionIds: Set<UUID> {
        Set(connectionStates.filter { $0.value }.keys)
    }
    
    /// Disconnect a specific connection
    func disconnect(_ connectionId: UUID) {
        connectionStates.removeValue(forKey: connectionId)
    }
    
    /// Disconnect all connections
    func disconnectAll() {
        connectionStates.removeAll()
    }
}

