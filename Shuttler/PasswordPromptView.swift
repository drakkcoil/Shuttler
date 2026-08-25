//
//  PasswordPromptView.swift
//  Shuttler
//
//  Password prompt dialog for connections that don't have a password set.
//

import SwiftUI

struct PasswordPromptView: View {
    let connection: Connection
    @Binding var isPresented: Bool
    @State private var password: String = ""
    @State private var savePassword: Bool = false
    @FocusState private var isPasswordFocused: Bool
    
    var onPasswordEntered: (String, Bool) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 0) {
                HStack(spacing: AppTheme.Spacing.m) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(.tint.opacity(0.12))
                        )
                    
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text("Password Required")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        Text("\(connection.protocolType.displayName) • \(connection.host):\(connection.port)")
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, AppTheme.Spacing.l)
                .padding(.vertical, AppTheme.Spacing.m)
                .background(.bar)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            
            Divider()
            
            // Content
            VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                Text("Enter password for \(connection.username):")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.top, AppTheme.Spacing.m)
                
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($isPasswordFocused)
                    .onSubmit {
                        if !password.isEmpty {
                            submitPassword()
                        }
                    }
                    .padding(.bottom, AppTheme.Spacing.xxs)
                
                Toggle("Save password in connection settings", isOn: $savePassword)
                    .font(.system(size: 12))
                    .padding(.bottom, AppTheme.Spacing.xxs)
                
                HStack {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    
                    Spacer()
                    
                    Button("Connect") {
                        submitPassword()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .shadow(color: .accentColor.opacity(0.12), radius: 8, x: 0, y: 2)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(password.isEmpty)
                    .scaleEffect(password.isEmpty ? 1.0 : 1.07)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: password)
                }
                .padding(.top, AppTheme.Spacing.s)
            }
            .padding(AppTheme.Spacing.xl)
        }
        .frame(width: 470)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 24, x: 0, y: 8)
        .onAppear {
            isPasswordFocused = true
        }
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isPresented)
    }
    
    private func submitPassword() {
        guard !password.isEmpty else { return }
        onPasswordEntered(password, savePassword)
        isPresented = false
    }
}

#Preview {
    PasswordPromptView(connection: .example(), isPresented: .constant(true)) { _,_ in }
}
