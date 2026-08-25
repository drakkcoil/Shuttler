//
//  ConnectionProgressView.swift
//  Shuttler
//
//  Connection progress dialog with verbose output
//

import SwiftUI

struct ConnectionProgressView: View {
    let connection: Connection
    @Binding var isPresented: Bool
    @State private var outputLines: [String] = []
    @State private var isConnecting = true
    @State private var errorMessage: String? = nil
    @State private var connectionTask: Task<Void, Never>? = nil
    @State private var pendingPrompt: PromptRequest? = nil
    @State private var showingPrompt = false
    @State private var sensitiveValues: [String] = []
    var onConnect: (@escaping (String) -> Void) async throws -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 0) {
                HStack(spacing: AppTheme.Spacing.m) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(.tint.opacity(0.1))
                        )
                    
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text("Connecting to \(connection.name)")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text("\(connection.protocolType.displayName) • \(connection.host):\(connection.port)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, AppTheme.Spacing.l)
                .padding(.vertical, AppTheme.Spacing.m)
                .background(.bar)
            }
            
            Divider()
            
            // Content
            VStack(spacing: AppTheme.Spacing.m) {
                // Output area
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            ForEach(Array(outputLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(
                                        line.contains("error") || line.contains("Error") || 
                                        line.contains("denied") || line.contains("failed") || 
                                        line.contains("✗") ? .red : 
                                        line.contains("✓") || line.contains("successful") ? .green :
                                        .primary
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            if isConnecting {
                                HStack(spacing: AppTheme.Spacing.xs) {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .controlSize(.small)
                                    Text("Connecting...")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, AppTheme.Spacing.xxs)
                            }
                        }
                        .padding(AppTheme.Spacing.m)
                    }
                    .frame(height: 320)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    )
                    .onChange(of: outputLines.count) {
                        if let lastIndex = outputLines.indices.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastIndex, anchor: .bottom)
                            }
                        }
                    }
                }
                
                // Error message
                if let error = errorMessage {
                    HStack(spacing: AppTheme.Spacing.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppTheme.Spacing.m)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.red.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.red.opacity(0.2), lineWidth: 1)
                    )
                }
                
                // Buttons
                HStack {
                    if isConnecting {
                        Button("Cancel") {
                            connectionTask?.cancel()
                            isPresented = false
                        }
                        .keyboardShortcut(.escape, modifiers: [])
                    } else {
                        Button("Close") {
                            isPresented = false
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.escape, modifiers: [])
                        .keyboardShortcut(.return, modifiers: [])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(AppTheme.Spacing.l)
        }
        .frame(width: 600, height: 500)
        .background(.regularMaterial)
        .sheet(isPresented: $showingPrompt, onDismiss: {
            pendingPrompt = nil
        }) {
            if let prompt = pendingPrompt {
                InteractiveAuthPromptView(prompt: prompt.prompt, isPresented: $showingPrompt) { response in
                    writePromptResponse(response, to: prompt.responseFile)
                }
            }
        }
        .onAppear {
            startConnection()
        }
    }
    
    private func startConnection() {
        connectionTask = Task { @MainActor in
            do {
                addOutput("Starting connection to \(connection.host)...")
                addOutput("Protocol: \(connection.protocolType.displayName)")
                addOutput("Host: \(connection.host)")
                addOutput("Port: \(connection.port)")
                addOutput("Username: \(connection.username)")
                if connection.getPassword() != nil {
                    addOutput("Authentication: Password (stored in Keychain)")
                } else if connection.usesKeyAuth {
                    addOutput("Authentication: SSH Key (\(connection.privateKeyPath ?? "default"))")
                } else {
                    addOutput("Authentication: None (will fail)")
                }
                addOutput("")
                
                try await onConnect(
                    { message in
                        Task { @MainActor in
                            addOutput(message)
                        }
                    }
                )
                
                addOutput("")
                addOutput("✓ Connection successful!")
                isConnecting = false
                
                // Auto-close after a short delay on success
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                if !Task.isCancelled {
                    await MainActor.run {
                        isPresented = false
                    }
                }
            } catch {
                addOutput("")
                let safeError = sanitizedOutput(error.localizedDescription)
                addOutput("✗ Connection failed: \(safeError)")
                errorMessage = safeError
                isConnecting = false
            }
        }
    }
    
    private func addOutput(_ line: String) {
        // Detect prompt forwarding lines
        if handlePromptLine(line) {
            return
        }
        outputLines.append(sanitizedOutput(line))
    }
    
    // MARK: - Prompt forwarding
    
    private struct PromptRequest {
        let prompt: String
        let responseFile: String
    }
    
    private func handlePromptLine(_ line: String) -> Bool {
        let filePrefix = "PROMPT_FILE::"
        if line.hasPrefix(filePrefix) {
            let payload = String(line.dropFirst(filePrefix.count))
            let parts = payload.components(separatedBy: "::")
            guard parts.count == 2 else { return false }
            
            let responseFile = parts[0]
            let promptFile = parts[1]
            let promptText = (try? String(contentsOfFile: promptFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prompt = promptText.isEmpty ? "Authentication prompt" : promptText
            try? FileManager.default.removeItem(atPath: promptFile)
            
            pendingPrompt = PromptRequest(prompt: prompt, responseFile: responseFile)
            showingPrompt = true
            return true
        }
        
        let prefix = "PROMPT::"
        guard line.hasPrefix(prefix) else { return false }
        let jsonPart = String(line.dropFirst(prefix.count))
        guard let data = jsonPart.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = obj["prompt"] as? String,
              let responseFile = obj["responseFile"] as? String else {
            return false
        }
        pendingPrompt = PromptRequest(prompt: prompt, responseFile: responseFile)
        showingPrompt = true
        return true
    }
    
    private func writePromptResponse(_ response: String, to path: String) {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rememberSensitiveValue(trimmed)
        let content = trimmed + "\n"
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            addOutput("Sent response to server prompt")
        } catch {
            addOutput("Failed to send prompt response: \(error.localizedDescription)")
        }
    }
    
    private func rememberSensitiveValue(_ value: String) {
        guard value.count >= 4, !sensitiveValues.contains(value) else { return }
        sensitiveValues.append(value)
    }
    
    private func sanitizedOutput(_ text: String) -> String {
        var redacted = text
        var secrets = sensitiveValues
        if let password = connection.getPassword()?.trimmingCharacters(in: .whitespacesAndNewlines),
           password.count >= 4 {
            secrets.append(password)
        }
        
        for secret in secrets where secret.count >= 4 {
            redacted = redacted.replacingOccurrences(of: secret, with: "<redacted>")
        }
        return redacted
    }
}
