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
    @State private var sidebarVisible: Bool = true
    @AppStorage(AppSettingsKeys.listDensity) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    @State private var triggerNewConnection = UUID()
    @State private var triggerRefresh = UUID()
    @State private var transferWindowVisible = false

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

    var body: some View {
        ZStack(alignment: .leading) {
            // Main content - always full width
            Group {
                if let id = selection, let connection = store.connection(id: id) {
                    VStack(spacing: 0) {
                        // Ribbon - responsive layout
                        GeometryReader { geometry in
                            let isCompact = geometry.size.width < 800
                            let isVeryCompact = geometry.size.width < 600
                            
                            HStack(spacing: isVeryCompact ? AppTheme.Spacing.s : AppTheme.Spacing.l) {
                                // Connection group
                                HStack(spacing: AppTheme.Spacing.s) {
                                    Button { NotificationCenter.default.post(name: .init("Shuttler.Refresh"), object: nil) } label: { 
                                        if isCompact {
                                            Image(systemName: "arrow.clockwise")
                                        } else {
                                            Label("Refresh", systemImage: "arrow.clockwise")
                                        }
                                    }
                                    Button { NotificationCenter.default.post(name: .init("Shuttler.NewConnection"), object: nil) } label: { 
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

                                // Transfer group
                                HStack(spacing: AppTheme.Spacing.s) {
                                    Button { NotificationCenter.default.post(name: .init("Shuttler.Download"), object: nil) } label: { 
                                        if isCompact {
                                            Image(systemName: "arrow.down.circle")
                                        } else {
                                            Label("Download", systemImage: "arrow.down.circle")
                                        }
                                    }
                                    Button { NotificationCenter.default.post(name: .init("Shuttler.Upload"), object: nil) } label: { 
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

                                // View group - adapts to available space
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
                                            Toggle(isOn: $sortAscending) { Image(systemName: sortAscending ? "arrow.up" : "arrow.down") }
                                            Toggle("Folders first", isOn: $foldersFirst)
                                        }
                                    }
                                    
                                    // Sidebar toggle button - separate with divider to avoid overlap
                                    Divider().frame(height: 20)
                                    
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.25)) {
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
                                    // Very compact: show only sidebar toggle
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            sidebarVisible.toggle()
                                        }
                                    } label: { 
                                        Image(systemName: sidebarVisible ? "sidebar.leading" : "sidebar.left")
                                    }
                                    
                                    // Menu for view options in very compact mode
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
                                
                                // Transfer indicator - shows when transfers are active but window is closed
                                if shouldShowTransferIndicator {
                                    transferIndicatorBadge
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 44)
                        .background(.thickMaterial)

                        RemoteBrowserView(connection: connection)
                            .environmentObject(store)
                            .id(connection.id)
                    }
                } else {
                    WelcomeView(showingNewConnection: $showingNewConnection)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Sidebar - overlays on top with smooth animation
            SidebarView(selection: $selection, query: $query, showingNewConnection: $showingNewConnection, editingConnection: $editingConnection, sidebarVisible: $sidebarVisible)
                .environmentObject(store)
                .searchable(text: $query, placement: .sidebar, prompt: "Search Connections")
                .frame(width: 240)
                .background(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 10, x: 3, y: 0)
                .offset(x: sidebarVisible ? 0 : -240)
                .animation(.easeInOut(duration: 0.25), value: sidebarVisible)
            
            // Floating button to reopen sidebar when closed
            if !sidebarVisible {
                VStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            sidebarVisible = true
                        }
                    } label: {
                        Image(systemName: "sidebar.leading")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .padding(8)
                            .background(.regularMaterial)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Show Sidebar")
                    .padding(.leading, 8)
                    Spacer()
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity.combined(with: .move(edge: .leading)))
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
            // Sidebar header with close button
            HStack {
                Text("Connections")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        sidebarVisible = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Sidebar")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            
            VStack {
                List {
                    // Favorites
                    Section {
                        ForEach(favorites, id: \.id) { conn in
                            connectionRow(conn)
                        }
                    } header: {
                        HStack {
                            Text("Favorites")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                            Spacer()
                        }
                    }

                    // Connections
                    Section {
                        ForEach(others, id: \.id) { conn in
                            connectionRow(conn)
                                .onDrag { NSItemProvider(object: conn.id.uuidString as NSString) }
                        }
                        .onMove { indices, newOffset in
                            store.moveConnections(indices: indices, to: newOffset)
                        }
                    } header: {
                        HStack {
                            Text("Connections")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                            Spacer()
                        }
                    }
                }
                .listStyle(.sidebar)
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
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: conn.protocolType.iconName)
                .foregroundStyle(conn.protocolType.tint)
            VStack(alignment: .leading) {
                Text(conn.name).font(.headline)
                Text("\(conn.username)@\(conn.host):\(conn.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .padding(.horizontal, 4)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .background((selection == conn.id) ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            // Single click: select and close sidebar
            selection = conn.id
            withAnimation(.easeInOut(duration: 0.25)) {
                sidebarVisible = false
            }
        }
        .onTapGesture(count: 2) {
            // Double-click: select, close sidebar, and connect
            selection = conn.id
            withAnimation(.easeInOut(duration: 0.25)) {
                sidebarVisible = false
            }
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
            Button(role: .destructive) { 
                handleConnectionDelete(conn: conn)
            } label: { 
                Label("Delete", systemImage: "trash") 
            }
        }
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
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 64, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            
            VStack(spacing: 12) {
                Text("Welcome to Shuttler")
                    .font(.system(size: 32, weight: .bold))
                Text("Create a connection to get started")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                VStack(spacing: 8) {
                    FeatureBadge(icon: "lock.shield.fill", text: "FTP, SFTP, and SCP support")
                    FeatureBadge(icon: "arrow.up.arrow.down", text: "Drag-and-drop transfers")
                    FeatureBadge(icon: "bolt.fill", text: "Fast native transfers")
                }
                .padding(.top, 8)
            }
            
            Button {
                showingNewConnection = true
            } label: {
                Label("New Connection", systemImage: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

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
            self._draft = State(initialValue: Connection.example())
            self.isEditing = false
            print("NewConnectionView init: Creating new connection")
        }
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $draft.name)
                Picker("Protocol", selection: $draft.protocolType) {
                    ForEach(ProtocolType.allCases) { proto in
                        Text(proto.displayName).tag(proto)
                    }
                }
                TextField("Host", text: $draft.host)
                TextField("Port", value: $draft.port, formatter: NumberFormatter())
                TextField("Username", text: $draft.username)
                SecureField("Password (optional)", text: Binding<String>(
                    get: { draft.password ?? "" },
                    set: { draft.password = $0.isEmpty ? nil : $0 }
                ))
                Toggle("Use Key Authentication", isOn: $draft.usesKeyAuth)
                if draft.usesKeyAuth {
                    TextField("Private Key Path", text: Binding<String>(
                        get: { draft.privateKeyPath ?? "" },
                        set: { draft.privateKeyPath = $0.isEmpty ? nil : $0 }
                    ))
                }
                TextField("Starting Directory (optional)", text: Binding<String>(
                    get: { draft.startingDirectory ?? "" },
                    set: { draft.startingDirectory = $0.isEmpty ? nil : $0 }
                ))
                .help("Optional: Directory to start in when connecting (e.g., /home/username)")
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Connection" : "New Connection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }.disabled(draft.name.isEmpty || draft.host.isEmpty || draft.username.isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }
}

// RemoteBrowserView supports single selection for downloads
struct RemoteBrowserView: View {
    let connection: Connection
    @EnvironmentObject var store: ConnectionsStore
    @Environment(\.openWindow) var openWindow
    @StateObject private var browserVM: RemoteBrowserViewModel
    @State private var errorMessage: String?
    @State private var showingUploadPicker = false
    @State private var downloadDestination: URL? = nil
    @State private var showingConnectionProgress = false
    @State private var showingUploadConflict = false
    @State private var uploadConflictResolution: (localURL: URL, existingItem: RemoteItem)?
    @State private var showingPasswordPrompt = false
    @State private var showingRenameDialog = false
    @State private var renameText = ""
    @State private var showingDisconnectConfirmation = false
    @State private var currentConnection: Connection

    @State private var selectedItem: RemoteItem? = nil
    @State private var pathComponents: [String] = ["/"]
    @AppStorage(AppSettingsKeys.listDensity) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    @AppStorage(AppSettingsKeys.sortKey) private var sortKeyRaw: String = SortKey.name.rawValue
    @AppStorage(AppSettingsKeys.sortAscending) private var sortAscending: Bool = true
    @AppStorage(AppSettingsKeys.foldersFirst) private var foldersFirst: Bool = true

    init(connection: Connection) {
        self.connection = connection
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
        VStack(spacing: 0) {
            headerView
            fileListView
        }
        .alert("Error", isPresented: isShowingError) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("File Already Exists", isPresented: $showingUploadConflict) {
            if let conflict = uploadConflictResolution {
                Button("Overwrite", role: .destructive) {
                    Task {
                        do {
                            try await browserVM.uploadWithResolution(conflict.localURL, overwrite: true)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    uploadConflictResolution = nil
                }
                Button("Keep Both") {
                    Task {
                        do {
                            try await browserVM.uploadWithResolution(conflict.localURL, overwrite: false)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    uploadConflictResolution = nil
                }
                Button("Cancel", role: .cancel) {
                    uploadConflictResolution = nil
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
        .onChange(of: connection.id) { oldValue, newValue in
            // Update when connection changes
            currentConnection = connection
            browserVM.updateConnection(connection)
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
    }
    
    private var headerView: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let isCompact = geometry.size.width < 700
                let isVeryCompact = geometry.size.width < 500
                
                HStack(spacing: AppTheme.Spacing.s) {
                    if !isVeryCompact {
                        Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
                        Text("\(connection.protocolType.displayName) • \(connection.name)")
                            .font(.headline)
                            .lineLimit(1)
                    } else {
                        // Very compact: just show icon and name
                        Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
                        Text(connection.name)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    if !browserVM.directoryHistory.isEmpty {
                        Button {
                            Task {
                                do {
                                    try await browserVM.goBack()
                                    let currentDirectory = browserVM.currentDirectory
                                    let comps = currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                                    pathComponents = comps.isEmpty ? ["/"] : comps
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
                                guard let item = selectedItem else {
                                    errorMessage = "Select a file or folder to download."
                                    return
                                }
                                if let url = NSOpenPanel.chooseDirectory() {
                                    downloadDestination = url
                                    Task {
                                        do {
                                            try await browserVM.download(item, to: url)
                                        } catch {
                                            errorMessage = error.localizedDescription
                                        }
                                    }
                                }
                            } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                            
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
                .padding(8)
            }
            .frame(height: 40)
            .background(.bar)
            
            pathView
        }
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
                    if !currentConnection.usesKeyAuth && currentConnection.password == nil {
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
            }
        }
        .sheet(isPresented: $showingPasswordPrompt) {
            PasswordPromptView(connection: currentConnection, isPresented: $showingPasswordPrompt) { password, savePassword in
                // Update connection with password
                var updatedConnection = currentConnection
                updatedConnection.password = password
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
                let currentDirectory = browserVM.currentDirectory
                let comps = currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                pathComponents = comps.isEmpty ? ["/"] : comps
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
            downloadButton
            uploadButton
            quickLookButton
        }
    }
    
    private var downloadButton: some View {
        Button {
            guard let item = selectedItem else {
                errorMessage = "Select a file or folder to download."
                return
            }
            if let url = NSOpenPanel.chooseDirectory() {
                downloadDestination = url
                // Run download - it's now non-blocking internally
                Task {
                    do {
                        try await browserVM.download(item, to: url)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
        .keyboardShortcut(.return, modifiers: [])
    }
    
    private var uploadButton: some View {
        Button {
            showingUploadPicker = true
        } label: {
            Label("Upload", systemImage: "arrow.up.circle")
        }
        .keyboardShortcut("u", modifiers: [.command])
    }
    
    private var quickLookButton: some View {
        Button {
            guard let item = selectedItem else {
                errorMessage = "Select an item to preview."
                return
            }
            #if os(macOS)
            // For Quick Look, we need to download the file temporarily
            if !item.isDirectory {
                Task {
                    do {
                        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                        let tempFile = tempDir.appendingPathComponent(item.name)
                        try await browserVM.download(item, to: tempDir)
                        // Use Quick Look via qlmanage
                        let qlProcess = Process()
                        qlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
                        qlProcess.arguments = ["-p", tempFile.path]
                        try? qlProcess.run()
                        // Clean up after a delay
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
        .keyboardShortcut(.space, modifiers: [])
    }
    
    private var pathView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(pathComponents.enumerated()), id: \.offset) { idx, comp in
                    HStack(spacing: 5) {
                        if idx == 0 {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 11))
                        }
                        Text(idx == 0 ? "/" : comp)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    if idx < pathComponents.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 2)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.thinMaterial)
    }
    
    @ViewBuilder
    private var fileListView: some View {
        let items = sortedItems(browserVM.items)
        
        fileListContent(items: items)
            .onAppear {
                // Debug: log items count and check for ubuntu file
                print("📋 UI: Displaying \(items.count) items from \(browserVM.items.count) parsed items")
                if let ubuntuItem = items.first(where: { $0.name.contains("ubuntu") }) {
                    if let ubuntuIndex = items.firstIndex(where: { $0.name.contains("ubuntu") }) {
                        print("✅ UI: Ubuntu file found in display list at index \(ubuntuIndex): \(ubuntuItem.name) at path: \(ubuntuItem.path)")
                    }
                    // Print the last 5 items to verify ordering
                    print("📋 Last 5 items in sorted list:")
                    for (idx, item) in items.suffix(5).enumerated() {
                        let actualIdx = items.count - 5 + idx
                        print("   [\(actualIdx)] \(item.name) - path: \(item.path)")
                    }
                } else {
                    print("❌ UI: Ubuntu file NOT found in display list")
                    // Check if it's in the raw items
                    if let ubuntuRaw = browserVM.items.first(where: { $0.name.contains("ubuntu") }) {
                        print("⚠️ UI: Ubuntu file found in browserVM.items but not in sorted items: \(ubuntuRaw.name) at path: \(ubuntuRaw.path)")
                    }
                }
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
            .overlay(alignment: .bottom) {
                fileListStatusBar
            }
    }
    
    @ViewBuilder
    private func fileListContent(items: [RemoteItem]) -> some View {
        ZStack {
            fileList(items: items)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleFileDrop(providers: providers)
                }
            
            if browserVM.isLoading {
                loadingView
            } else if browserVM.items.isEmpty {
                emptyStateView
            }
        }
    }
    
    @ViewBuilder
    private func fileList(items: [RemoteItem]) -> some View {
        List {
            ForEach(Array(items.enumerated()), id: \.element.path) { index, item in
                fileListItem(item: item)
                    .id("\(item.path)-\(index)")
                    .listRowSeparatorTint(Color(white: 0.85))
                    .listRowSeparator(.visible, edges: .bottom)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                    .onAppear {
                        // Debug: log when ubuntu file appears
                        if item.name.contains("ubuntu") {
                            print("✅ RENDERED: Ubuntu file at index \(index) - name='\(item.name)', path='\(item.path)'")
                        }
                    }
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
    private func fileListItem(item: RemoteItem) -> some View {
        let isSelected = selectedItem?.path == item.path
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
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer(minLength: 8)
            
            // File size
            Text(item.sizeString)
                .font(.system(size: density == .comfortable ? 12 : 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, rowPadding)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handleItemTap(item: item)
        }
        .contextMenu {
            fileItemContextMenu(item: item)
        }
        #if os(macOS)
        .onDrag {
            guard !item.isDirectory, browserVM.isConnected else { return NSItemProvider() }
            let provider = FilePromiseProvider(fileType: UTType.data.identifier, delegate: FilePromiseDelegate(item: item, browserVM: browserVM))
            return provider as Any as? NSItemProvider ?? NSItemProvider()
        }
        #endif
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
        Button {
            handleContextMenuDownload(item: item)
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
        
        if !item.isDirectory {
            Button {
                handleContextMenuRename(item: item)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            
            Button {
                handleContextMenuEdit(item: item)
            } label: {
                Label("Edit", systemImage: "pencil.line")
            }
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
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text("This folder is empty")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            Button { 
                showingUploadPicker = true 
            } label: { 
                Label("Upload Files", systemImage: "arrow.up.circle.fill")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial.opacity(0.3))
    }
    
    private var fileListStatusBar: some View {
        HStack(spacing: 12) {
            Text("\(browserVM.items.count) item\(browserVM.items.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let sel = selectedItem {
                Divider()
                    .frame(height: 12)
                HStack(spacing: 6) {
                    Image(systemName: sel.isDirectory ? "folder.fill" : "doc.fill")
                        .font(.system(size: 10))
                    Text(sel.name)
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .background(.bar)
    }
    
    // MARK: - Helper Methods
    
    private func handleItemTap(item: RemoteItem) {
        selectedItem = item
        if item.isDirectory {
            Task {
                do {
                    try await browserVM.open(item)
                    let currentDirectory = browserVM.currentDirectory
                    let comps = currentDirectory.rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                    pathComponents = comps.isEmpty ? ["/"] : comps
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func handleContextMenuDownload(item: RemoteItem) {
        selectedItem = item
        if let url = NSOpenPanel.chooseDirectory() {
            Task {
                do {
                    try await browserVM.download(item, to: url)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
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
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = "Delete \"\(item.name)\"?"
        alert.informativeText = item.isDirectory 
            ? "This folder and all its contents will be permanently deleted. This action cannot be undone."
            : "This file will be permanently deleted. This action cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            Task {
                do {
                    try await browserVM.delete(item)
                } catch {
                    errorMessage = "Failed to delete: \(error.localizedDescription)"
                }
            }
        }
        #else
        Task {
            do {
                try await browserVM.delete(item)
            } catch {
                errorMessage = "Failed to delete: \(error.localizedDescription)"
            }
        }
        #endif
    }
    
    
    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        guard browserVM.isConnected else {
            errorMessage = "Not connected. Please connect first."
            return false
        }
        
        Task {
            await processFileDrop(providers: providers)
        }
        
        return true
    }
    
    private func processFileDrop(providers: [NSItemProvider]) async {
        var uploadErrors: [String] = []
        var uploadCount = 0
        
        await withTaskGroup(of: (success: Bool, error: String?)?.self) { group in
            for provider in providers {
                group.addTask {
                    await self.processFileProvider(provider: provider)
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
    
    private func processFileProvider(provider: NSItemProvider) async -> (success: Bool, error: String?)? {
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
            try await browserVM.upload(url)
            return (success: true, error: nil)
        } catch let error as UploadConflictError {
            // Handle conflict - set state for alert
            await MainActor.run {
                uploadConflictResolution = (localURL: error.localURL, existingItem: error.existingItem)
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
                for url in urls {
                    do {
                        try await browserVM.upload(url)
                    } catch let error as UploadConflictError {
                        // Handle conflict - set state for alert
                        await MainActor.run {
                            uploadConflictResolution = (localURL: error.localURL, existingItem: error.existingItem)
                            showingUploadConflict = true
                        }
                        // Break to wait for user decision on first conflict
                        break
                    } catch {
                        errorMessage = error.localizedDescription
                        break
                    }
                }
            }
        case .failure(let err):
            errorMessage = err.localizedDescription
        }
    }
    
    private func handleDownloadNotification() {
        guard let item = selectedItem else {
            errorMessage = "Select a file or folder to download."
            return
        }
        if let url = NSOpenPanel.chooseDirectory() {
            downloadDestination = url
            Task {
                do {
                    try await browserVM.download(item, to: url)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func sortedItems(_ items: [RemoteItem]) -> [RemoteItem] {
        // Debug: check for ubuntu file before sorting
        if let ubuntuBefore = items.first(where: { $0.name.contains("ubuntu") }) {
            print("🔍 Before sorting: Found ubuntu file - name='\(ubuntuBefore.name)', path='\(ubuntuBefore.path)'")
        } else {
            print("❌ Before sorting: Ubuntu file NOT found in items array")
            print("   Total items: \(items.count)")
            print("   Sample names: \(items.prefix(5).map { $0.name }.joined(separator: ", "))")
        }
        
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
        
        // Debug: check for ubuntu file after sorting
        if let ubuntuAfter = result.first(where: { $0.name.contains("ubuntu") }) {
            print("✅ After sorting: Found ubuntu file at index \(result.firstIndex(where: { $0.name.contains("ubuntu") }) ?? -1) - name='\(ubuntuAfter.name)', path='\(ubuntuAfter.path)'")
        } else {
            print("❌ After sorting: Ubuntu file NOT found in sorted result")
        }
        
        return result
    }
}

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
}
#endif

#if os(macOS)
// File promise delegate for drag and drop downloads
class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let item: RemoteItem
    let browserVM: RemoteBrowserViewModel
    
    init(item: RemoteItem, browserVM: RemoteBrowserViewModel) {
        self.item = item
        self.browserVM = browserVM
    }
    
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        return item.name
    }
    
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        // This is called only when the file is actually dropped
        // Run download in background - non-blocking
        Task.detached { [weak self] in
            guard let self = self else {
                completionHandler(NSError(domain: "Shuttler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download failed"]))
                return
            }
            
            do {
                let destinationDir = url.deletingLastPathComponent()
                try await self.browserVM.download(self.item, to: destinationDir)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}

// Custom NSFilePromiseProvider that works with SwiftUI
class FilePromiseProvider: NSFilePromiseProvider {
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        return [.fileURL]
    }
}
#endif

#Preview {
    ContentView()
}

