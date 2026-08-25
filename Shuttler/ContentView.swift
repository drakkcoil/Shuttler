//
//  ContentView.swift
//  Shuttler
//
//  Created by Adam Newman on 12/12/25.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @StateObject private var store = ConnectionsStore()
    @ObservedObject private var transferManager = TransferManager.shared
    @Environment(\.openWindow) var openWindow
    @State private var selection: UUID?
    @State private var showingNewConnection = false
    @State private var editingConnection: Connection? = nil
    @State private var query = ""
    @AppStorage(AppSettingsKeys.sidebarVisible) private var sidebarVisible: Bool = true
    @AppStorage(AppSettingsKeys.listDensity) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    @State private var triggerNewConnection = UUID()
    @State private var triggerRefresh = UUID()
    @State private var transferWindowVisible = false
    #if DEBUG
    @State private var didRunTransferWindowAutomation = false
    #endif

    @AppStorage(AppSettingsKeys.sortKey) private var sortKeyRaw: String = SortKey.name.rawValue
    @AppStorage(AppSettingsKeys.sortAscending) private var sortAscending: Bool = true
    @AppStorage(AppSettingsKeys.foldersFirst) private var foldersFirst: Bool = true
    
    private var shouldShowTransferIndicator: Bool {
        transferManager.hasActiveTransfers && !transferWindowVisible
    }
    
    private func showTransfersWindow() {
        #if os(macOS)
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue.contains("transfers") == true }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            transferWindowVisible = true
        } else {
            openWindow(id: "transfers")
            transferWindowVisible = true
        }
        #endif
    }
    
    private func checkTransferWindowVisibility() {
        #if os(macOS)
        transferWindowVisible = NSApplication.shared.windows.contains { window in
            window.identifier?.rawValue.contains("transfers") == true && window.isVisible
        }
        #endif
    }
    
    private func runTransferWindowAutomationIfRequested() {
        #if DEBUG
        guard !didRunTransferWindowAutomation,
              ProcessInfo.processInfo.environment["SHUTTLER_UI_TEST_START_TRANSFER"] == "1" else {
            return
        }
        
        didRunTransferWindowAutomation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let id = TransferManager.shared.start(
                name: "Automation Transfer",
                direction: .download,
                totalBytes: 100,
                remotePath: "/automation-transfer",
                localPath: "/tmp/automation-transfer"
            )
            TransferManager.shared.update(id: id, bytesTransferred: 10, totalBytes: 100)
        }
        #endif
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if sidebarVisible {
                    SidebarView(selection: $selection, query: $query, showingNewConnection: $showingNewConnection, editingConnection: $editingConnection, sidebarVisible: $sidebarVisible)
                        .environmentObject(store)
                        .searchable(text: $query, prompt: "Search Connections")
                        .frame(width: 248)
                        .background(.thinMaterial)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    
                    Divider()
                }
                
                Group {
                    if let id = selection, let connection = store.connection(id: id) {
                        VStack(spacing: 0) {
                            mainRibbon
                            
                            RemoteBrowserView(connection: connection, sidebarVisible: $sidebarVisible)
                                .environmentObject(store)
                                .id(connection.id)
                        }
                    } else {
                        WelcomeView(showingNewConnection: $showingNewConnection, selection: $selection)
                            .environmentObject(store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.easeInOut(duration: 0.22), value: sidebarVisible)
            
            if !sidebarVisible {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        sidebarVisible = true
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Show Sidebar")
                .padding(10)
                .transition(.opacity)
            }
        }
        .sheet(item: $editingConnection) { connection in
            NewConnectionView(connection: connection) { updatedConn in
                store.update(updatedConn)
                editingConnection = nil
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showingNewConnection) {
            if editingConnection == nil {
                NewConnectionView(connection: nil) { conn in
                    store.add(conn)
                    selection = conn.id
                    showingNewConnection = false
                }
                .environmentObject(store)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.NewConnection"))) { _ in
            showingNewConnection = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.ShowTransfers"))) { _ in
            showTransfersWindow()
        }
        .onAppear {
            checkTransferWindowVisibility()
            runTransferWindowAutomationIfRequested()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.TransferWindowDidAppear"))) { _ in
            transferWindowVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.TransferWindowDidDisappear"))) { _ in
            transferWindowVisible = false
        }
        .onChange(of: transferManager.activeTransfers.count) { _, _ in
            // If transfers change, re-check window visibility
            checkTransferWindowVisibility()
        }
        .navigationTitle("Shuttler")
    }
    
    private var mainRibbon: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 800
            let isVeryCompact = geometry.size.width < 600
            
            HStack(spacing: isVeryCompact ? AppTheme.Spacing.s : AppTheme.Spacing.l) {
                HStack(spacing: AppTheme.Spacing.s) {
                    Button {
                        NotificationCenter.default.post(name: .init("Shuttler.Refresh"), object: nil)
                    } label: {
                        if isCompact {
                            Image(systemName: "arrow.clockwise")
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    
                    Button {
                        NotificationCenter.default.post(name: .init("Shuttler.NewConnection"), object: nil)
                    } label: {
                        if isCompact {
                            Image(systemName: "plus")
                        } else {
                            Label("New", systemImage: "plus")
                        }
                    }
                }

                if !isVeryCompact {
                    Divider().frame(height: 20)
                }

                HStack(spacing: AppTheme.Spacing.s) {
                    Button {
                        NotificationCenter.default.post(name: .init("Shuttler.Download"), object: nil)
                    } label: {
                        if isCompact {
                            Image(systemName: "arrow.down.circle")
                        } else {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                    }
                    
                    Button {
                        NotificationCenter.default.post(name: .init("Shuttler.Upload"), object: nil)
                    } label: {
                        if isCompact {
                            Image(systemName: "arrow.up.circle")
                        } else {
                            Label("Upload", systemImage: "arrow.up.circle")
                        }
                    }
                }

                if !isVeryCompact {
                    Divider().frame(height: 20)
                }

                if !isVeryCompact {
                    HStack(spacing: AppTheme.Spacing.s) {
                        Picker("Density", selection: $listDensityRaw) {
                            Text("Comfortable").tag(ListDensity.comfortable.rawValue)
                            Text("Compact").tag(ListDensity.compact.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: isCompact ? 140 : nil)

                        Picker("Sort", selection: $sortKeyRaw) {
                            Text("Name").tag(SortKey.name.rawValue)
                            Text("Size").tag(SortKey.size.rawValue)
                            Text("Kind").tag(SortKey.kind.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: isCompact ? 120 : nil)

                        if !isCompact {
                            Toggle(isOn: $sortAscending) {
                                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                            }
                            Toggle("Folders first", isOn: $foldersFirst)
                        }
                    }
                    
                    Divider().frame(height: 20)
                    
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            sidebarVisible.toggle()
                        }
                    } label: {
                        if isCompact {
                            Image(systemName: sidebarVisible ? "sidebar.leading" : "sidebar.left")
                        } else {
                            Label(sidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: sidebarVisible ? "sidebar.leading" : "sidebar.left")
                        }
                    }
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            sidebarVisible.toggle()
                        }
                    } label: {
                        Image(systemName: sidebarVisible ? "sidebar.leading" : "sidebar.left")
                    }
                    
                    Menu {
                        Picker("Density", selection: $listDensityRaw) {
                            Text("Comfortable").tag(ListDensity.comfortable.rawValue)
                            Text("Compact").tag(ListDensity.compact.rawValue)
                        }
                        
                        Picker("Sort", selection: $sortKeyRaw) {
                            Text("Name").tag(SortKey.name.rawValue)
                            Text("Size").tag(SortKey.size.rawValue)
                            Text("Kind").tag(SortKey.kind.rawValue)
                        }
                        
                        Toggle(isOn: $sortAscending) {
                            Text(sortAscending ? "Ascending" : "Descending")
                        }
                        
                        Toggle("Folders first", isOn: $foldersFirst)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                Spacer()
                
                if shouldShowTransferIndicator {
                    transferIndicatorBadge
                }
            }
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.xs)
        }
        .frame(height: 44)
        .background(.bar)
    }
    
    private var transferIndicatorBadge: some View {
        Button {
            showTransfersWindow()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(transferManager.activeTransfers.count)")
                    .font(.system(size: 12, weight: .semibold))
                if transferManager.activeTransfers.count == 1,
                   let transfer = transferManager.activeTransfers.first {
                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(transfer.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 150)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                ZStack {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.15))
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                }
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .help("\(transferManager.activeTransfers.count) active transfer\(transferManager.activeTransfers.count == 1 ? "" : "s"). Click to view.")
        .transition(.scale.combined(with: .opacity))
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: ConnectionsStore
    @StateObject private var connectionManager = ConnectionManager.shared
    @Binding var selection: UUID?
    @Binding var query: String
    @Binding var showingNewConnection: Bool
    @Binding var editingConnection: Connection?
    @Binding var sidebarVisible: Bool

    @AppStorage("sidebar.favoritesCollapsed") private var favoritesCollapsed = false
    @AppStorage("sidebar.connectionsCollapsed") private var connectionsCollapsed = false
    @AppStorage(AppSettingsKeys.listDensity) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    private var favoritesExpandedBinding: Binding<Bool> {
        Binding(
            get: { !favoritesCollapsed },
            set: { newValue in favoritesCollapsed = !newValue }
        )
    }

    private var connectionsExpandedBinding: Binding<Bool> {
        Binding(
            get: { !connectionsCollapsed },
            set: { newValue in connectionsCollapsed = !newValue }
        )
    }

    var body: some View {
        let filtered = store.connections.filter {
            query.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.host.localizedCaseInsensitiveContains(query) ||
            $0.username.localizedCaseInsensitiveContains(query)
        }
        let favorites = filtered.filter { $0.isFavorite }
        let others = filtered.filter { !$0.isFavorite }

        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Connections", systemImage: "rectangle.connected.to.line.below")
                        .font(.system(size: 15, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                    Text("\(filtered.count) saved")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    showingNewConnection = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(.quaternary.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .help("New Connection")
                
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        sidebarVisible = false
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Sidebar")
            }
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.s)
            .background(.bar)
            
            VStack {
                if filtered.isEmpty {
                    VStack(spacing: AppTheme.Spacing.s) {
                        Image(systemName: query.isEmpty ? "plus.circle" : "magnifyingglass")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text(query.isEmpty ? "No Connections" : "No Matches")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if query.isEmpty {
                            Button {
                                showingNewConnection = true
                            } label: {
                                Label("New Connection", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(AppTheme.Spacing.l)
                } else {
                    List {
                        if !favorites.isEmpty {
                            Section {
                                ForEach(favorites, id: \.id) { conn in
                                    connectionRow(conn)
                                }
                            } header: {
                                sectionHeader("Favorites", count: favorites.count)
                            }
                        }
                        
                        if !others.isEmpty {
                            Section {
                                ForEach(others, id: \.id) { conn in
                                    connectionRow(conn)
                                        .onDrag { NSItemProvider(object: conn.id.uuidString as NSString) }
                                }
                                .onMove { indices, newOffset in
                                    store.moveConnections(indices: indices, to: newOffset)
                                }
                            } header: {
                                sectionHeader("Connections", count: others.count)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 220)
        }
        .frame(minWidth: 220)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingNewConnection = true
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
                
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        sidebarVisible = false
                    }
                } label: {
                    Label("Close Sidebar", systemImage: "xmark")
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }

    @ViewBuilder
    private func connectionRow(_ conn: Connection) -> some View {
        let isConnected = connectionManager.isConnected(conn.id)
        
        HStack(spacing: AppTheme.Spacing.s) {
            Image(systemName: conn.protocolType.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(conn.protocolType.tint)
                .frame(width: 28, height: 28)
                .background(conn.protocolType.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(conn.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Circle()
                        .fill(isConnected ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                        .help(isConnected ? "Connected" : "Disconnected")
                }
                Text("\(conn.username)@\(conn.host):\(conn.port)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            Button {
                store.toggleFavorite(conn)
            } label: {
                Image(systemName: conn.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(conn.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(conn.isFavorite ? "Unfavorite" : "Favorite")
        }
        .padding(.vertical, (ListDensity(rawValue: listDensityRaw) ?? .comfortable) == .comfortable ? 6 : 2)
        .padding(.horizontal, 6)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .background((selection == conn.id) ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            // Single click: select connection
            selection = conn.id
        }
        .onTapGesture(count: 2) {
            // Double-click: select and connect (don't auto-close sidebar)
            selection = conn.id
            // Trigger connection by posting notification
            NotificationCenter.default.post(name: .init("Shuttler.Connect"), object: conn.id)
        }
        .contextMenu {
            Button {
                // Get a fresh copy of the connection from the store to ensure we have all the latest data
                if let freshConn = store.connection(id: conn.id) {
                    editingConnection = freshConn
                    print("Setting editingConnection: '\(freshConn.name)' with host '\(freshConn.host)' and username '\(freshConn.username)'")
                }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            
            Button(conn.isFavorite ? "Unfavorite" : "Favorite") { store.toggleFavorite(conn) }
            
            Divider()
            
            Button {
                // Close sidebar from context menu
                withAnimation(.easeInOut(duration: 0.25)) {
                    sidebarVisible = false
                }
            } label: {
                Label("Close Sidebar", systemImage: "xmark")
            }
            
            Button(role: .destructive) { 
                handleConnectionDelete(conn: conn)
            } label: { 
                Label("Delete", systemImage: "trash") 
            }
        }
    }
    
    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 8)
    }
    
    #if os(macOS)
    private func handleConnectionDelete(conn: Connection) {
        let alert = NSAlert()
        alert.messageText = "Delete Connection?"
        alert.informativeText = "Are you sure you want to delete the connection \"\(conn.name)\"? This action cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            store.remove(conn)
        }
    }
    #endif
}

struct WelcomeView: View {
    @Binding var showingNewConnection: Bool
    @EnvironmentObject var store: ConnectionsStore
    @Binding var selection: UUID?
    
    var body: some View {
        let recentConnections = store.getRecentConnections(maxCount: 5)
        
        ScrollView {
            VStack(spacing: AppTheme.Spacing.l) {
                VStack(spacing: AppTheme.Spacing.m) {
                    Image(systemName: store.connections.isEmpty ? "plus.circle" : "rectangle.connected.to.line.below")
                        .font(.system(size: 46, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .frame(width: 72, height: 72)
                        .background(.quaternary.opacity(0.28), in: Circle())
                    
                    VStack(spacing: AppTheme.Spacing.xs) {
                        Text(store.connections.isEmpty ? "Add a Connection" : "Choose a Connection")
                            .font(.system(size: 27, weight: .semibold))
                        Text(store.connections.isEmpty ? "Set up your first server." : "No connection selected.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                }
                
                Button {
                    showingNewConnection = true
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                if !recentConnections.isEmpty {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                        Text("Recently Connected")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        
                        VStack(spacing: AppTheme.Spacing.xs) {
                            ForEach(recentConnections, id: \.id) { conn in
                                Button {
                                    selection = conn.id
                                } label: {
                                    HStack {
                                        Image(systemName: conn.protocolType.iconName)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(conn.protocolType.tint)
                                            .frame(width: 28, height: 28)
                                            .background(conn.protocolType.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(conn.name)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(.primary)
                                            Text("\(conn.protocolType.displayName) • \(conn.host)")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                        
                                        Spacer()
                                        
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, AppTheme.Spacing.m)
                                    .padding(.vertical, AppTheme.Spacing.s)
                                    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: 440)
                }
            }
            .padding(AppTheme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS)
// Custom view to properly handle mouse clicks with modifiers in List views
struct ClickableRowView: NSViewRepresentable {
    let onCommandClick: () -> Void
    let onShiftClick: () -> Void
    let onRegularClick: () -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = ClickableNSView()
        view.onCommandClick = onCommandClick
        view.onShiftClick = onShiftClick
        view.onRegularClick = onRegularClick
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let clickableView = nsView as? ClickableNSView {
            clickableView.onCommandClick = onCommandClick
            clickableView.onShiftClick = onShiftClick
            clickableView.onRegularClick = onRegularClick
        }
    }
}

class ClickableNSView: NSView {
    var onCommandClick: (() -> Void)?
    var onShiftClick: (() -> Void)?
    var onRegularClick: (() -> Void)?
    
    override func mouseDown(with event: NSEvent) {
        // Don't call super - we want to handle this ourselves
        let commandPressed = event.modifierFlags.contains(.command)
        let shiftPressed = event.modifierFlags.contains(.shift)
        
        if commandPressed {
            onCommandClick?()
        } else if shiftPressed {
            onShiftClick?()
        } else {
            onRegularClick?()
        }
    }
    
    override var acceptsFirstResponder: Bool {
        return false
    }
    
    override var mouseDownCanMoveWindow: Bool {
        return false
    }
}
#endif

struct FeatureBadge: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.tint)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

struct NewConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Connection
    @AppStorage(AppSettingsKeys.sshKeyPath) private var defaultSSHKeyPath: String = ""
    var onSave: (Connection) -> Void
    private let isEditing: Bool

    init(connection: Connection? = nil, onSave: @escaping (Connection) -> Void) {
        // Initialize draft with the provided connection or a new example
        // Since Connection is a struct, we can directly assign it
        if let conn = connection {
            // Create a copy to ensure we have all the values
            let copy = conn
            self._draft = State(initialValue: copy)
            self.isEditing = true
            print("NewConnectionView init: Editing connection '\(copy.name)' with host '\(copy.host)' and username '\(copy.username)'")
        } else {
            var example = Connection.example()
            example.useSystemSSHTransport = true
            self._draft = State(initialValue: example)
            self.isEditing = false
            print("NewConnectionView init: Creating new connection")
        }
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $draft.name)
                    Picker("Protocol", selection: $draft.protocolType) {
                        ForEach(ProtocolType.allCases) { proto in
                            Text(proto.displayName).tag(proto)
                        }
                    }
                    .onChange(of: draft.protocolType) { oldValue, newValue in
                        draft.port = newValue.defaultPort
                        draft.useSystemSSHTransport = newValue == .sftp || newValue == .scp
                        if newValue == .ftp {
                            draft.usesKeyAuth = false
                            draft.privateKeyPath = nil
                        }
                    }
                    TextField("Host", text: $draft.host)
                    TextField("Port", value: $draft.port, formatter: NumberFormatter())
                    TextField("Username", text: $draft.username)
                }
                
                Section("Authentication") {
                    if draft.protocolType == .sftp || draft.protocolType == .scp {
                        Toggle("SSH key", isOn: Binding(
                            get: { draft.usesKeyAuth },
                            set: { newValue in
                                draft.usesKeyAuth = newValue
                                if newValue {
                                    fillSuggestedSSHKeyIfNeeded()
                                    draft.useSystemSSHTransport = true
                                }
                            }
                        ))
                        
                        if draft.usesKeyAuth {
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                HStack(spacing: AppTheme.Spacing.s) {
                                    TextField("Private key", text: Binding<String>(
                                        get: { draft.privateKeyPath ?? "" },
                                        set: { draft.privateKeyPath = $0.isEmpty ? nil : $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    
                                    Button {
                                        choosePrivateKey()
                                    } label: {
                                        Label("Choose", systemImage: "folder")
                                    }
                                }
                                
                                sshKeyStatusView
                                
                                HStack(spacing: AppTheme.Spacing.s) {
                                    Button {
                                        fillSuggestedSSHKeyIfNeeded(force: true)
                                    } label: {
                                        Label("Use Suggested Key", systemImage: "wand.and.stars")
                                    }
                                    .disabled(suggestedSSHKeyPath == nil)
                                    
                                    if let keyPath = draft.privateKeyPath, !keyPath.isEmpty {
                                        Button {
                                            revealSSHKey(path: keyPath)
                                        } label: {
                                            Label("Reveal", systemImage: "magnifyingglass")
                                        }
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        
                        SecureField("Password or passphrase (optional)", text: Binding<String>(
                            get: { draft.getPassword() ?? "" },
                            set: { setDraftPassword($0) }
                        ))
                    } else {
                        SecureField("Password", text: Binding<String>(
                            get: { draft.getPassword() ?? "" },
                            set: { setDraftPassword($0) }
                        ))
                    }
                }
                
                Section("Options") {
                    TextField("Starting directory", text: Binding<String>(
                        get: { draft.startingDirectory ?? "" },
                        set: { draft.startingDirectory = $0.isEmpty ? nil : $0 }
                    ))
                    .help("Optional: Directory to start in when connecting.")
                    
                    if draft.protocolType == .sftp || draft.protocolType == .scp {
                        Toggle("MFA-compatible SSH mode", isOn: $draft.useSystemSSHTransport)
                            .help("Uses macOS OpenSSH so keyboard-interactive MFA prompts such as Cisco Duo can be answered in Shuttler.")
                            .disabled(draft.usesKeyAuth)
                        
                        Text(draft.usesKeyAuth ? "Required for SSH keys, passphrases, and agent-backed authentication." : "Recommended for SSH keys, Duo, push approval, and passcode prompts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("FTP uses the server's username/password flow. If your FTP server asks for an account code or one-time response, Shuttler will show a prompt during connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Connection" : "New Connection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Store password in Keychain before saving
                        if let password = draft.password, !password.isEmpty {
                            do {
                                try KeychainManager.shared.storePassword(password, forConnectionId: draft.id)
                            } catch {
                                print("⚠️ Failed to store password in Keychain: \(error)")
                            }
                            // Clear password from draft before saving (it's in Keychain now)
                            var savedDraft = draft
                            savedDraft.password = nil
                            onSave(savedDraft)
                        } else {
                            onSave(draft)
                        }
                        dismiss()
                    }.disabled(draft.name.isEmpty || draft.host.isEmpty || draft.username.isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
        .onAppear {
            if draft.usesKeyAuth {
                draft.useSystemSSHTransport = true
            }
        }
    }
    
    @ViewBuilder
    private var sshKeyStatusView: some View {
        if let path = draft.privateKeyPath, !path.isEmpty {
            if FileManager.default.fileExists(atPath: expandedPath(path)) {
                Label((path as NSString).lastPathComponent, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("Key file not found", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else {
            Label("Choose a private key from ~/.ssh or your preferred key folder.", systemImage: "key")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    private var suggestedSSHKeyPath: String? {
        if !defaultSSHKeyPath.isEmpty, FileManager.default.fileExists(atPath: expandedPath(defaultSSHKeyPath)) {
            return expandedPath(defaultSSHKeyPath)
        }
        
        let sshDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        let candidates = ["id_ed25519", "id_ecdsa", "id_rsa"]
        return candidates
            .map { sshDirectory.appendingPathComponent($0).path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }
    
    private func setDraftPassword(_ newValue: String) {
        draft.password = newValue.isEmpty ? nil : newValue
        if !newValue.isEmpty {
            do {
                try KeychainManager.shared.storePassword(newValue, forConnectionId: draft.id)
            } catch {
                print("Failed to store password in Keychain: \(error)")
            }
        }
    }
    
    private func fillSuggestedSSHKeyIfNeeded(force: Bool = false) {
        guard force || draft.privateKeyPath?.isEmpty != false else { return }
        draft.privateKeyPath = suggestedSSHKeyPath
    }
    
    private func choosePrivateKey() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.prompt = "Choose Key"
        panel.directoryURL = suggestedSSHKeyPath
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            draft.privateKeyPath = url.path
            defaultSSHKeyPath = url.path
            draft.usesKeyAuth = true
            draft.useSystemSSHTransport = true
        }
        #endif
    }
    
    private func revealSSHKey(path: String) {
        #if os(macOS)
        NSWorkspace.shared.selectFile(expandedPath(path), inFileViewerRootedAtPath: URL(fileURLWithPath: expandedPath(path)).deletingLastPathComponent().path)
        #endif
    }
    
    private func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}

// BrowserTab represents a tab in the tabbed browsing interface
struct BrowserTab: Identifiable {
    let id: UUID
    var name: String
    var path: String
    let connectionId: UUID
    
    init(id: UUID = UUID(), name: String, path: String, connectionId: UUID) {
        self.id = id
        self.name = name
        self.path = path
        self.connectionId = connectionId
    }
}

// RemoteBrowserView supports single selection for downloads
struct RemoteBrowserView: View {
    let connection: Connection
    @Binding var sidebarVisible: Bool
    @EnvironmentObject var store: ConnectionsStore
    @Environment(\.openWindow) var openWindow
    @StateObject private var browserVM: RemoteBrowserViewModel
    @StateObject private var connectionManager = ConnectionManager.shared
    @State private var errorMessage: String?
    @State private var showingUploadPicker = false
    @State private var showingDownloadOptions = false
    @State private var pendingDownloadItems: [RemoteItem] = []
    @State private var showingConnectionProgress = false
    @State private var showingUploadConflict = false
    @State private var uploadConflictResolution: (localURL: URL, existingItem: RemoteItem)?
    @State private var uploadConflictDestination: RemotePath?
    @State private var showingPasswordPrompt = false
    @State private var showingRenameDialog = false
    @State private var renameText = ""
    @State private var showingNewFolderDialog = false
    @State private var newFolderName = ""
    @State private var showingMoveCopyDialog = false
    @State private var moveCopyDestinationPath = ""
    @State private var moveCopyDialogOperation: ClipboardOperation = .copy
    @State private var moveCopyDialogItems: [RemoteItem] = []
    @State private var showingDisconnectConfirmation = false
    @State private var currentConnection: Connection

    @State private var selectedItem: RemoteItem? = nil
    @State private var selectedItems: Set<RemoteItem> = []
    @State private var lastSelectedIndex: Int? = nil
    @State private var hoveredItemPath: String? = nil
    @State private var pathComponents: [String] = ["/"]
    @State private var searchText = ""
    @State private var isDropTargeted = false
    @FocusState private var isSearchFocused: Bool
    
    // Clipboard for copy/paste operations
    @State private var clipboardItems: [RemoteItem] = []
    @State private var clipboardOperation: ClipboardOperation = .copy // .copy or .cut
    
    // Permissions editing
    @State private var showingPermissionsDialog = false
    @State private var permissionsText = ""
    @State private var itemForPermissions: RemoteItem? = nil
    
    enum ClipboardOperation {
        case copy, cut
    }
    
    // Tab management
    @State private var tabs: [BrowserTab] = []
    @State private var activeTabId: UUID?
    @AppStorage(AppSettingsKeys.listDensity) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    @AppStorage(AppSettingsKeys.sortKey) private var sortKeyRaw: String = SortKey.name.rawValue
    @AppStorage(AppSettingsKeys.sortAscending) private var sortAscending: Bool = true
    @AppStorage(AppSettingsKeys.foldersFirst) private var foldersFirst: Bool = true
    @AppStorage(AppSettingsKeys.defaultDownloadFolder) private var defaultDownloadFolder: String = NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true).first ?? "~/Downloads"

    init(connection: Connection, sidebarVisible: Binding<Bool>) {
        self.connection = connection
        _sidebarVisible = sidebarVisible
        _currentConnection = State(initialValue: connection)
        _browserVM = StateObject(wrappedValue: RemoteBrowserViewModel(connection: connection))
    }
    
    private var isShowingError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    var body: some View {
        viewModifiersPart1
    }
    
    private var baseView: some View {
        VStack(spacing: 0) {
            headerView
            if !tabs.isEmpty {
                tabBarView
            }
            // Show the breadcrumb / path bar below the tabs
            pathView
            fileListView
        }
        .focusable()
        .focusEffectDisabled()
    }
    
    private var keyboardShortcutsPart1: some View {
        baseView
            .onKeyPress { keyPress in
                if keyPress.key == .escape {
                    if !searchText.isEmpty {
                        searchText = ""
                        return .handled
                    }
                }
                return .ignored
            }
            .onKeyPress { keyPress in
                if keyPress.key == .return && keyPress.modifiers.contains(.command) {
                    if let item = selectedItem, item.isDirectory {
                        Task {
                            do {
                                try await browserVM.open(item)
                                let currentDirectory = browserVM.currentDirectory
                                let comps = currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                                pathComponents = comps.isEmpty ? ["/"] : ["/"] + comps
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                        return .handled
                    }
                }
                if keyPress.characters == "f" && keyPress.modifiers.contains(.command) {
                    isSearchFocused = true
                    return .handled
                }
                if keyPress.characters == "a" && keyPress.modifiers.contains(.command) {
                    handleSelectAll()
                    return .handled
                }
                if keyPress.characters == "n" && keyPress.modifiers.contains(.command) {
                    if browserVM.isConnected {
                        newFolderName = ""
                        showingNewFolderDialog = true
                        return .handled
                    }
                }
                return .ignored
            }
    }
    
    private var keyboardShortcutsPart2: some View {
        keyboardShortcutsPart1
            .onKeyPress { keyPress in
                if keyPress.key == .delete {
                    if !selectedItems.isEmpty || selectedItem != nil {
                        handleDeleteSelected()
                        return .handled
                    }
                }
                if keyPress.key == .upArrow {
                    navigateItems(direction: .up)
                    return .handled
                }
                if keyPress.key == .downArrow {
                    navigateItems(direction: .down)
                    return .handled
                }
                return .ignored
            }
    }
    
    private var keyboardShortcutsPart3: some View {
        keyboardShortcutsPart2
            .onKeyPress { keyPress in
                if keyPress.characters == "c" && keyPress.modifiers.contains(.command) {
                    handleCopy()
                    return .handled
                }
                if keyPress.characters == "x" && keyPress.modifiers.contains(.command) {
                    handleCut()
                    return .handled
                }
                if keyPress.characters == "v" && keyPress.modifiers.contains(.command) {
                    if !clipboardItems.isEmpty {
                        handleContextMenuPaste()
                        return .handled
                    }
                }
                if keyPress.characters == "d" && keyPress.modifiers.contains(.command) {
                    if let item = selectedItem {
                        handleContextMenuDuplicate(item: item)
                        return .handled
                    }
                }
                return .ignored
            }
    }
    
    private var viewModifiersPart1: some View {
        keyboardShortcutsPart3
            .overlay(alignment: .topTrailing) {
                ToastContainer()
            }
            .onChange(of: errorMessage) { oldValue, newValue in
                if let message = newValue {
                    ToastManager.shared.show(message, type: .error)
                    errorMessage = nil // Clear after showing toast
                }
            }
            .alert("File Already Exists", isPresented: $showingUploadConflict) {
                if let conflict = uploadConflictResolution {
                    Button("Overwrite", role: .destructive) {
                        Task {
                            do {
                                try await browserVM.uploadWithResolution(conflict.localURL, overwrite: true, to: uploadConflictDestination)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                        uploadConflictResolution = nil
                        uploadConflictDestination = nil
                    }
                    Button("Keep Both") {
                        Task {
                            do {
                                try await browserVM.uploadWithResolution(conflict.localURL, overwrite: false, to: uploadConflictDestination)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                        uploadConflictResolution = nil
                        uploadConflictDestination = nil
                    }
                    Button("Cancel", role: .cancel) {
                        uploadConflictResolution = nil
                        uploadConflictDestination = nil
                    }
                }
            } message: {
                if let conflict = uploadConflictResolution {
                    Text("A file named '\(conflict.existingItem.name)' already exists on the server. What would you like to do?")
                }
            }
            .alert("Rename", isPresented: $showingRenameDialog) {
                TextField("New name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    renameText = ""
                }
                Button("Rename") {
                    guard let item = selectedItem, !renameText.isEmpty else { return }
                    Task {
                        do {
                            try await browserVM.rename(item, to: renameText)
                            renameText = ""
                        } catch {
                            errorMessage = "Failed to rename: \(error.localizedDescription)"
                        }
                    }
                }
            } message: {
                Text("Enter new name for \(selectedItem?.name ?? "item")")
            }
            .alert(moveCopyDialogOperation == .cut ? "Move Items" : "Copy Items", isPresented: $showingMoveCopyDialog) {
                TextField("Remote destination path", text: $moveCopyDestinationPath)
                Button("Cancel", role: .cancel) {
                    moveCopyDialogItems = []
                    moveCopyDestinationPath = ""
                }
                Button(moveCopyDialogOperation == .cut ? "Move" : "Copy") {
                    let destination = RemotePath(rawValue: moveCopyDestinationPath.trimmingCharacters(in: .whitespacesAndNewlines))
                    let items = moveCopyDialogItems
                    let operation = moveCopyDialogOperation
                    Task {
                        await performRemoteTransfer(items: items, to: destination, operation: operation)
                    }
                }
            } message: {
                Text("Enter the remote folder path where the selected items should go.")
            }
            .onChange(of: connection.id) { oldValue, newValue in
                // Update when connection changes
                currentConnection = connection
                browserVM.updateConnection(connection)
                // Restore connection if needed (this will reconnect if ConnectionManager says it should be connected)
                Task {
                    await browserVM.restoreConnectionIfNeeded()
                }
            }
            .onChange(of: browserVM.currentDirectory) { oldValue, newValue in
                // Update path components when directory changes
                // Always include "/" as the first element to represent root
                let comps = newValue.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                if comps.isEmpty {
                    pathComponents = ["/"]
                } else {
                    // Prepend "/" to show root, then all path components
                    pathComponents = ["/"] + comps
                }
                
                // Update or create tab for current directory
                updateTabForCurrentDirectory()
            }
            .onAppear {
                // Restore connection if needed when view appears
                Task {
                    await browserVM.restoreConnectionIfNeeded()
                }
                // Initialize path components
                // Always include "/" as the first element to represent root
                let comps = browserVM.currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                if comps.isEmpty {
                    pathComponents = ["/"]
                } else {
                    // Prepend "/" to show root, then all path components
                    pathComponents = ["/"] + comps
                }
                
                // Create initial tab
                if tabs.isEmpty {
                    let initialTab = BrowserTab(
                        name: connection.name,
                        path: browserVM.currentDirectory.rawValue,
                        connectionId: connection.id
                    )
                    tabs = [initialTab]
                    activeTabId = initialTab.id
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.Connect"))) { notification in
                // Handle connect notification - connect if this is the selected connection
                if let connectionId = notification.object as? UUID, connectionId == connection.id {
                    if !browserVM.isConnected {
                        showingConnectionProgress = true
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.Disconnect"))) { _ in
                // Handle disconnect notification - show confirmation
                if browserVM.isConnected {
                    showingDisconnectConfirmation = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.ForceDisconnectAll"))) { _ in
                // Force disconnect when app is quitting
                if browserVM.isConnected {
                    browserVM.disconnect()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.ToggleSidebar"))) { _ in
                // Toggle sidebar from View menu
                withAnimation(.easeInOut(duration: 0.25)) {
                    sidebarVisible.toggle()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.FileClick"))) { notification in
                // Handle file click from drag view
                if let clickedItem = notification.object as? RemoteItem {
                    // Find the item in the current items and select it
                    if let index = browserVM.items.firstIndex(where: { $0.path == clickedItem.path }) {
                        handleItemTap(item: clickedItem, index: index, items: browserVM.items)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.FileOpen"))) { notification in
                if let item = notification.object as? RemoteItem {
                    handleItemDoubleTap(item: item)
                }
            }
            .sheet(isPresented: $showingPasswordPrompt) {
                PasswordPromptView(connection: currentConnection, isPresented: $showingPasswordPrompt) { password, savePassword in
                    // Update connection with password
                    var updatedConnection = currentConnection
                    if savePassword {
                        updatedConnection.setPassword(password)
                    } else {
                        updatedConnection.password = password // Temporary, in-memory only
                    }
                    currentConnection = updatedConnection
                    browserVM.updateConnection(updatedConnection)
                    
                    // Save to store if user requested
                    if savePassword {
                        store.update(updatedConnection)
                    }
                    
                    // Now show connection progress
                    showingConnectionProgress = true
                }
            }
            .sheet(isPresented: $showingConnectionProgress) {
                ConnectionProgressView(connection: currentConnection, isPresented: $showingConnectionProgress) { outputHandler in
                    try await browserVM.connect(outputHandler: outputHandler)
                    if browserVM.connection.useSystemSSHTransport != currentConnection.useSystemSSHTransport {
                        currentConnection = browserVM.connection
                        store.update(browserVM.connection)
                    }
                    // Record successful connection
                    store.recordConnection(connectionId: currentConnection.id)
                    let currentDirectory = browserVM.currentDirectory
                    let comps = currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                    pathComponents = comps.isEmpty ? ["/"] : ["/"] + comps
                }
            }
            .sheet(isPresented: $showingDownloadOptions) {
                DownloadOptionsView(items: pendingDownloadItems, defaultFolder: expandedPath(defaultDownloadFolder)) { destination, revealWhenDone in
                    showingDownloadOptions = false
                    let items = pendingDownloadItems
                    pendingDownloadItems = []
                    Task {
                        await performDownloads(items: items, to: destination, revealWhenDone: revealWhenDone)
                    }
                } onCancel: {
                    showingDownloadOptions = false
                    pendingDownloadItems = []
                }
            }
            .alert("Change Permissions", isPresented: $showingPermissionsDialog) {
                TextField("Permissions (e.g., 755)", text: $permissionsText)
                Button("Cancel", role: .cancel) {
                    permissionsText = ""
                    itemForPermissions = nil
                }
                Button("Change") {
                    guard let item = itemForPermissions, !permissionsText.isEmpty else { return }
                    Task {
                        do {
                            try await browserVM.changePermissions(item: item, permissions: permissionsText)
                            try await browserVM.refresh()
                            permissionsText = ""
                            itemForPermissions = nil
                        } catch {
                            errorMessage = "Failed to change permissions: \(error.localizedDescription)"
                        }
                    }
                }
            } message: {
                if let item = itemForPermissions {
                    Text("Enter new permissions for \(item.name) (e.g., 755, 644, 777)")
                }
            }
            .onChange(of: showingNewFolderDialog) { oldValue, newValue in
                if newValue {
                    #if os(macOS)
                    let alert = NSAlert()
                    alert.messageText = "New Folder"
                    alert.informativeText = "Enter a name for the new folder:"
                    alert.addButton(withTitle: "Create")
                    alert.addButton(withTitle: "Cancel")
                    alert.alertStyle = .informational
                    
                    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                    input.placeholderString = "Folder name"
                    input.stringValue = newFolderName
                    alert.accessoryView = input
                    alert.window.initialFirstResponder = input
                    
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        let folderName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !folderName.isEmpty {
                            Task {
                                do {
                                    try await browserVM.createDirectory(name: folderName)
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                    showingNewFolderDialog = false
                    #endif
                }
            }
    }
    
    private var headerView: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 700
            let isVeryCompact = geometry.size.width < 500
            
            HStack(spacing: AppTheme.Spacing.m) {
                HStack(spacing: AppTheme.Spacing.s) {
                    Image(systemName: connection.protocolType.iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(connection.protocolType.tint)
                        .frame(width: 34, height: 34)
                        .background(connection.protocolType.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Text(connection.name)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            if !isVeryCompact {
                                connectionStatusPill
                            }
                        }
                        
                        if !isVeryCompact {
                            Text("\(connection.protocolType.displayName) • \(connection.username)@\(connection.host):\(connection.port)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                
                Spacer()
                
                if !isVeryCompact {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                        TextField("Search files...", text: $searchText)
                            .textFieldStyle(.plain)
                            .frame(width: isCompact ? 150 : 220)
                            .focused($isSearchFocused)
                            .onSubmit {
                                // Search is live, no action needed
                            }
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.s)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                
                if !browserVM.directoryHistory.isEmpty {
                    Button {
                        Task {
                            do {
                                try await browserVM.goBack()
                                let currentDirectory = browserVM.currentDirectory
                                let comps = currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                                pathComponents = comps.isEmpty ? ["/"] : ["/"] + comps
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        if isCompact {
                            Image(systemName: "chevron.left")
                        } else {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                }
                
                connectDisconnectButton(isCompact: isCompact)
                
                if !isVeryCompact {
                    actionButtons
                } else {
                    // Very compact: use menu for actions
                    Menu {
                        Button {
                            Task {
                                do {
                                    try await browserVM.refresh()
                                    let currentDirectory = browserVM.currentDirectory
                                    let comps = currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                                    pathComponents = comps.isEmpty ? ["/"] : comps
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        
                        Button {
                            beginDownloadForCurrentSelection()
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                        .disabled(selectedItem == nil && selectedItems.isEmpty)
                        
                        Button {
                            showingUploadPicker = true
                        } label: {
                            Label("Upload", systemImage: "arrow.up.circle")
                        }
                        
                        Button {
                            guard let item = selectedItem else {
                                errorMessage = "Select an item to preview."
                                return
                            }
                            #if os(macOS)
                            if !item.isDirectory {
                                Task {
                                    do {
                                        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                                        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                                        let tempFile = tempDir.appendingPathComponent(item.name)
                                        try await browserVM.download(item, to: tempDir)
                                        let qlProcess = Process()
                                        qlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
                                        qlProcess.arguments = ["-p", tempFile.path]
                                        try? qlProcess.run()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                                            try? FileManager.default.removeItem(at: tempDir)
                                        }
                                    } catch {
                                        errorMessage = "Failed to preview file: \(error.localizedDescription)"
                                    }
                                }
                            } else {
                                errorMessage = "Quick Look is only available for files, not directories."
                            }
                            #endif
                        } label: {
                            Label("Quick Look", systemImage: "eye")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.xs)
        }
        .frame(height: 52)
        .background(.bar)
    }
    
    private var connectionStatusPill: some View {
        Label(browserVM.isConnected ? "Connected" : "Offline", systemImage: browserVM.isConnected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(browserVM.isConnected ? .green : .secondary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.35), in: Capsule())
            .help(browserVM.isConnected ? "Connected to \(connection.host)" : "Not connected")
    }
    
    private func connectDisconnectButton(isCompact: Bool) -> some View {
        Group {
            if browserVM.isConnected {
                Button {
                    showingDisconnectConfirmation = true
                } label: {
                    if isCompact {
                        Image(systemName: "xmark.circle")
                    } else {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                }
                .keyboardShortcut("k", modifiers: [.command])
                .confirmationDialog("Disconnect from \(connection.name)?", isPresented: $showingDisconnectConfirmation, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) {
                        browserVM.disconnect()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("You will need to reconnect to access this server.")
                }
            } else {
                Button {
                    // Check if password is needed
                    if !currentConnection.usesKeyAuth && currentConnection.getPassword() == nil {
                        showingPasswordPrompt = true
                    } else {
                        showingConnectionProgress = true
                    }
                } label: {
                    if isCompact {
                        Image(systemName: "bolt.horizontal")
                    } else {
                        Label("Connect", systemImage: "bolt.horizontal")
                    }
                }
                .keyboardShortcut("k", modifiers: [.command])
                .buttonStyle(.borderedProminent)
            }
        }
    }
    
    private var actionButtons: some View {
        Group {
            Button {
                Task {
                    do {
                        try await browserVM.refresh()
                        let currentDirectory = browserVM.currentDirectory
                        let comps = currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                        pathComponents = comps.isEmpty ? ["/"] : comps
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!browserVM.isConnected)
            downloadButton
            uploadButton
            newFolderButton
            deleteButton
            quickLookButton
        }
    }
    
    private var deleteButton: some View {
        Button {
            handleDeleteSelected()
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .keyboardShortcut(.delete, modifiers: [])
        .disabled((selectedItem == nil && selectedItems.isEmpty) || !browserVM.isConnected)
    }
    
    private var newFolderButton: some View {
        Button {
            newFolderName = ""
            showingNewFolderDialog = true
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(!browserVM.isConnected)
    }
    
    
    private var downloadButton: some View {
        Button {
            beginDownloadForCurrentSelection()
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
        .keyboardShortcut(.return, modifiers: [])
        .disabled((selectedItem == nil && selectedItems.isEmpty) || !browserVM.isConnected)
    }
    
    private var uploadButton: some View {
        Button {
            showingUploadPicker = true
        } label: {
            Label("Upload", systemImage: "arrow.up.circle")
        }
        .keyboardShortcut("u", modifiers: [.command])
        .disabled(!browserVM.isConnected)
    }
    
    private var quickLookButton: some View {
        Button {
            guard let item = selectedItem else {
                errorMessage = "Select an item to preview."
                return
            }
            handleQuickLook(item: item)
        } label: {
            Label("Quick Look", systemImage: "eye")
        }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(!browserVM.isConnected || selectedItem == nil || selectedItem?.isDirectory == true)
    }
    
    private var pathView: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            Label(browserVM.currentDirectory.rawValue.isEmpty ? "/" : browserVM.currentDirectory.rawValue, systemImage: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 120, alignment: .leading)
            
            Divider()
                .frame(height: 18)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(pathComponents.enumerated()), id: \.offset) { idx, comp in
                        breadcrumbButton(index: idx, component: comp)
                        
                        if idx < pathComponents.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.m)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)
        }
    }
    
    private func breadcrumbButton(index: Int, component: String) -> some View {
        Button {
            let targetPath: String
            if component == "/" || index == 0 {
                targetPath = "/"
            } else {
                let segments = pathComponents[1...index]
                targetPath = "/" + segments.joined(separator: "/")
            }
            
            Task {
                do {
                    try await browserVM.navigateToPath(targetPath)
                    let currentDirectory = browserVM.currentDirectory
                    let comps = currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                    pathComponents = comps.isEmpty ? ["/"] : ["/"] + comps
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } label: {
            HStack(spacing: 5) {
                if index == 0 {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 10))
                }
                Text(component == "/" ? "Root" : component)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(index == pathComponents.count - 1 ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(index == pathComponents.count - 1 ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!browserVM.isConnected)
        .help("Navigate to \(component == "/" ? "root" : component)")
    }
    
    private var tabBarView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    Button {
                        switchToTab(tab)
                    } label: {
                        HStack(spacing: 6) {
                            Text(tab.name)
                                .font(.system(size: 12, weight: activeTabId == tab.id ? .semibold : .regular))
                                .lineLimit(1)
                            
                            if tabs.count > 1 {
                                Button {
                                    closeTab(tab)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Close Tab")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(activeTabId == tab.id ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(activeTabId == tab.id ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                
                // New tab button
                Button {
                    createNewTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .help("New Tab")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.thinMaterial)
        .frame(height: 36)
    }
    
    private func updateTabForCurrentDirectory() {
        let currentPath = browserVM.currentDirectory.rawValue
        let tabName = pathComponents.last ?? "/"
        
        // Only update the active tab, don't auto-create new tabs
        if let activeId = activeTabId, let index = tabs.firstIndex(where: { $0.id == activeId }) {
            tabs[index].path = currentPath
            tabs[index].name = tabName
        } else if tabs.isEmpty {
            // Create initial tab if none exist
            let initialTab = BrowserTab(
                name: tabName,
                path: currentPath,
                connectionId: connection.id
            )
            tabs = [initialTab]
            activeTabId = initialTab.id
        }
    }
    
    private func createNewTab() {
        let newTab = BrowserTab(
            name: connection.name,
            path: "/",
            connectionId: connection.id
        )
        tabs.append(newTab)
        activeTabId = newTab.id
        
        // Navigate to root
        Task {
            do {
                try await browserVM.navigateToPath("/")
                let comps = browserVM.currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                pathComponents = comps.isEmpty ? ["/"] : ["/"] + comps
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func switchToTab(_ tab: BrowserTab) {
        guard tab.connectionId == connection.id else { return }
        activeTabId = tab.id
        
        Task {
            do {
                try await browserVM.navigateToPath(tab.path)
                let comps = browserVM.currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                pathComponents = comps.isEmpty ? ["/"] : ["/"] + comps
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func closeTab(_ tab: BrowserTab) {
        guard tabs.count > 1 else { return }
        
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: index)
            
            // If we closed the active tab, switch to another
            if activeTabId == tab.id {
                if index < tabs.count {
                    activeTabId = tabs[index].id
                } else if !tabs.isEmpty {
                    activeTabId = tabs[tabs.count - 1].id
                } else {
                    activeTabId = nil
                }
                
                // Navigate to the new active tab
                if let activeId = activeTabId, let activeTab = tabs.first(where: { $0.id == activeId }) {
                    switchToTab(activeTab)
                }
            }
        }
    }
    
    @ViewBuilder
    private var fileListView: some View {
        let filteredItems = searchText.isEmpty 
            ? browserVM.items 
            : browserVM.items.filter { item in
                item.name.localizedCaseInsensitiveContains(searchText)
            }
        let items = sortedItems(filteredItems)
        
        fileListContent(items: items)
            .onAppear {
                // Check for duplicate paths
                let paths = items.map { $0.path }
                let uniquePaths = Set(paths)
                if paths.count != uniquePaths.count {
                    print("⚠️ UI: Found \(paths.count - uniquePaths.count) duplicate paths!")
                    let pathCounts = Dictionary(grouping: paths, by: { $0 }).mapValues { $0.count }
                    for (path, count) in pathCounts where count > 1 {
                        print("   Duplicate path: \(path) appears \(count) times")
                    }
                }
            }
            .fileImporter(isPresented: $showingUploadPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                handleFileImporterResult(result)
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.Refresh"))) { _ in
                Task { try? await browserVM.refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.Download"))) { _ in
                handleDownloadNotification()
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.Upload"))) { _ in
                showingUploadPicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.SelectAll"))) { _ in
                let filteredItems = searchText.isEmpty 
                    ? browserVM.items 
                    : browserVM.items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
                let sorted = sortedItems(filteredItems)
                selectedItems = Set(sorted)
                if let first = sorted.first {
                    selectedItem = first
                    lastSelectedIndex = 0
                }
            }
            .onChange(of: searchText) { oldValue, newValue in
                // Clear selection when search changes
                if !newValue.isEmpty {
                    selectedItems.removeAll()
                    selectedItem = nil
                    lastSelectedIndex = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.NewTab"))) { _ in
                createNewTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("Shuttler.CloseTab"))) { _ in
                if let activeId = activeTabId, let tab = tabs.first(where: { $0.id == activeId }) {
                    closeTab(tab)
                }
            }
            .overlay(alignment: .bottom) {
                fileListStatusBar
            }
    }
    
    @ViewBuilder
    private func fileListContent(items: [RemoteItem]) -> some View {
        ZStack {
            fileListShell(items: items)
                .onDrop(of: [.fileURL, .shuttlerRemoteItem], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers, destination: browserVM.currentDirectory)
                }
            
            if browserVM.isLoading {
                loadingView
            } else if browserVM.items.isEmpty {
                emptyStateView
            } else if items.isEmpty {
                searchEmptyStateView
            }
            
            if isDropTargeted {
                dropTargetOverlay
            }
        }
    }
    
    private func fileListShell(items: [RemoteItem]) -> some View {
        VStack(spacing: 0) {
            if !items.isEmpty {
                fileListHeader
            }
            fileList(items: items)
        }
    }
    
    private var fileListHeader: some View {
        HStack(spacing: 12) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Permissions")
                .frame(width: 70, alignment: .trailing)
            Text("Size")
                .frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 46)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)
        }
    }
    
    @ViewBuilder
    private func fileList(items: [RemoteItem]) -> some View {
        List {
            ForEach(Array(items.enumerated()), id: \.element.path) { index, item in
                fileListItem(item: item, index: index, items: items)
                    .id("\(item.path)-\(index)")
                    .listRowSeparatorTint(Color(white: 0.85))
                    .listRowSeparator(.visible, edges: .bottom)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            }
            
            // Add invisible spacer at the end to ensure last item is fully visible above status bar
            Color.clear
                .frame(height: 32)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.visible)
    }
    
    @ViewBuilder
    private func fileListItem(item: RemoteItem, index: Int, items: [RemoteItem]) -> some View {
        let isSelected = selectedItem?.path == item.path
        let isHovered = hoveredItemPath == item.path
        let density = ListDensity(rawValue: listDensityRaw) ?? .comfortable
        let rowPadding: CGFloat = density == .comfortable ? 8 : 4
        let iconSize: CGFloat = density == .comfortable ? 18 : 16
        
        HStack(spacing: 12) {
            // File type icon
            Group {
                if item.isDirectory {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue.gradient)
                } else {
                    fileIcon(for: item.name)
                        .foregroundStyle(fileIconColor(for: item.name))
                }
            }
            .font(.system(size: iconSize, weight: .medium))
            .frame(width: iconSize + 4, alignment: .center)
            
            // File name
            Text(item.name)
                .font(.system(size: density == .comfortable ? 13 : 12))
                .foregroundStyle(item.isDirectory ? .primary : .secondary)
                .fontWeight(item.isDirectory ? .medium : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            
            Spacer(minLength: 8)
            
            if !item.permissionsString.isEmpty {
                Text(item.permissionsString)
                    .font(.system(size: density == .comfortable ? 12 : 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 70, alignment: .trailing)
            }
            
            // File size
            Text(item.sizeString)
                .font(.system(size: density == .comfortable ? 12 : 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, rowPadding)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground(isSelected: isSelected || selectedItems.contains(item), isHovered: isHovered))
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.quaternary.opacity(0.35))
                .frame(height: 0.5)
                .padding(.leading, iconSize + 28)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredItemPath = hovering ? item.path : (hoveredItemPath == item.path ? nil : hoveredItemPath)
        }
        #if os(macOS)
        .simultaneousGesture(
            TapGesture()
                .onEnded { _ in
                    let currentEvent = NSApp.currentEvent
                    let commandPressed = currentEvent?.modifierFlags.contains(.command) ?? false
                    let shiftPressed = currentEvent?.modifierFlags.contains(.shift) ?? false
                    
                    if commandPressed {
                        // Command-click to toggle selection
                        if selectedItems.contains(item) {
                            selectedItems.remove(item)
                            if selectedItem?.path == item.path {
                                selectedItem = selectedItems.first
                            }
                        } else {
                            selectedItems.insert(item)
                            selectedItem = item
                            lastSelectedIndex = index
                        }
                    } else if shiftPressed {
                        // Shift-click for range selection
                        handleShiftClick(item: item, index: index, items: items)
                    } else {
                        // Regular click - select single item only (no navigation)
                        selectedItems.removeAll()
                        selectedItem = item
                        selectedItems.insert(item)
                        lastSelectedIndex = index
                    }
                }
        )
        .onTapGesture(count: 2) {
            // Double-click to open directories
            if item.isDirectory {
                Task {
                    do {
                        try await browserVM.open(item)
                        let currentDirectory = browserVM.currentDirectory
                        let comps = currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                        pathComponents = comps.isEmpty ? ["/"] : ["/"] + comps
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        #else
        .onTapGesture {
            // Single click - select only
            selectedItems.removeAll()
            selectedItem = item
            selectedItems.insert(item)
            lastSelectedIndex = index
        }
        .onTapGesture(count: 2) {
            // Double-click to open directories
            handleItemDoubleTap(item: item)
        }
        #endif
        .contextMenu {
            fileItemContextMenu(item: item)
        }
        .onDrag {
            makeRemoteItemProvider(for: item)
        }
        .onDrop(of: [.fileURL, .shuttlerRemoteItem], isTargeted: nil) { providers in
            guard item.isDirectory else { return false }
            return handleDrop(providers: providers, destination: RemotePath(rawValue: item.path))
        }
        #if os(macOS)
        .overlay(
            Group {
                if browserVM.isConnected {
                    DragSourceView(item: item, browserVM: browserVM, isConnected: browserVM.isConnected)
                } else {
                    Color.clear
                        .allowsHitTesting(false)
                }
            }
        )
        #endif
    }
    
    private func rowBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }
        if isHovered {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }
    
    private func fileIcon(for filename: String) -> Image {
        let ext = (filename as NSString).pathExtension.lowercased()
        
        switch ext {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp", "heic", "svg":
            return Image(systemName: "photo.fill")
        case "mp4", "mov", "avi", "mkv", "webm", "flv", "wmv", "m4v":
            return Image(systemName: "film.fill")
        case "mp3", "wav", "aac", "flac", "m4a", "ogg", "wma":
            return Image(systemName: "music.note")
        case "pdf":
            return Image(systemName: "doc.fill")
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            return Image(systemName: "archivebox.fill")
        case "html", "htm", "css", "js", "jsx", "ts", "tsx", "json", "xml":
            return Image(systemName: "code")
        case "txt", "md", "rtf":
            return Image(systemName: "doc.text.fill")
        case "sql", "db", "sqlite":
            return Image(systemName: "externaldrive.fill")
        case "iso", "dmg", "img":
            return Image(systemName: "opticaldisc.fill")
        default:
            return Image(systemName: "doc.fill")
        }
    }
    
    private func fileIconColor(for filename: String) -> Color {
        let ext = (filename as NSString).pathExtension.lowercased()
        
        switch ext {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp", "heic", "svg":
            return .orange
        case "mp4", "mov", "avi", "mkv", "webm", "flv", "wmv", "m4v":
            return .purple
        case "mp3", "wav", "aac", "flac", "m4a", "ogg", "wma":
            return .pink
        case "pdf":
            return .red
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            return .brown
        case "html", "htm", "css", "js", "jsx", "ts", "tsx", "json", "xml":
            return .yellow
        case "txt", "md", "rtf":
            return .gray
        case "sql", "db", "sqlite":
            return .cyan
        case "iso", "dmg", "img":
            return .indigo
        default:
            return .secondary
        }
    }
    
    @ViewBuilder
    private func fileItemContextMenu(item: RemoteItem) -> some View {
        if item.isDirectory {
            Button {
                handleItemDoubleTap(item: item)
            } label: {
                Label("Open", systemImage: "folder")
            }
            
            Divider()
        } else {
            Button {
                handleQuickLook(item: item)
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
        }
        
        Button {
            handleContextMenuDownload(item: item)
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
        
        Divider()
        
        Button {
            handleContextMenuCopy(item: item)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .keyboardShortcut("c", modifiers: [.command])
        
        Button {
            handleContextMenuCut(item: item)
        } label: {
            Label("Cut", systemImage: "scissors")
        }
        .keyboardShortcut("x", modifiers: [.command])
        
        if !clipboardItems.isEmpty {
            Button {
                handleContextMenuPaste()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("v", modifiers: [.command])
        }
        
        Divider()
        
        Button {
            showMoveCopyDialog(for: item, operation: .copy)
        } label: {
            Label("Copy To...", systemImage: "folder.badge.plus")
        }
        
        Button {
            showMoveCopyDialog(for: item, operation: .cut)
        } label: {
            Label("Move To...", systemImage: "folder.badge.gearshape")
        }
        
        Divider()
        
        Button {
            handleContextMenuDuplicate(item: item)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        .keyboardShortcut("d", modifiers: [.command])
        
        Button {
            handleContextMenuRename(item: item)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        
        if !item.isDirectory {
            
            Button {
                handleContextMenuEdit(item: item)
            } label: {
                Label("Edit", systemImage: "pencil.line")
            }
        }
        
        Divider()
        
        Button {
            handleContextMenuPermissions(item: item)
        } label: {
            Label("Permissions...", systemImage: "lock")
        }
        
        Divider()
        
        Button(role: .destructive) {
            handleContextMenuDelete(item: item)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
    
    private var loadingView: some View {
        ProgressView().controlSize(.large)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    private var emptyStateView: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            Image(systemName: browserVM.isConnected ? "folder" : "folder.badge.questionmark")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            
            if browserVM.isConnected {
                VStack(spacing: AppTheme.Spacing.xs) {
                    Text("Empty Folder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(browserVM.currentDirectory.rawValue)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Button {
                        showingUploadPicker = true
                    } label: {
                        Label("Upload", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, AppTheme.Spacing.xs)
                }
            } else {
                VStack(spacing: AppTheme.Spacing.xs) {
                    Text("Not Connected")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                    
                    Text("\(connection.username)@\(connection.host)")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Button {
                        if !currentConnection.usesKeyAuth && currentConnection.getPassword() == nil {
                            showingPasswordPrompt = true
                        } else {
                            showingConnectionProgress = true
                        }
                    } label: {
                        Label("Connect", systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, AppTheme.Spacing.xs)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppTheme.Spacing.xl)
    }
    
    private var searchEmptyStateView: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Matches")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            Button {
                searchText = ""
            } label: {
                Label("Clear Search", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppTheme.Spacing.xl)
    }
    
    
    private var fileListStatusBar: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            let filteredCount = searchText.isEmpty 
                ? browserVM.items.count 
                : browserVM.items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }.count
            let totalCount = browserVM.items.count
            
            Label(browserVM.isConnected ? "Connected" : "Offline", systemImage: browserVM.isConnected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(browserVM.isConnected ? .green : .secondary)
            
            Divider()
                .frame(height: 12)
            
            if !searchText.isEmpty {
                Text("\(filteredCount) of \(totalCount) item\(totalCount == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(totalCount) item\(totalCount == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if !selectedItems.isEmpty || selectedItem != nil {
                Divider()
                    .frame(height: 12)
                HStack(spacing: 6) {
                    let displayCount = selectedItems.isEmpty ? 1 : selectedItems.count
                    if displayCount > 1 {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 10))
                        Text("\(displayCount) selected")
                            .font(.system(size: 12))
                    } else if let sel = selectedItem {
                        Image(systemName: sel.isDirectory ? "folder.fill" : "doc.fill")
                            .font(.system(size: 10))
                        Text(sel.name)
                            .font(.system(size: 12))
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            
            Text(browserVM.currentDirectory.rawValue)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .background(.bar)
    }
    
    private var dropTargetOverlay: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 2)
            }
            .overlay {
                Label("Drop to Upload", systemImage: "arrow.up.doc.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(10)
            .allowsHitTesting(false)
    }
    
    // MARK: - Helper Methods
    
    private func handleItemTap(item: RemoteItem, index: Int, items: [RemoteItem]) {
        // Regular click - select single item only (no navigation)
        // Note: Command-click and Shift-click are handled by simultaneousGesture above
        // Double-click is handled separately
        selectedItems.removeAll()
        selectedItem = item
        selectedItems.insert(item)
        lastSelectedIndex = index
    }
    
    private func handleItemDoubleTap(item: RemoteItem) {
        // Double-click to open directories
        if item.isDirectory {
            Task {
                do {
                    try await browserVM.open(item)
                    let currentDirectory = browserVM.currentDirectory
                    let comps = currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                    pathComponents = comps.isEmpty ? ["/"] : ["/"] + comps
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func handleShiftClick(item: RemoteItem, index: Int, items: [RemoteItem]) {
        // Shift-click for range selection
        // items parameter should already be the sorted/filtered list being displayed
        guard index < items.count else { return }
        
        if let lastIndex = lastSelectedIndex, lastIndex < items.count {
            let startIndex = min(lastIndex, index)
            let endIndex = max(lastIndex, index)
            
            // Select all items in the range
            for i in startIndex...endIndex {
                if i < items.count {
                    selectedItems.insert(items[i])
                }
            }
            
            // Update selected item to the clicked item
            selectedItem = item
            lastSelectedIndex = index
        } else {
            // No previous selection, just select this item
            selectedItems.removeAll()
            selectedItem = item
            selectedItems.insert(item)
            lastSelectedIndex = index
        }
    }
    
    private func handleQuickLook(item: RemoteItem) {
        #if os(macOS)
        if item.isDirectory {
            errorMessage = "Quick Look is only available for files, not directories."
            return
        }
        
        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let tempFile = tempDir.appendingPathComponent(item.name)
                try await browserVM.download(item, to: tempDir)
                let qlProcess = Process()
                qlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
                qlProcess.arguments = ["-p", tempFile.path]
                try? qlProcess.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    try? FileManager.default.removeItem(at: tempDir)
                }
            } catch {
                errorMessage = "Failed to preview file: \(error.localizedDescription)"
            }
        }
        #endif
    }
    
    private func beginDownloadForCurrentSelection() {
        let itemsToDownload = selectedItems.isEmpty ? (selectedItem.map { [$0] } ?? []) : Array(selectedItems)
        beginDownload(items: itemsToDownload)
    }
    
    private func beginDownload(items: [RemoteItem]) {
        guard !items.isEmpty else {
            errorMessage = "Select a file or folder to download."
            return
        }
        
        #if os(macOS)
        pendingDownloadItems = items
        showingDownloadOptions = true
        #endif
    }
    
    private func performDownloads(items: [RemoteItem], to destination: URL, revealWhenDone: Bool = true) async {
        var downloadedURLs: [URL] = []
        ToastManager.shared.show("Downloading \(items.count) item\(items.count == 1 ? "" : "s")", type: .info)
        
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not prepare download folder: \(error.localizedDescription)"
            return
        }
        
        for item in items {
            do {
                let localName = try await resolveDownloadName(for: item, in: destination)
                guard let localName else { return }
                try await browserVM.download(item, to: destination, as: localName)
                downloadedURLs.append(destination.appendingPathComponent(localName))
            } catch {
                errorMessage = "Failed to download \(item.name): \(error.localizedDescription)"
                return
            }
        }
        #if os(macOS)
        if revealWhenDone, !downloadedURLs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(downloadedURLs)
        }
        ToastManager.shared.show("Downloaded \(items.count) item\(items.count == 1 ? "" : "s")", type: .success)
        #endif
    }
    
    private func resolveDownloadName(for item: RemoteItem, in destination: URL) async throws -> String? {
        let targetURL = destination.appendingPathComponent(item.name)
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return item.name
        }
        
        #if os(macOS)
        let choice = NSAlert.downloadConflictChoice(itemName: item.name, destination: destination)
        switch choice {
        case .replace:
            try FileManager.default.removeItem(at: targetURL)
            return item.name
        case .keepBoth:
            return uniqueLocalName(for: item.name, in: destination)
        case .cancel:
            return nil
        }
        #else
        return uniqueLocalName(for: item.name, in: destination)
        #endif
    }
    
    private func uniqueLocalName(for fileName: String, in directory: URL) -> String {
        let nsName = fileName as NSString
        let baseName = nsName.deletingPathExtension
        let pathExtension = nsName.pathExtension
        var counter = 2
        var candidate: String
        repeat {
            candidate = pathExtension.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(pathExtension)"
            counter += 1
        } while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        return candidate
    }
    
    private func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
    
    private func handleContextMenuDownload(item: RemoteItem) {
        selectedItem = item
        let itemsToDownload = selectedItems.contains(item) ? Array(selectedItems) : [item]
        beginDownload(items: itemsToDownload)
    }
    
    private func handleContextMenuRename(item: RemoteItem) {
        selectedItem = item
        renameText = item.name
        showingRenameDialog = true
    }
    
    private func handleContextMenuEdit(item: RemoteItem) {
        selectedItem = item
        Task {
            do {
                let tempFile = try await browserVM.editFile(item)
                NSWorkspace.shared.open(tempFile)
            } catch {
                errorMessage = "Failed to edit file: \(error.localizedDescription)"
            }
        }
    }
    
    private func handleContextMenuDelete(item: RemoteItem) {
        selectedItem = item
        if !selectedItems.contains(item) {
            selectedItems.insert(item)
        }
        handleDeleteSelected()
    }
    
    private func handleContextMenuCopy(item: RemoteItem) {
        selectedItem = item
        clipboardItems = selectedItems.isEmpty ? [item] : Array(selectedItems)
        clipboardOperation = .copy
    }
    
    private func handleContextMenuCut(item: RemoteItem) {
        selectedItem = item
        clipboardItems = selectedItems.isEmpty ? [item] : Array(selectedItems)
        clipboardOperation = .cut
    }
    
    private func handleContextMenuPaste() {
        guard !clipboardItems.isEmpty, browserVM.isConnected else { return }
        
        Task {
            await performRemoteTransfer(items: clipboardItems, to: browserVM.currentDirectory, operation: clipboardOperation)
        }
    }
    
    private func handleContextMenuDuplicate(item: RemoteItem) {
        selectedItem = item
        guard browserVM.isConnected else {
            errorMessage = "Not connected"
            return
        }
        
        Task {
            do {
                try await browserVM.duplicate(item: item)
                try await browserVM.refresh()
            } catch {
                errorMessage = "Failed to duplicate: \(error.localizedDescription)"
            }
        }
    }
    
    private func handleContextMenuPermissions(item: RemoteItem) {
        selectedItem = item
        itemForPermissions = item
        permissionsText = item.permissions ?? "644"
        showingPermissionsDialog = true
    }
    
    private func showMoveCopyDialog(for item: RemoteItem, operation: ClipboardOperation) {
        selectedItem = item
        moveCopyDialogItems = selectedItems.contains(item) ? Array(selectedItems) : [item]
        moveCopyDialogOperation = operation
        moveCopyDestinationPath = browserVM.currentDirectory.rawValue
        showingMoveCopyDialog = true
    }
    
    private func handleDeleteSelected() {
        let itemsToDelete = selectedItems.isEmpty ? (selectedItem.map { [$0] } ?? []) : Array(selectedItems)
        guard !itemsToDelete.isEmpty else { return }
        
        #if os(macOS)
        // Check if folders are empty asynchronously before showing confirmation
        Task {
            var folderEmptyStatus: [RemoteItem: Bool] = [:]
            
            // Check each directory to see if it's empty
            for item in itemsToDelete where item.isDirectory {
                do {
                    let isEmpty = try await browserVM.isDirectoryEmpty(item)
                    folderEmptyStatus[item] = isEmpty
                } catch {
                    // If we can't check, assume it's not empty to be safe
                    folderEmptyStatus[item] = false
                }
            }
            
            // Show confirmation dialog on main thread
            await MainActor.run {
                let alert = NSAlert()
                
                if itemsToDelete.count == 1 {
                    let item = itemsToDelete[0]
                    alert.messageText = "Delete \"\(item.name)\"?"
                    
                    if item.isDirectory {
                        let isEmpty = folderEmptyStatus[item] ?? false
                        if isEmpty {
                            alert.informativeText = "This empty folder will be permanently deleted. This action cannot be undone."
                        } else {
                            alert.informativeText = "⚠️ This folder is not empty. This folder and all its contents will be permanently deleted. This action cannot be undone."
                        }
                    } else {
                        alert.informativeText = "This file will be permanently deleted. This action cannot be undone."
                    }
                } else {
                    alert.messageText = "Delete \(itemsToDelete.count) items?"
                    
                    // Check if any folders are not empty
                    let nonEmptyFolders = itemsToDelete.filter { item in
                        item.isDirectory && (folderEmptyStatus[item] == false)
                    }
                    
                    if !nonEmptyFolders.isEmpty {
                        let folderCount = nonEmptyFolders.count
                        let folderText = folderCount == 1 ? "folder" : "folders"
                        alert.informativeText = "⚠️ \(folderCount) of the selected \(folderText) \(folderCount == 1 ? "is" : "are") not empty. These items and all their contents will be permanently deleted. This action cannot be undone."
                    } else {
                        alert.informativeText = "These items will be permanently deleted. This action cannot be undone."
                    }
                }
                
                alert.addButton(withTitle: "Delete")
                alert.addButton(withTitle: "Cancel")
                alert.alertStyle = .warning
                
                let response = alert.runModal()
                
                if response == .alertFirstButtonReturn {
                    Task {
                        for item in itemsToDelete {
                            do {
                                try await browserVM.delete(item)
                            } catch {
                                errorMessage = "Failed to delete \(item.name): \(error.localizedDescription)"
                                break
                            }
                        }
                        // Clear selection after deletion
                        selectedItems.removeAll()
                        selectedItem = nil
                        lastSelectedIndex = nil
                    }
                }
            }
        }
        #else
        Task {
            for item in itemsToDelete {
                do {
                    try await browserVM.delete(item)
                } catch {
                    errorMessage = "Failed to delete \(item.name): \(error.localizedDescription)"
                    break
                }
            }
            // Clear selection after deletion
            selectedItems.removeAll()
            selectedItem = nil
            lastSelectedIndex = nil
        }
        #endif
    }
    
    private enum NavigationDirection {
        case up, down
    }
    
    private func handleSelectAll() {
        let filteredItems = searchText.isEmpty 
            ? browserVM.items 
            : browserVM.items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        let sorted = sortedItems(filteredItems)
        selectedItems = Set(sorted)
        if let first = sorted.first {
            selectedItem = first
            lastSelectedIndex = 0
        }
    }
    
    private func handleCopy() {
        let itemsToCopy = selectedItems.isEmpty ? (selectedItem.map { [$0] } ?? []) : Array(selectedItems)
        if !itemsToCopy.isEmpty {
            clipboardItems = itemsToCopy
            clipboardOperation = .copy
        }
    }
    
    private func handleCut() {
        let itemsToCut = selectedItems.isEmpty ? (selectedItem.map { [$0] } ?? []) : Array(selectedItems)
        if !itemsToCut.isEmpty {
            clipboardItems = itemsToCut
            clipboardOperation = .cut
        }
    }
    
    private func navigateItems(direction: NavigationDirection) {
        let filteredItems = searchText.isEmpty 
            ? browserVM.items 
            : browserVM.items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        let items = sortedItems(filteredItems)
        
        guard !items.isEmpty else { return }
        
        let currentIndex: Int
        if let lastIndex = lastSelectedIndex, lastIndex < items.count {
            currentIndex = lastIndex
        } else if let selected = selectedItem, let index = items.firstIndex(where: { $0.path == selected.path }) {
            currentIndex = index
        } else {
            currentIndex = 0
        }
        
        let newIndex: Int
        switch direction {
        case .up:
            newIndex = max(0, currentIndex - 1)
        case .down:
            newIndex = min(items.count - 1, currentIndex + 1)
        }
        
        if newIndex != currentIndex && newIndex < items.count {
            let newItem = items[newIndex]
            selectedItem = newItem
            selectedItems.removeAll()
            selectedItems.insert(newItem)
            lastSelectedIndex = newIndex
        }
    }
    
    private func makeRemoteItemProvider(for item: RemoteItem) -> NSItemProvider {
        let provider = NSItemProvider()
        if let data = try? JSONEncoder().encode(item) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.shuttlerRemoteItem.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }
    
    private func handleDrop(providers: [NSItemProvider], destination: RemotePath) -> Bool {
        guard browserVM.isConnected else {
            errorMessage = "Not connected. Please connect first."
            return false
        }
        
        Task {
            if await processRemoteItemDrop(providers: providers, destination: destination) {
                return
            }
            await processFileDrop(providers: providers, destination: destination)
        }
        
        return true
    }
    
    private func processRemoteItemDrop(providers: [NSItemProvider], destination: RemotePath) async -> Bool {
        let remoteProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.shuttlerRemoteItem.identifier) }
        guard !remoteProviders.isEmpty else { return false }
        
        var droppedItems: [RemoteItem] = []
        for provider in remoteProviders {
            if let data = try? await loadDataRepresentation(from: provider, typeIdentifier: UTType.shuttlerRemoteItem.identifier),
               let item = try? JSONDecoder().decode(RemoteItem.self, from: data) {
                droppedItems.append(item)
            }
        }
        
        guard !droppedItems.isEmpty else { return true }
        
        #if os(macOS)
        let shouldCopy = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        #else
        let shouldCopy = false
        #endif
        await performRemoteTransfer(items: droppedItems, to: destination, operation: shouldCopy ? .copy : .cut)
        return true
    }
    
    private func loadDataRepresentation(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? TransferError(message: "Unable to load drag data."))
                }
            }
        }
    }
    
    private func performRemoteTransfer(items: [RemoteItem], to destination: RemotePath, operation: ClipboardOperation) async {
        guard !items.isEmpty else { return }
        let destinationValue = destination.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destinationValue.isEmpty else {
            errorMessage = "Enter a remote destination path."
            return
        }
        let normalizedDestination = RemotePath(rawValue: destinationValue)
        
        do {
            for item in items {
                if item.path == normalizedDestination.rawValue || normalizedDestination.rawValue.hasPrefix(item.path + "/") {
                    throw TransferError(message: "Cannot move or copy \(item.name) into itself.")
                }
                
                if operation == .cut {
                    try await browserVM.move(item: item, to: normalizedDestination)
                } else {
                    try await browserVM.copy(item: item, to: normalizedDestination)
                }
            }
            
            if operation == .cut {
                clipboardItems = []
            }
            try await browserVM.refresh()
            ToastManager.shared.show("\(operation == .cut ? "Moved" : "Copied") \(items.count) item\(items.count == 1 ? "" : "s")", type: .success)
        } catch {
            errorMessage = "Failed to \(operation == .cut ? "move" : "copy"): \(error.localizedDescription)"
        }
    }
    
    private func processFileDrop(providers: [NSItemProvider], destination: RemotePath) async {
        var uploadErrors: [String] = []
        var uploadCount = 0
        
        await withTaskGroup(of: (success: Bool, error: String?)?.self) { group in
            for provider in providers {
                group.addTask {
                    await self.processFileProvider(provider: provider, destination: destination)
                }
            }
            
            for await result in group {
                if let result = result {
                    if result.success {
                        uploadCount += 1
                    } else if let error = result.error {
                        uploadErrors.append(error)
                    }
                }
            }
        }
        
        // Refresh after all uploads complete
        try? await browserVM.refresh()
        
        // Show success/error message
        await MainActor.run {
            if uploadCount > 0 && uploadErrors.isEmpty {
                // Success - no error message needed, refresh shows the new files
            } else if !uploadErrors.isEmpty {
                errorMessage = uploadErrors.joined(separator: "\n")
            }
        }
    }
    
    private func processFileProvider(provider: NSItemProvider, destination: RemotePath) async -> (success: Bool, error: String?)? {
        // Get file URL from provider - try different methods
        var fileURL: URL? = nil
        
        // Method 1: Try loading as URL directly (most reliable for macOS)
        if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) as? URL {
            fileURL = url
        }
        
        // Method 2: Try as Data and convert to URL
        if fileURL == nil {
            if let urlData = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) as? Data {
                fileURL = URL(dataRepresentation: urlData, relativeTo: nil)
            }
        }
        
        // Method 3: Try as string
        if fileURL == nil {
            if let urlString = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) as? String {
                // Handle both file:// URLs and plain paths
                if urlString.hasPrefix("file://") {
                    fileURL = URL(string: urlString)
                } else {
                    fileURL = URL(fileURLWithPath: urlString)
                }
            }
        }
        
        // Method 4: Try legacy identifier
        if fileURL == nil {
            if let url = try? await provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) as? URL {
                fileURL = url
            } else if let urlData = try? await provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) as? Data {
                fileURL = URL(dataRepresentation: urlData, relativeTo: nil)
            }
        }
        
        guard let url = fileURL else {
            // Log what types are available for debugging
            let types = provider.registeredTypeIdentifiers
            return (success: false, error: "Failed to load file URL. Available types: \(types.joined(separator: ", "))")
        }
        
        // Verify the file exists and is accessible
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (success: false, error: "File not found: \(url.lastPathComponent)")
        }
        
        do {
            try await browserVM.upload(url, to: destination)
            return (success: true, error: nil)
        } catch let error as UploadConflictError {
            // Handle conflict - set state for alert
            await MainActor.run {
                uploadConflictResolution = (localURL: error.localURL, existingItem: error.existingItem)
                uploadConflictDestination = destination
                showingUploadConflict = true
            }
            // Return success since we're handling it with user interaction
            return (success: true, error: nil)
        } catch {
            return (success: false, error: "\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
    
    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                // Upload all selected files concurrently
                await withTaskGroup(of: Void.self) { group in
                    for url in urls {
                        group.addTask {
                            do {
                                try await self.browserVM.upload(url)
                            } catch let error as UploadConflictError {
                                // Handle conflict - set state for alert
                                await MainActor.run {
                                    self.uploadConflictResolution = (localURL: error.localURL, existingItem: error.existingItem)
                                    self.showingUploadConflict = true
                                }
                            } catch {
                                await MainActor.run {
                                    self.errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                }
                // Refresh after all uploads complete
                try? await browserVM.refresh()
            }
        case .failure(let err):
            errorMessage = err.localizedDescription
        }
    }
    
    private func handleDownloadNotification() {
        beginDownloadForCurrentSelection()
    }
    
    private func sortedItems(_ items: [RemoteItem]) -> [RemoteItem] {
        let key = SortKey(rawValue: sortKeyRaw) ?? .name
        let sorted: [RemoteItem]
        switch key {
        case .name:
            sorted = items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size:
            sorted = items.sorted { $0.size < $1.size }
        case .kind:
            sorted = items.sorted { (lhs, rhs) in
                let lk = lhs.isDirectory ? 0 : 1
                let rk = rhs.isDirectory ? 0 : 1
                if lk != rk { return lk < rk }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
        let final = sortAscending ? sorted : sorted.reversed()
        
        // Apply foldersFirst sorting - this needs to preserve the existing sort order within each group
        let result: [RemoteItem]
        if foldersFirst {
            let folders = final.filter { $0.isDirectory }
            let files = final.filter { !$0.isDirectory }
            result = folders + files
        } else {
            result = Array(final)
        }
        
        return result
    }
}

#if os(macOS)
struct DownloadOptionsView: View {
    let items: [RemoteItem]
    let defaultFolder: String
    var onStart: (URL, Bool) -> Void
    var onCancel: () -> Void
    
    @State private var revealWhenDone = true
    
    private var downloadsURL: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
    
    private var defaultFolderURL: URL {
        URL(fileURLWithPath: NSString(string: defaultFolder).expandingTildeInPath, isDirectory: true)
    }
    
    private var itemSummary: String {
        if items.count == 1 {
            return items[0].name
        }
        return "\(items.count) items"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            HStack(spacing: AppTheme.Spacing.m) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.green)
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("Download \(itemSummary)")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Choose where Shuttler should save the selection.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            
            VStack(spacing: AppTheme.Spacing.xs) {
                destinationButton(
                    title: "Downloads",
                    subtitle: downloadsURL.path,
                    icon: "tray.and.arrow.down.fill",
                    url: downloadsURL
                )
                
                if defaultFolderURL.standardizedFileURL != downloadsURL.standardizedFileURL {
                    destinationButton(
                        title: "Default Folder",
                        subtitle: defaultFolderURL.path,
                        icon: "folder.fill",
                        url: defaultFolderURL
                    )
                }
                
                Button {
                    chooseFolder()
                } label: {
                    destinationRow(title: "Choose Folder...", subtitle: "Pick another location", icon: "folder.badge.plus")
                }
                .buttonStyle(.plain)
            }
            
            Toggle("Reveal in Finder when complete", isOn: $revealWhenDone)
            
            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(AppTheme.Spacing.l)
        .frame(width: 460)
        .background(.regularMaterial)
    }
    
    private func destinationButton(title: String, subtitle: String, icon: String, url: URL) -> some View {
        Button {
            onStart(url, revealWhenDone)
        } label: {
            destinationRow(title: title, subtitle: subtitle, icon: icon)
        }
        .buttonStyle(.plain)
    }
    
    private func destinationRow(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: AppTheme.Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.green)
                .frame(width: 30, height: 30)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(AppTheme.Spacing.s)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Download Location"
        panel.prompt = "Download"
        panel.directoryURL = defaultFolderURL
        if panel.runModal() == .OK, let url = panel.url {
            onStart(url, revealWhenDone)
        }
    }
}
#endif

#if os(macOS)
extension NSOpenPanel {
    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }
    
    static func chooseDownloadDirectory(itemCount: Int) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = itemCount == 1 ? "Choose Download Location" : "Choose Download Location for \(itemCount) Items"
        panel.message = "Select the folder where Shuttler should save the selected remote item\(itemCount == 1 ? "" : "s")."
        panel.prompt = "Download"
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }
}

enum DownloadConflictChoice {
    case replace
    case keepBoth
    case cancel
}

extension NSAlert {
    static func downloadConflictChoice(itemName: String, destination: URL) -> DownloadConflictChoice {
        let alert = NSAlert()
        alert.messageText = "\"\(itemName)\" Already Exists"
        alert.informativeText = "The destination folder already contains an item named \"\(itemName)\". Choose whether to replace it or keep both copies."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Cancel")
        
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .replace
        case .alertSecondButtonReturn:
            return .keepBoth
        default:
            return .cancel
        }
    }
}
#endif

extension UTType {
    static let shuttlerRemoteItem = UTType(exportedAs: "com.finalreality.shuttler.remote-item")
}

#if os(macOS)
final class RemoteItemPasteboardWriter: NSObject, NSPasteboardWriting {
    private let data: Data
    
    init?(item: RemoteItem) {
        guard let data = try? JSONEncoder().encode(item) else { return nil }
        self.data = data
        super.init()
    }
    
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [NSPasteboard.PasteboardType(UTType.shuttlerRemoteItem.identifier)]
    }
    
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        data
    }
    
    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        []
    }
}

// File promise delegate for drag and drop downloads
class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let item: RemoteItem
    let browserVM: RemoteBrowserViewModel
    
    init(item: RemoteItem, browserVM: RemoteBrowserViewModel) {
        self.item = item
        self.browserVM = browserVM
        super.init()
    }
    
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        // Return the filename - this is critical for the drag to work
        // Ensure the filename is valid and not empty
        var filename = item.name
        if filename.isEmpty {
            filename = "file"
        }
        // Remove any invalid characters that might cause issues
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        filename = filename.components(separatedBy: invalidChars).joined(separator: "_")
        print("📋 FilePromise: fileNameForType requested for type: \(fileType), returning: \(filename)")
        return filename
    }
    
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        // This is called only when the file is actually dropped
        // The URL is the exact location where the file should be written
        // The system provides a temporary location with the correct filename
        print("📥 FilePromise: writePromiseTo called for \(item.name) at \(url.path)")
        
        Task { @MainActor [weak self] in
            guard let self = self else {
                let error = NSError(domain: "Shuttler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download failed: View model deallocated"])
                print("❌ FilePromise: Delegate deallocated")
                completionHandler(error)
                return
            }
            
            do {
                // Download to the directory containing the destination URL
                // The download function will create a file with item.name in that directory
                let destinationDir = url.deletingLastPathComponent()
                print("📥 FilePromise: Downloading \(self.item.name) to directory \(destinationDir.path)")
                
                // Download to the directory
                try await self.browserVM.download(self.item, to: destinationDir)
                
                // The download creates a file with item.name in destinationDir
                // But the system expects the file at the exact URL provided
                // Check if the downloaded file needs to be moved/renamed
                let downloadedFile = destinationDir.appendingPathComponent(self.item.name)
                if downloadedFile != url && FileManager.default.fileExists(atPath: downloadedFile.path) {
                    // Move the downloaded file to the exact location expected
                    print("📥 FilePromise: Moving downloaded file from \(downloadedFile.path) to \(url.path)")
                    try FileManager.default.moveItem(at: downloadedFile, to: url)
                } else if !FileManager.default.fileExists(atPath: url.path) {
                    // If the file doesn't exist at the expected location, something went wrong
                    throw NSError(domain: "Shuttler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Downloaded file not found at expected location"])
                }
                
                print("✅ FilePromise: Download completed for \(self.item.name)")
                completionHandler(nil)
            } catch {
                print("❌ FilePromise: Download failed for \(self.item.name): \(error.localizedDescription)")
                completionHandler(error)
            }
        }
    }
}

// NSViewRepresentable to handle drag and drop with NSFilePromiseProvider
struct DragSourceView: NSViewRepresentable {
    let item: RemoteItem
    let browserVM: RemoteBrowserViewModel
    let isConnected: Bool
    
    func makeNSView(context: Context) -> NSView {
        print("🔧 Creating DragSourceView for: \(item.name), isDirectory: \(item.isDirectory), isConnected: \(isConnected)")
        let view = DragSourceNSView(item: item, browserVM: browserVM, isConnected: isConnected)
        // Make the view fill the entire area and be transparent
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        // Set up tracking area to monitor mouse events
        view.setupTrackingArea()
        // Ensure the view can receive mouse events
        view.isHidden = false
        print("🔧 DragSourceView created, bounds: \(view.bounds), frame: \(view.frame)")
        return view
    }
    
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // Clean up tracking areas when view is dismantled
        if let dragView = nsView as? DragSourceNSView {
            if let trackingArea = dragView.trackingArea {
                dragView.removeTrackingArea(trackingArea)
            }
        }
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Update connection status if needed
        if let dragView = nsView as? DragSourceNSView {
            print("🔧 Updating DragSourceView for: \(item.name)")
            // Update tracking area if bounds changed
            dragView.setupTrackingArea()
        }
    }
}

class DragSourceNSView: NSView, NSDraggingSource {
    let item: RemoteItem
    let browserVM: RemoteBrowserViewModel
    let isConnected: Bool
    private var mouseDownLocation: NSPoint = .zero
    private var hasStartedDrag = false
    private var shouldForwardClick = true
    var trackingArea: NSTrackingArea?
    private var globalEventMonitor: Any?
    private var filePromiseDelegate: FilePromiseDelegate? // Retain the delegate
    
    init(item: RemoteItem, browserVM: RemoteBrowserViewModel, isConnected: Bool) {
        self.item = item
        self.browserVM = browserVM
        self.isConnected = isConnected
        super.init(frame: .zero)
        print("🔧 DragSourceNSView initialized for: \(item.name)")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override var acceptsFirstResponder: Bool {
        return false
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept when connected
        guard isConnected else {
            return nil
        }
        // Check if point is in bounds
        if bounds.contains(point) {
            print("🎯 hitTest: returning self for \(item.name) at point \(point)")
            return self
        }
        return nil
    }
    
    func setupTrackingArea() {
        // Use tracking area that captures mouse events
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .enabledDuringMouseDrag]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        if let trackingArea = trackingArea {
            addTrackingArea(trackingArea)
            print("🔧 Tracking area set up for \(item.name), bounds: \(bounds)")
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            print("🔧 DragSourceView moved to window for \(item.name)")
            setupTrackingArea()
        }
    }
    
    override func layout() {
        super.layout()
        // Update tracking area when layout changes
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        setupTrackingArea()
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        setupTrackingArea()
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Don't steal first mouse - let underlying views handle it
        return false
    }
    
    override func mouseDown(with event: NSEvent) {
        // Store location for potential drag (in view coordinates)
        let pointInView = convert(event.locationInWindow, from: nil)
        mouseDownLocation = pointInView
        hasStartedDrag = false
        shouldForwardClick = true
        
        print("🖱️ mouseDown received for: \(item.name), location: \(pointInView)")
        
        if event.clickCount >= 2, item.isDirectory {
            if let monitor = globalEventMonitor {
                NSEvent.removeMonitor(monitor)
                globalEventMonitor = nil
            }
            hasStartedDrag = true
            shouldForwardClick = false
            NotificationCenter.default.post(name: .init("Shuttler.FileOpen"), object: item)
            return
        }
        
        // Set up global event monitor to track mouseDragged
        // This ensures we catch drag events even if the view hierarchy interferes
        print("🖱️ Setting up global event monitor for \(item.name)")
        globalEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] monitoredEvent in
            guard let self = self else {
                print("🖱️ Global monitor: self is nil")
                return monitoredEvent
            }
            
            print("🖱️ Global monitor: received event type \(monitoredEvent.type.rawValue)")
            
            if monitoredEvent.type == .leftMouseDragged {
                print("🖱️ Global monitor: mouseDragged detected for \(self.item.name)")
                // Check if mouse is over our view
                if let window = self.window, window == monitoredEvent.window {
                    let locationInWindow = monitoredEvent.locationInWindow
                    let locationInView = self.convert(locationInWindow, from: nil)
                    
                    print("🖱️ Global monitor: location in view: \(locationInView), bounds: \(self.bounds), contains: \(self.bounds.contains(locationInView))")
                    
                    if self.bounds.contains(locationInView) {
                        print("🖱️ Global monitor: calling handleMouseDragged")
                        self.handleMouseDragged(monitoredEvent)
                    } else {
                        print("🖱️ Global monitor: mouse not over view")
                    }
                } else {
                    print("🖱️ Global monitor: window mismatch or nil")
                }
            } else if monitoredEvent.type == .leftMouseUp {
                print("🖱️ Global monitor: mouseUp detected, hasStartedDrag: \(self.hasStartedDrag)")
                // Clean up monitor
                if let monitor = self.globalEventMonitor {
                    NSEvent.removeMonitor(monitor)
                    self.globalEventMonitor = nil
                }
                
                // If we didn't drag, forward the click via notification
                if !self.hasStartedDrag {
                    print("🖱️ Global monitor: posting FileClick notification")
                    NotificationCenter.default.post(name: .init("Shuttler.FileClick"), object: self.item)
                }
            }
            
            return monitoredEvent
        }
        
        print("🖱️ Global event monitor set up: \(globalEventMonitor != nil)")
        
        // Don't forward mouseDown - we'll handle clicks via notification
    }
    
    private func handleMouseDragged(_ event: NSEvent) {
        print("🖱️ handleMouseDragged called for: \(item.name)")
        
        // Only handle when connected
        guard isConnected, !hasStartedDrag else {
            print("🖱️ handleMouseDragged: skipping - isDirectory: \(item.isDirectory), isConnected: \(isConnected), hasStartedDrag: \(hasStartedDrag)")
            return
        }
        
        // Check if we've moved far enough to start a drag (threshold of 3 points)
        let currentPointInView = convert(event.locationInWindow, from: nil)
        
        let deltaX = abs(currentPointInView.x - mouseDownLocation.x)
        let deltaY = abs(currentPointInView.y - mouseDownLocation.y)
        
        print("🖱️ Drag delta: \(deltaX), \(deltaY), threshold: 3")
        
        // Only start drag if moved more than 3 points
        guard deltaX > 3 || deltaY > 3 else {
            print("🖱️ Drag delta too small, not starting drag")
            return
        }
        
        // Start the drag!
        hasStartedDrag = true
        shouldForwardClick = false
        
        print("🖱️ Starting drag session for file: \(item.name)")
        
        startDragSession(with: event)
    }
    
    override func mouseDragged(with event: NSEvent) {
        // This might be called directly, but handleMouseDragged will also be called via global monitor
        handleMouseDragged(event)
    }
    
    private func startDragSession(with event: NSEvent) {
        var draggingItems: [NSDraggingItem] = []
        
        if let remoteWriter = RemoteItemPasteboardWriter(item: item) {
            let remoteDraggingItem = NSDraggingItem(pasteboardWriter: remoteWriter)
            let remoteDragFrame = bounds.isEmpty ? NSRect(x: 0, y: 0, width: 100, height: 100) : bounds
            remoteDraggingItem.draggingFrame = remoteDragFrame
            remoteDraggingItem.imageComponentsProvider = {
                let component = NSDraggingImageComponent(key: .icon)
                let iconName = self.item.isDirectory ? "folder" : "doc"
                component.contents = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
                component.frame = NSRect(origin: .zero, size: NSSize(width: 32, height: 32))
                return [component]
            }
            draggingItems.append(remoteDraggingItem)
        }
        
        // Create file promise provider for Finder downloads.
        // Use the file's extension to determine the UTI, or fall back to data
        let fileExtension = (item.name as NSString).pathExtension.lowercased()
        var uti: String = item.isDirectory ? UTType.folder.identifier : UTType.data.identifier
        
        if !fileExtension.isEmpty {
            if let fileUTI = UTType(filenameExtension: fileExtension) {
                let identifier = fileUTI.identifier
                if !identifier.isEmpty {
                    uti = identifier
                }
            }
        }
        
        // Final fallback to ensure we always have a valid UTI
        if uti.isEmpty {
            uti = "public.data"
        }
        
        print("🖱️ Creating file promise provider with UTI: \(uti) for file: \(item.name)")
        
        // Create delegate and retain it (both the provider and we will retain it)
        let delegate = FilePromiseDelegate(item: item, browserVM: browserVM)
        self.filePromiseDelegate = delegate // Retain the delegate
        let filePromiseProvider = NSFilePromiseProvider(fileType: uti, delegate: delegate)
        
        // Create dragging item with the file promise provider
        let draggingItem = NSDraggingItem(pasteboardWriter: filePromiseProvider)
        
        // Use the bounds of the view for dragging frame
        let dragFrame = bounds.isEmpty ? NSRect(x: 0, y: 0, width: 100, height: 100) : bounds
        draggingItem.draggingFrame = dragFrame
        
        // Create a better drag image
        draggingItem.imageComponentsProvider = {
            let component = NSDraggingImageComponent(key: .icon)
            // Use a file icon that matches the file type
            let iconName = self.item.isDirectory ? "folder" : "doc"
            if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                component.contents = image
            } else {
                component.contents = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            }
            component.frame = NSRect(origin: .zero, size: NSSize(width: 32, height: 32))
            return [component]
        }
        
        draggingItems.append(draggingItem)
        
        // Start dragging session
        print("🖱️ Beginning drag session with \(draggingItem)")
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }
    
    override func mouseUp(with event: NSEvent) {
        // Clean up event monitor
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        
        // Forward mouseUp
        nextResponder?.mouseUp(with: event)
        hasStartedDrag = false
    }
    
    deinit {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard isConnected else {
            return []
        }
        return context == .outsideApplication ? .copy : [.copy, .move]
    }
    
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // Optional: Add any setup when drag begins
    }
    
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Optional: Track drag movement
    }
    
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        hasStartedDrag = false
    }
}
#endif

#Preview {
    ContentView()
}
