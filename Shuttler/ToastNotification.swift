//
//  ToastNotification.swift
//  Shuttler
//
//  Toast-style inline error and notification system
//

import SwiftUI
import Combine

enum ToastType {
    case error
    case success
    case info
    case warning
    
    var icon: String {
        switch self {
        case .error: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .error: return .red
        case .success: return .green
        case .info: return .blue
        case .warning: return .orange
        }
    }
}

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    let type: ToastType
    let duration: TimeInterval
    
    init(_ message: String, type: ToastType = .error, duration: TimeInterval = 4.0) {
        self.message = message
        self.type = type
        self.duration = duration
    }
}

@MainActor
final class ToastManager: ObservableObject {
    static let shared = ToastManager()
    
    @Published var toasts: [Toast] = []
    
    private init() {}
    
    func show(_ message: String, type: ToastType = .error, duration: TimeInterval = 4.0) {
        let toast = Toast(message, type: type, duration: duration)
        toasts.append(toast)
        
        // Auto-dismiss after duration
        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            await MainActor.run {
                toasts.removeAll { $0.id == toast.id }
            }
        }
    }
    
    func dismiss(_ toast: Toast) {
        toasts.removeAll { $0.id == toast.id }
    }
}

struct ToastView: View {
    let toast: Toast
    @ObservedObject var manager = ToastManager.shared
    
    var body: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            Image(systemName: toast.type.icon)
                .foregroundStyle(toast.type.color)
                .font(.system(size: 14, weight: .semibold))
            
            Text(toast.message)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(3)
            
            Spacer()
            
            Button {
                manager.dismiss(toast)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppTheme.Spacing.m)
        .padding(.vertical, AppTheme.Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        .frame(maxWidth: 400)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct ToastContainer: View {
    @ObservedObject var manager = ToastManager.shared
    
    var body: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            ForEach(manager.toasts) { toast in
                ToastView(toast: toast)
            }
        }
        .padding(.top, AppTheme.Spacing.m)
        .padding(.trailing, AppTheme.Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(true)
    }
}
