//
//  AppDelegate.swift
//  Shuttler
//
//  Handles app lifecycle events, including quit confirmation when connected
//

#if os(macOS)
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var isAnyConnectionActive: Bool = false
    
    override init() {
        super.init()
        AppDelegate.shared = self
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup menu bar if enabled (with a small delay to ensure UI is ready)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let menuBarEnabled = UserDefaults.standard.bool(forKey: "settings.menuBarEnabled")
            if menuBarEnabled {
                MenuBarManager.shared.setup()
            }
        }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isAnyConnectionActive {
            // Show alert asking user if they want to quit
            let alert = NSAlert()
            alert.messageText = "Quit Shuttler?"
            alert.informativeText = "You are currently connected to a server. Quitting will close the connection."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            
            let response = alert.runModal()
            
            if response == .alertFirstButtonReturn {
                // User chose to quit - disconnect all connections and allow quit
                NotificationCenter.default.post(name: NSNotification.Name("Shuttler.ForceDisconnectAll"), object: nil)
                // Mark as not active so next termination attempt succeeds
                isAnyConnectionActive = false
                return .terminateNow
            } else {
                // User cancelled
                return .terminateCancel
            }
        }
        
        return .terminateNow
    }
}
#endif

