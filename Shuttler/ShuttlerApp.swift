//
//  ShuttlerApp.swift
//  Shuttler
//
//  Created by Adam Newman on 12/12/25.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct ShuttlerApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif

    @Environment(\.openWindow) var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppBackground()
                NavigationStack {
                    ContentView()
                        .navigationTitle("Shuttler")
                }
            }
            #if os(macOS)
            .onAppear {
                if let app = NSApplication.shared as NSApplication? {
                    app.setActivationPolicy(.regular)
                    app.activate(ignoringOtherApps: true)
                }
                // #region agent log
                agentDebugLogApp(
                    runId: "run1",
                    hypothesisId: "H0",
                    location: "ShuttlerApp.onAppear",
                    message: "app_launch_macOS",
                    data: [:]
                )
                // #endregion
            }
            #endif
            #if os(macOS)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
            #endif
            .tint(AppTheme.tint)
            .task {
                // #region agent log
                agentDebugLogApp(
                    runId: "run1",
                    hypothesisId: "H0",
                    location: "ShuttlerApp.task",
                    message: "app_scene_task_start",
                    data: [:]
                )
                // #endregion
            }
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Shuttler") {
                    openWindow(id: "about")
                }
            }
            
            CommandGroup(replacing: .newItem) {
                Button("New Connection") {
                    NotificationCenter.default.post(name: .init("Shuttler.NewConnection"), object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            
            CommandGroup(after: .newItem) {
                Button("Connect") {
                    NotificationCenter.default.post(name: .init("Shuttler.Connect"), object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])
                
                Button("Disconnect") {
                    NotificationCenter.default.post(name: .init("Shuttler.Disconnect"), object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                
                Divider()
            }
            
            CommandGroup(after: .importExport) {
                Button("Refresh") {
                    NotificationCenter.default.post(name: .init("Shuttler.Refresh"), object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
                
                Divider()
                
                Button("Upload Files…") {
                    NotificationCenter.default.post(name: .init("Shuttler.Upload"), object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command])
                
                Button("Download Selected") {
                    NotificationCenter.default.post(name: .init("Shuttler.Download"), object: nil)
                }
                .keyboardShortcut(.return, modifiers: [])
                
                Button("Select All") {
                    NotificationCenter.default.post(name: .init("Shuttler.SelectAll"), object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command])
                
                Divider()
                
                Button("Show Transfers") {
                    NotificationCenter.default.post(name: .init("Shuttler.ShowTransfers"), object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            
            CommandGroup(after: .toolbar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .init("Shuttler.ToggleSidebar"), object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                
                Divider()
                
                Button("New Tab") {
                    NotificationCenter.default.post(name: .init("Shuttler.NewTab"), object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command])
                
                Button("Close Tab") {
                    NotificationCenter.default.post(name: .init("Shuttler.CloseTab"), object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command])
            }
            
            CommandGroup(replacing: .help) {
                Button("Shuttler Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("?", modifiers: [.shift, .command])
            }
        }
        
        Window("About Shuttler", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        
        Window("Transfers", id: "transfers") {
            TransferWindow()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.bottomTrailing)
        .defaultSize(width: 600, height: 500)
        
        Settings {
            SettingsView()
        }
        
        Window("Help", id: "help") {
            HelpView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultSize(width: 700, height: 700)
    }
}

private func agentDebugLogApp(runId: String, hypothesisId: String, location: String, message: String, data: [String: Any]) {
    let logPath = "/Users/anewman/Library/CloudStorage/OneDrive-sbfoods.com/Documents/XCode Projects/Shuttler/Shuttler/.cursor/debug.log"
    let payload: [String: Any] = [
        "sessionId": "debug-session",
        "runId": runId,
        "hypothesisId": hypothesisId,
        "location": location,
        "message": message,
        "data": data,
        "timestamp": Int(Date().timeIntervalSince1970 * 1000)
    ]
    
    guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
        return
    }
    
    let newline = Data("\n".utf8)
    if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
    }
    
    guard let handle = FileHandle(forWritingAtPath: logPath) else {
        return
    }
    
    handle.seekToEndOfFile()
    handle.write(jsonData)
    handle.write(newline)
    try? handle.close()
}
