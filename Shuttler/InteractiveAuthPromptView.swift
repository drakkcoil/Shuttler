//
//  InteractiveAuthPromptView.swift
//  Shuttler
//
//  Dialog for interactive authentication prompts (e.g., Cisco Duo)
//

import SwiftUI

struct InteractiveAuthPromptView: View {
    let prompt: String
    @Binding var isPresented: Bool
    @State private var response: String = ""
    @FocusState private var isResponseFocused: Bool
    var onResponse: (String) -> Void
    
    // Parse Duo prompt to extract structured information
    private var parsedPrompt: (title: String, instruction: String, options: [(number: String, text: String)], inputLabel: String) {
        let lowerPrompt = prompt.lowercased()
        
        // Check if this is a Duo prompt
        if lowerPrompt.contains("duo") || lowerPrompt.contains("two-factor") {
            // Extract title (usually "Duo two-factor login for [username]")
            let titleMatch = prompt.range(of: #"Duo.*?login.*?for.*"#, options: .regularExpression)
            let title = titleMatch != nil ? String(prompt[titleMatch!]) : "Duo Two-Factor Authentication"
            
            // Extract instruction
            let instructionMatch = prompt.range(of: #"Enter.*?:"#, options: .regularExpression)
            let instruction = instructionMatch != nil ? String(prompt[instructionMatch!]) : "Enter a passcode or select one of the following options:"
            
            // Extract numbered options (e.g., "1. Duo Push to...", "2. SMS passcodes to...")
            var options: [(number: String, text: String)] = []
            let optionPattern = #"(\d+)\.\s*([^\n]+)"#
            let regex = try? NSRegularExpression(pattern: optionPattern, options: [])
            if let matches = regex?.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)) {
                for match in matches {
                    if match.numberOfRanges >= 3 {
                        let numberRange = Range(match.range(at: 1), in: prompt)!
                        let textRange = Range(match.range(at: 2), in: prompt)!
                        let number = String(prompt[numberRange])
                        let text = String(prompt[textRange]).trimmingCharacters(in: .whitespaces)
                        options.append((number: number, text: text))
                    }
                }
            }
            
            let inputLabel = options.isEmpty ? "Passcode or option:" : "Passcode or option (\(options.map { $0.number }.joined(separator: "-"))):"
            
            return (title: title, instruction: instruction, options: options, inputLabel: inputLabel)
        } else {
            // Generic prompt - return as-is
            return (title: "Authentication Required", instruction: prompt, options: [], inputLabel: "Response:")
        }
    }
    
    // Check if clipboard has content for Paste button
    private var clipboardHasContent: Bool {
        #if os(macOS)
        if let clipboardString = NSPasteboard.general.string(forType: .string) {
            return !clipboardString.isEmpty
        }
        return false
        #else
        return UIPasteboard.general.hasStrings
        #endif
    }
    
    // Get clipboard string content
    private var clipboardString: String? {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #else
        return UIPasteboard.general.string
        #endif
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 0) {
                HStack(spacing: AppTheme.Spacing.m) {
                    Image(systemName: "key.radiowaves.forward.fill") // more distinctive MFA/2FA icon
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(.tint.opacity(0.12))
                                .shadow(color: Color.accentColor.opacity(0.5), radius: 6, x: 0, y: 0) // subtle glow accent
                        )
                    
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text("Server Prompt")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .accessibilityLabel("Authentication prompt title")
                            .accessibilityAddTraits(.isHeader)
                        Text("Interactive authentication required")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Authentication prompt subtitle")
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, AppTheme.Spacing.l)
                .padding(.vertical, AppTheme.Spacing.m)
                .background(.bar)
            }
            
            Divider()
            
            // Content
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                let parsed = parsedPrompt
                
                // Title (for Duo prompts)
                if !parsed.title.isEmpty && parsed.title != "Authentication Required" {
                    Text(parsed.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, AppTheme.Spacing.m)
                        .accessibilityLabel("Authentication method title")
                }
                
                // Instruction
                Text(parsed.instruction)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Authentication instructions")
                
                // Numbered options (for Duo)
                if !parsed.options.isEmpty {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        ForEach(parsed.options, id: \.number) { option in
                            Button {
                                response = option.number
                                submitResponse()
                            } label: {
                                HStack(alignment: .top, spacing: AppTheme.Spacing.s) {
                                    Text(option.number)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .frame(width: 22, height: 22)
                                        .background(Circle().fill(Color.accentColor))
                                    Text(option.text)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, AppTheme.Spacing.s)
                                .padding(.vertical, AppTheme.Spacing.xs)
                                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Choose option \(option.number)")
                            .accessibilityHint(option.text)
                        }
                    }
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                
                // Input field with Paste button if clipboard content is present
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(parsed.inputLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    
                    HStack(spacing: 6) {
                        TextField("", text: $response)
                            .textFieldStyle(.roundedBorder)
                            .focused($isResponseFocused)
                            .onSubmit {
                                if !response.isEmpty {
                                    submitResponse()
                                }
                            }
                            .textContentType(.oneTimeCode) // autofill suggestion for one-time codes
                            // Apply glow accent when focused
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isResponseFocused ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 2)
                                    .shadow(color: isResponseFocused ? Color.accentColor.opacity(0.5) : Color.clear, radius: 8, x: 0, y: 0)
                            )
                            .accessibilityLabel(parsed.inputLabel)
                            .accessibilityHint("Enter the passcode or option number here")
                        
                        if clipboardHasContent {
                            Button("Paste") {
                                if let clipboardText = clipboardString {
                                    response = clipboardText
                                }
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Paste from clipboard")
                            .accessibilityHint("Pastes text from the clipboard into the input field")
                        }
                    }
                }
                .padding(.top, AppTheme.Spacing.xs)
                
                // Help text
                if parsed.options.isEmpty && (prompt.localizedCaseInsensitiveContains("duo") || prompt.localizedCaseInsensitiveContains("passcode")) {
                    Text("Enter your Duo passcode, or type 'push' to send a push notification")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Help text")
                }
                
                // Buttons
                HStack {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel("Cancel authentication")
                    .accessibilityHint("Dismisses the authentication prompt without submitting a response")
                    
                    Spacer()
                    
                    Button("Continue") {
                        submitResponse()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(response.isEmpty)
                    .accessibilityLabel("Submit response")
                    .accessibilityHint("Submits the entered response for authentication")
                }
                .padding(.top, AppTheme.Spacing.m)
            }
            .padding(AppTheme.Spacing.l)
        }
        .frame(width: 500)
        .background(.regularMaterial)
        // Animate presentation/dismissal with scale and opacity
        .scaleEffect(isPresented ? 1 : 0.95)
        .opacity(isPresented ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: isPresented)
        .onAppear {
            isResponseFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
    
    private func submitResponse() {
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else { return }
        onResponse(trimmedResponse)
        isPresented = false
    }
}
