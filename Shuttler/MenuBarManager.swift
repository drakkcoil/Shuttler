//
//  MenuBarManager.swift
//  Shuttler
//
//  Manages the menu bar status item with transfer status and quick actions
//

#if os(macOS)
import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarManager: ObservableObject {
    static let shared = MenuBarManager()
    
    private var statusItem: NSStatusItem?
    private var transferManager: TransferManager
    private var cancellables = Set<AnyCancellable>()
    @Published private(set) var isEnabled: Bool = false
    
    private init() {
        self.transferManager = TransferManager.shared
    }
    
    func setup() {
        // Don't setup if already enabled
        guard !isEnabled else { return }
        
        // Ensure we're on the main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setup()
            }
            return
        }
        
        // Create status item
        let newStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = newStatusItem.button else {
            NSStatusBar.system.removeStatusItem(newStatusItem)
            return
        }
        
        // Store status item first
        statusItem = newStatusItem
        
        // Configure button
        button.imagePosition = .imageLeading
        button.appearsDisabled = false
        button.bezelStyle = .texturedRounded
        
        // Create menu first
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        // Transfer status section
        let transferStatusItem = NSMenuItem(title: "No active transfers", action: nil, keyEquivalent: "")
        transferStatusItem.isEnabled = false
        menu.addItem(transferStatusItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Show Transfers window
        let showTransfersItem = NSMenuItem(
            title: "Show Transfers",
            action: #selector(showTransfers),
            keyEquivalent: "t"
        )
        showTransfersItem.keyEquivalentModifierMask = [.command, .shift]
        showTransfersItem.target = self
        showTransfersItem.isEnabled = true
        menu.addItem(showTransfersItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // New Connection
        let newConnectionItem = NSMenuItem(
            title: "New Connection",
            action: #selector(newConnection),
            keyEquivalent: "n"
        )
        newConnectionItem.keyEquivalentModifierMask = .command
        newConnectionItem.target = self
        newConnectionItem.isEnabled = true
        menu.addItem(newConnectionItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Show Main Window
        let showWindowItem = NSMenuItem(
            title: "Show Shuttler",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        showWindowItem.target = self
        showWindowItem.isEnabled = true
        menu.addItem(showWindowItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Shuttler",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)
        
        // Set menu before updating icon
        newStatusItem.menu = menu
        
        // Set initial icon
        updateStatusIcon()
        
        // Observe transfer changes - use main thread directly since we're already @MainActor
        transferManager.$transfers
            .sink { [weak self] _ in
                guard let self = self, self.isEnabled else { return }
                self.updateStatusIcon()
                self.updateMenu()
            }
            .store(in: &cancellables)
        
        isEnabled = true
        
        // Debug: Print to confirm setup
        print("✅ Menu bar status item created and enabled")
    }
    
    func teardown() {
        guard isEnabled else { return }
        
        // Ensure we're on the main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.teardown()
            }
            return
        }
        
        // Cancel all subscriptions first
        cancellables.removeAll()
        
        // Clear menu and button before removing status item
        if let statusItem = statusItem {
            // Clear button state first
            statusItem.button?.image = nil
            statusItem.button?.title = ""
            statusItem.button?.isHidden = true
            
            // Clear the menu after a brief delay to allow UI to update
            // This helps minimize scene disconnection warnings
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, let statusItem = self.statusItem else { return }
                
                // Clear menu
                statusItem.menu = nil
                
                // Remove status item after another brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NSStatusBar.system.removeStatusItem(statusItem)
                    self.statusItem = nil
                    self.isEnabled = false
                    print("✅ Menu bar status item removed")
                }
            }
        } else {
            isEnabled = false
        }
    }
    
    private func updateStatusIcon() {
        guard isEnabled, let button = statusItem?.button else { return }
        
        let activeCount = transferManager.activeTransfers.count
        
        if activeCount > 0 {
            // Show transfer icon with badge
            if let image = NSImage(systemSymbolName: "arrow.up.arrow.down.circle.fill", accessibilityDescription: "Active Transfers") {
                image.isTemplate = true
                // Ensure proper size for menu bar
                image.size = NSSize(width: 18, height: 18)
                button.image = image
                button.imagePosition = .imageLeading
                button.title = " \(activeCount)"
            }
        } else {
            // Show simple icon
            if let image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "Shuttler") {
                image.isTemplate = true
                // Ensure proper size for menu bar
                image.size = NSSize(width: 18, height: 18)
                button.image = image
                button.title = ""
            }
        }
        
        // Make sure button is visible
        button.isHidden = false
    }
    
    private func updateMenu() {
        guard isEnabled, let menu = statusItem?.menu, menu.items.count > 0 else { return }
        
        let activeCount = transferManager.activeTransfers.count
        let completedCount = transferManager.transfers.filter { $0.isComplete }.count
        
        // Update transfer status item (first item is the status)
        let statusMenuItem = menu.items[0]
        if activeCount > 0 || completedCount > 0 {
            let statusText: String
            if activeCount > 0 {
                statusText = "\(activeCount) active, \(completedCount) completed"
            } else {
                statusText = "\(completedCount) completed"
            }
            statusMenuItem.title = statusText
        } else {
            statusMenuItem.title = "No active transfers"
        }
    }
    
    @objc private func showTransfers() {
        NotificationCenter.default.post(name: .init("Shuttler.ShowTransfers"), object: nil)
    }
    
    @objc private func newConnection() {
        NotificationCenter.default.post(name: .init("Shuttler.NewConnection"), object: nil)
    }
    
    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isMainWindow || $0.isKeyWindow }) {
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
#endif
