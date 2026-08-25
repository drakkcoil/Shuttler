import Foundation
import SwiftUI
import Combine
#if os(macOS)
import UserNotifications
#endif

enum TransferDirection: String, Codable { case upload, download }

struct ActiveTransfer: Identifiable, Equatable {
    let id: UUID
    let name: String
    let direction: TransferDirection
    var progress: Double // 0...1
    var startedAt: Date
    var bytesTotal: Int64?
    var bytesTransferred: Int64
    var bytesPerSecond: Double = 0
    var lastUpdateTime: Date = Date()
    var lastBytesTransferred: Int64 = 0
    var isComplete: Bool = false
    var hasError: Bool = false
    var errorMessage: String?
    var remotePath: String?
    var localPath: String?
}

@MainActor
final class TransferManager: ObservableObject {
    static let shared = TransferManager()

    @Published var transfers: [ActiveTransfer] = []
    @Published var isExpanded: Bool = false
    @Published var isWindowVisible: Bool = false

    private var timers: [UUID: Timer] = [:]
    private var cancellationTasks: [UUID: Any] = [:] // Store any Task type for cancellation

    func start(name: String, direction: TransferDirection, totalBytes: Int64? = nil, remotePath: String? = nil, localPath: String? = nil) -> UUID {
        let id = UUID()
        let now = Date()
        let t = ActiveTransfer(id: id, name: name, direction: direction, progress: 0, startedAt: now, bytesTotal: totalBytes, bytesTransferred: 0, bytesPerSecond: 0, lastUpdateTime: now, lastBytesTransferred: 0, isComplete: false, hasError: false, errorMessage: nil, remotePath: remotePath, localPath: localPath)
        transfers.append(t)
        isExpanded = true
        
        #if os(macOS)
        NotificationCenter.default.post(name: .init("Shuttler.ShowTransfers"), object: nil)
        #endif
        
        // If totalBytes is nil, simulate progress
        if totalBytes == nil {
            let transferId = id
            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    guard let idx = self.transfers.firstIndex(where: { $0.id == transferId }) else {
                        self.invalidateTimer(id: transferId)
                        return
                    }
                    var transfer = self.transfers[idx]
                    // Increment progress by 0.05 each tick until reaching 1.0
                    if transfer.progress < 1.0 {
                        transfer.progress = min(1.0, transfer.progress + 0.05)
                        self.transfers[idx] = transfer
                    } else {
                        // Progress complete, finish transfer
                        self.finish(id: transferId)
                        self.invalidateTimer(id: transferId)
                    }
                }
            }
            timers[id] = timer
        }

        return id
    }

    func update(id: UUID, bytesTransferred: Int64, totalBytes: Int64?) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        var t = transfers[idx]
        let now = Date()
        
        // Calculate transfer speed
        let timeDelta = now.timeIntervalSince(t.lastUpdateTime)
        if timeDelta > 0.1 { // Update speed at most every 100ms
            let bytesDelta = Double(bytesTransferred - t.lastBytesTransferred)
            t.bytesPerSecond = bytesDelta / timeDelta
            t.lastUpdateTime = now
            t.lastBytesTransferred = bytesTransferred
        }
        
        t.bytesTransferred = bytesTransferred
        t.bytesTotal = totalBytes ?? t.bytesTotal
        if let total = t.bytesTotal, total > 0 {
            let calculatedProgress = Double(bytesTransferred) / Double(total)
            // If bytesTransferred equals or exceeds total, force progress to exactly 1.0
            if bytesTransferred >= total {
                t.progress = 1.0
                print("📊 TransferManager: Forcing progress to 1.0 (100%) for transfer \(id.uuidString.prefix(8)) - \(bytesTransferred)/\(total), current progress value: \(t.progress)")
            } else {
                t.progress = min(1.0, calculatedProgress)
            }
            // Mark as complete when progress reaches 100%, but add a small delay to ensure UI updates
            if t.progress >= 1.0 && !t.isComplete {
                // Don't mark complete immediately - let UI show 100% first
                // The finish() method will be called separately
                print("📊 TransferManager: Progress at 100% for transfer \(id.uuidString.prefix(8)), but not marking complete yet (will be marked by finish())")
            }
        } else {
            // Simulated linear progress if total is unknown
            t.progress = min(1.0, max(t.progress, 0.1))
        }
        transfers[idx] = t
        print("📊 TransferManager: Updated transfer \(id.uuidString.prefix(8)) - progress: \(t.progress) (\(Int(t.progress * 100))%), bytes: \(t.bytesTransferred)/\(t.bytesTotal ?? 0)")
    }

    func finish(id: UUID, withError: Error? = nil) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else {
            print("⚠️ TransferManager: Cannot finish transfer \(id.uuidString.prefix(8)) - not found in transfers list (count: \(transfers.count))")
            return
        }
        var t = transfers[idx]
        print("📊 TransferManager: Finishing transfer \(id.uuidString.prefix(8)) - current progress: \(t.progress) (\(Int(t.progress * 100))%), isComplete: \(t.isComplete)")
        
        if let error = withError {
            t.hasError = true
            t.errorMessage = error.localizedDescription
        } else {
            // Ensure progress is at 100% when finishing successfully
            if let total = t.bytesTotal, total > 0 {
                t.progress = 1.0
                t.bytesTransferred = total // Ensure bytes match total
            }
        }
        t.isComplete = true
        transfers[idx] = t
        
        print("✅ TransferManager: Finished transfer \(id.uuidString.prefix(8)) - progress: \(t.progress) (\(Int(t.progress * 100))%), isComplete: \(t.isComplete), hasError: \(t.hasError), bytesTransferred: \(t.bytesTransferred)/\(t.bytesTotal ?? 0)")
        
        // Send notification for completed transfers
        #if os(macOS)
        if let error = withError {
            sendNotification(title: "Transfer Failed", body: "\(t.name) failed: \(error.localizedDescription)", isError: true)
        } else {
            sendNotification(title: "Transfer Complete", body: "\(t.name) completed successfully", isError: false)
        }
        #endif
        
        // Trigger UI update by accessing @Published property
        objectWillChange.send()
    }
    
    #if os(macOS)
    private func sendNotification(title: String, body: String, isError: Bool) {
        // Use UserNotifications framework for modern notifications
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if isError {
            content.sound = .default
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    #endif
    
    func clearCompleted() {
        transfers.removeAll { $0.isComplete }
    }
    
    var activeTransfers: [ActiveTransfer] {
        transfers.filter { !$0.isComplete }
    }
    
    var failedTransfers: [ActiveTransfer] {
        transfers.filter { $0.isComplete && $0.hasError }
    }
    
    var successfulTransfers: [ActiveTransfer] {
        transfers.filter { $0.isComplete && !$0.hasError }
    }
    
    var hasActiveTransfers: Bool {
        !activeTransfers.isEmpty
    }
    
    func retryTransfer(_ transfer: ActiveTransfer) {
        // This would need to be implemented by the caller
        // as we don't have enough context here to retry
        // Just remove the error state for now
        if let idx = transfers.firstIndex(where: { $0.id == transfer.id }) {
            var t = transfers[idx]
            t.hasError = false
            t.errorMessage = nil
            t.isComplete = false
            t.progress = 0
            t.bytesTransferred = 0
            transfers[idx] = t
        }
    }
    
    func cancel(id: UUID) {
        if let cancelFunc = cancellationTasks[id] as? () -> Void {
            cancelFunc()
            cancellationTasks.removeValue(forKey: id)
        }
        finish(id: id)
    }
    
    func registerCancellationTask(id: UUID, task: Any) {
        // Store a cancellation closure
        if let downloadTask = task as? Task<Void, Error> {
            cancellationTasks[id] = { downloadTask.cancel() }
        } else if let uploadTask = task as? Task<Void, Never> {
            cancellationTasks[id] = { uploadTask.cancel() }
        }
    }
    
    func registerCancellationTask(id: UUID, cancellationClosure: @escaping () -> Void) {
        cancellationTasks[id] = cancellationClosure
    }

    private func invalidateTimer(id: UUID) {
        if let timer = timers[id] {
            timer.invalidate()
            timers.removeValue(forKey: id)
        }
    }
}
