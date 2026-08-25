import SwiftUI

struct TransferWindow: View {
    @ObservedObject var manager: TransferManager = .shared
    @State private var showCompleted = true
    @State private var filterMode: FilterMode = .all
    
    enum FilterMode: String, CaseIterable {
        case all = "All"
        case active = "Active"
        case completed = "Completed"
        case failed = "Failed"
    }
    
    private var filteredTransfers: [ActiveTransfer] {
        switch filterMode {
        case .all:
            return manager.transfers
        case .active:
            return manager.activeTransfers
        case .completed:
            return manager.successfulTransfers
        case .failed:
            return manager.failedTransfers
        }
    }
    
    private var activeTransfers: [ActiveTransfer] {
        filteredTransfers.filter { !$0.isComplete }
    }
    
    private var completedTransfers: [ActiveTransfer] {
        filteredTransfers.filter { $0.isComplete }
    }
    
    private var windowTitle: String {
        if manager.hasActiveTransfers {
            return "\(manager.activeTransfers.count) Active"
        }
        if manager.failedTransfers.isEmpty {
            return "All Caught Up"
        }
        return "\(manager.failedTransfers.count) Failed"
    }
    
    private var completedCount: Int {
        manager.successfulTransfers.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            transferHeader
            .background(.bar, in: Rectangle())
            
            Divider()
            
            // Transfer list
            if filteredTransfers.isEmpty {
                VStack(spacing: AppTheme.Spacing.m) {
                    Image(systemName: "tray")
                        .font(.system(size: 56))
                        .foregroundStyle(.tertiary)
                    Text("No Transfers")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("File transfers will appear here")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Active transfers
                        if !activeTransfers.isEmpty {
                            ForEach(activeTransfers) { transfer in
                                TransferRow(transfer: transfer)
                                    .padding(.horizontal, AppTheme.Spacing.m)
                                    .padding(.vertical, AppTheme.Spacing.xs)
                                    .contextMenu {
                                        TransferContextMenu(transfer: transfer)
                                    }
                                Divider()
                                    .padding(.leading, 60)
                            }
                        }
                        
                        // Completed transfers
                        if showCompleted && !completedTransfers.isEmpty {
                            if !activeTransfers.isEmpty {
                                Divider()
                                    .padding(.vertical, 8)
                            }
                            
                            ForEach(completedTransfers) { transfer in
                                TransferRow(transfer: transfer)
                                    .padding(.horizontal, AppTheme.Spacing.m)
                                    .padding(.vertical, AppTheme.Spacing.xs)
                                    .contextMenu {
                                        TransferContextMenu(transfer: transfer)
                                    }
                                if transfer.id != completedTransfers.last?.id {
                                    Divider()
                                        .padding(.leading, 60)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 660, minHeight: 440)
        .background(.regularMaterial)
        .onAppear {
            #if os(macOS)
            NotificationCenter.default.post(name: .init("Shuttler.TransferWindowDidAppear"), object: nil)
            #endif
        }
        .onDisappear {
            #if os(macOS)
            NotificationCenter.default.post(name: .init("Shuttler.TransferWindowDidDisappear"), object: nil)
            #endif
        }
    }
    
    private var transferHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.m) {
                Image(systemName: manager.hasActiveTransfers ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(manager.hasActiveTransfers ? Color.accentColor : .green)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transfers")
                        .font(.system(size: 18, weight: .semibold))
                    Text(windowTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Picker("Filter", selection: $filterMode) {
                    ForEach(FilterMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
            }
            
            HStack(spacing: AppTheme.Spacing.s) {
                transferStat("Active", value: "\(manager.activeTransfers.count)", icon: "bolt.fill")
                transferStat("Done", value: "\(completedCount)", icon: "checkmark.circle.fill")
                transferStat("Failed", value: "\(manager.failedTransfers.count)", icon: "exclamationmark.triangle.fill")
                
                Spacer()
                
                Button {
                    showCompleted.toggle()
                } label: {
                    Label(showCompleted ? "Hide Done" : "Show Done", systemImage: showCompleted ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                
                if !completedTransfers.isEmpty {
                    Button("Clear Done") {
                        withAnimation {
                            manager.clearCompleted()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.m)
        .padding(.vertical, AppTheme.Spacing.m)
    }
    
    private func transferStat(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.35), in: Capsule())
    }
}

struct TransferRow: View {
    let transfer: ActiveTransfer
    @ObservedObject var manager: TransferManager = .shared
    
    private var speedString: String {
        if transfer.isComplete {
            return "Complete"
        } else if transfer.bytesPerSecond > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .binary
            return "\(formatter.string(fromByteCount: Int64(transfer.bytesPerSecond)))/s"
        } else {
            return "Starting..."
        }
    }
    
    private var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        if let total = transfer.bytesTotal {
            return "\(formatter.string(fromByteCount: transfer.bytesTransferred)) of \(formatter.string(fromByteCount: total))"
        } else {
            return formatter.string(fromByteCount: transfer.bytesTransferred)
        }
    }
    
    private var timeRemaining: String? {
        guard !transfer.isComplete,
              transfer.bytesPerSecond > 0,
              let total = transfer.bytesTotal,
              total > transfer.bytesTransferred else {
            return nil
        }
        
        let remainingBytes = total - transfer.bytesTransferred
        let secondsRemaining = Double(remainingBytes) / transfer.bytesPerSecond
        
        if secondsRemaining < 60 {
            return "\(Int(secondsRemaining))s remaining"
        } else if secondsRemaining < 3600 {
            let minutes = Int(secondsRemaining / 60)
            let seconds = Int(secondsRemaining.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s remaining"
        } else {
            let hours = Int(secondsRemaining / 3600)
            let minutes = Int((secondsRemaining.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)m remaining"
        }
    }
    
    private var elapsedTime: String {
        let elapsed = Date().timeIntervalSince(transfer.startedAt)
        if elapsed < 60 {
            return "\(Int(elapsed))s"
        } else if elapsed < 3600 {
            return "\(Int(elapsed / 60))m"
        } else {
            return "\(Int(elapsed / 3600))h"
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Direction icon
            ZStack {
                Circle()
                    .fill(transfer.direction == .upload 
                          ? Color.blue.opacity(0.15) 
                          : Color.green.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: transfer.direction == .upload ? "arrow.up" : "arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(transfer.direction == .upload ? .blue : .green)
            }
            
            // Content
            VStack(alignment: .leading, spacing: 8) {
                // File name and status
                HStack {
                    Text(transfer.name)
                        .lineLimit(1)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    if transfer.isComplete {
                        HStack(spacing: 4) {
                            Image(systemName: transfer.hasError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 14))
                            Text(transfer.hasError ? "Failed" : "Done")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(transfer.hasError ? .red : .green)
                    } else {
                        Button {
                            withAnimation {
                                manager.cancel(id: transfer.id)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Cancel transfer")
                    }
                }
                
                // Error message
                if transfer.hasError, let errorMsg = transfer.errorMessage {
                    Text(errorMsg)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 6)
                        
                        // Progress
                        RoundedRectangle(cornerRadius: 3)
                            .fill(transfer.hasError ? Color.red : (transfer.direction == .upload ? Color.blue : Color.green))
                            .frame(width: geometry.size.width * transfer.progress, height: 6)
                            .animation(.easeInOut, value: transfer.progress)
                    }
                }
                .frame(height: 6)
                
                // Stats row
                HStack {
                    // Size
                    Label(sizeString, systemImage: "doc")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    // Percentage
                    Text("\(Int(transfer.progress * 100))%")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                
                // Speed and time
                HStack {
                    if transfer.isComplete {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            Text("Completed in \(elapsedTime)")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    } else {
                        HStack(spacing: 12) {
                            if transfer.bytesPerSecond > 0 {
                                Label(speedString, systemImage: "speedometer")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            
                            if let remaining = timeRemaining {
                                Label(remaining, systemImage: "timer")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    Spacer()
                }
            }
        }
        .opacity(transfer.isComplete && !transfer.hasError ? 0.7 : 1.0)
        .animation(.easeInOut, value: transfer.isComplete)
    }
}

struct TransferContextMenu: View {
    let transfer: ActiveTransfer
    @ObservedObject var manager = TransferManager.shared
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        if transfer.isComplete {
            if let localPath = transfer.localPath, !localPath.isEmpty {
                Button {
                    #if os(macOS)
                    let url = URL(fileURLWithPath: localPath)
                    NSWorkspace.shared.selectFile(localPath, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    #endif
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }
            
            if let remotePath = transfer.remotePath, !remotePath.isEmpty {
                Button {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(remotePath, forType: .string)
                    #endif
                } label: {
                    Label("Copy Remote Path", systemImage: "doc.on.doc")
                }
            }
            
            if transfer.hasError {
                Divider()
                Button {
                    manager.retryTransfer(transfer)
                    // Note: Actual retry would need to be implemented by the caller
                    // This just resets the error state
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
        }
        
        Divider()
        
        Button(role: .destructive) {
            manager.transfers.removeAll { $0.id == transfer.id }
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }
}

#Preview {
    TransferWindow()
        .frame(width: 500, height: 400)
}
