//
//  SSHTransport.swift
//  Shuttler
//
//  Implements SFTP and SCP using system ssh/sftp/scp via Process.
//

import Foundation

struct SSHAuthConfig {
    let host: String
    let port: Int
    let username: String
    let privateKeyPath: String?
    let password: String?
}

enum SSHExec {
    private static let sharedConnectionOptions = [
        "-o", "ControlMaster=auto",
        "-o", "ControlPersist=10m",
        "-o", "ControlPath=shuttler-ssh-%C"
    ]
    
    static func sshArgs(
        _ auth: SSHAuthConfig,
        extra: [String],
        allowPrompts: Bool = false,
        requestTTY: Bool = false,
        allowDefaultKeys: Bool = false
    ) -> [String] {
        var args: [String] = ["-p", String(auth.port)]
        args += sharedConnectionOptions
        if requestTTY {
            args += ["-tt"]
        }
        
        if allowPrompts {
            args += [
                "-o", "BatchMode=no",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "KbdInteractiveAuthentication=yes",
                "-o", "ChallengeResponseAuthentication=yes",
                "-o", "NumberOfPasswordPrompts=3",
                "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=60",
                "-o", "ServerAliveCountMax=3"
            ]
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        
        if let key = auth.privateKeyPath, !key.isEmpty {
            args += ["-i", key]
            args += ["-o", "IdentitiesOnly=yes"]
        } else if allowPrompts && allowDefaultKeys {
            args += [
                "-o", "PreferredAuthentications=publickey,keyboard-interactive,password",
                "-o", "PubkeyAuthentication=yes",
                "-o", "PasswordAuthentication=yes",
                "-o", "IdentitiesOnly=no"
            ]
        } else if allowPrompts {
            // For password/MFA auth, prevent ssh-agent/default keys from exhausting auth attempts.
            args += [
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "PubkeyAuthentication=no",
                "-o", "PasswordAuthentication=yes",
                "-o", "IdentitiesOnly=yes"
            ]
        } else {
            args += [
                "-o", "PubkeyAuthentication=no",
                "-o", "IdentitiesOnly=yes"
            ]
        }
        // Trim hostname and username to ensure no whitespace issues
        let trimmedHost = auth.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = auth.username.trimmingCharacters(in: .whitespacesAndNewlines)
        args += ["\(trimmedUser)@\(trimmedHost)"]
        args += extra
        return args
    }

    static func sftpArgs(_ auth: SSHAuthConfig, extra: [String], allowPrompts: Bool = false) -> [String] {
        var args: [String] = ["-P", String(auth.port)]
        args += sharedConnectionOptions
        
        if allowPrompts {
            args += [
                "-o", "BatchMode=no",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "KbdInteractiveAuthentication=yes",
                "-o", "ChallengeResponseAuthentication=yes",
                "-o", "NumberOfPasswordPrompts=3",
                "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=60",
                "-o", "ServerAliveCountMax=3"
            ]
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        
        if let key = auth.privateKeyPath, !key.isEmpty {
            args += ["-i", key, "-o", "IdentitiesOnly=yes"]
        } else if allowPrompts {
            args += [
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "PubkeyAuthentication=no",
                "-o", "PasswordAuthentication=yes",
                "-o", "IdentitiesOnly=yes"
            ]
        } else {
            args += [
                "-o", "PubkeyAuthentication=no",
                "-o", "IdentitiesOnly=yes"
            ]
        }
        args += extra
        args += ["\(auth.username)@\(auth.host)"]
        return args
    }

    static func scpArgs(_ auth: SSHAuthConfig, extra: [String]) -> [String] {
        var args: [String] = ["-P", String(auth.port)]
        args += sharedConnectionOptions
        if let key = auth.privateKeyPath, !key.isEmpty {
            args += ["-i", key, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes"]
        } else if auth.password == nil {
            args += [
                "-o", "BatchMode=yes",
                "-o", "PubkeyAuthentication=no",
                "-o", "IdentitiesOnly=yes"
            ]
        } else {
            // Non-interactive operations must reuse the authenticated control connection.
            args += [
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "PasswordAuthentication=yes",
                "-o", "KbdInteractiveAuthentication=yes",
                "-o", "ChallengeResponseAuthentication=yes",
                "-o", "IdentitiesOnly=yes",
                "-o", "NumberOfPasswordPrompts=3",
                "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=60",
                "-o", "ServerAliveCountMax=3"
            ]
        }
        args += extra
        return args
    }
}

// #region agent log helper
private func debugLog(location: String, message: String, data: [String: Any] = [:], hypothesisId: String = "") {
    // Primary log path for debug mode (per system reminder)
    let primaryLogPath = "/Users/anewman/Library/CloudStorage/OneDrive-sbfoods.com/Documents/XCode Projects/Shuttler/Shuttler/.cursor/debug.log"
    // Secondary log path (app container documents)
    let secondaryLogPath = "/Users/anewman/Library/Containers/FinalReality.Shuttler/Data/Documents/debug.log"
    let logPaths = [primaryLogPath, secondaryLogPath]
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    var logEntry: [String: Any] = [
        "location": location,
        "message": message,
        "timestamp": timestamp,
        "sessionId": "debug-session",
        "runId": "run1"
    ]
    if !data.isEmpty {
        // Sanitize data for JSONSerialization
        var safeData: [String: Any] = [:]
        for (k, v) in data {
            if JSONSerialization.isValidJSONObject([k: v]) {
                safeData[k] = v
            } else {
                safeData[k] = String(describing: v)
            }
        }
        logEntry["data"] = safeData
    }
    if !hypothesisId.isEmpty {
        logEntry["hypothesisId"] = hypothesisId
    }
    
    // Print to XCode console
    let consoleMsg = "[\(location)] \(message)" + (data.isEmpty ? "" : " \(data)")
    print("🔍 DEBUG: \(consoleMsg)")
    
        // Write to log files (primary + secondary)
    if let logData = try? JSONSerialization.data(withJSONObject: logEntry),
       let logLine = String(data: logData, encoding: .utf8) {
        for logPath in logPaths {
            let logURL = URL(fileURLWithPath: logPath)
            let logDir = logURL.deletingLastPathComponent()
            
            do {
                try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("🔍 DEBUG: Failed to create log directory: \(error.localizedDescription), path: \(logDir.path)")
                continue
            }
            
            do {
                if FileManager.default.fileExists(atPath: logPath) {
                    let fileHandle = try FileHandle(forWritingTo: logURL)
                    defer { fileHandle.closeFile() }
                    fileHandle.seekToEndOfFile()
                    if let lineData = (logLine + "\n").data(using: .utf8) {
                        fileHandle.write(lineData)
                    }
                } else {
                    try (logLine + "\n").write(to: logURL, atomically: true, encoding: .utf8)
                }
            } catch {
                print("🔍 DEBUG: Failed to write log file: \(error.localizedDescription), path: \(logPath)")
            }
        }
    } else {
        print("🔍 DEBUG: Failed to serialize log entry")
    }
    }
	// #endregion

private func redactSensitiveText(_ text: String, secrets: [String?]) -> String {
    var redacted = text
    for secret in secrets.compactMap({ $0 }).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
        guard secret.count >= 4 else { continue }
        redacted = redacted.replacingOccurrences(of: secret, with: "<redacted>")
    }
    return redacted
}

private func emitSanitizedLines(from text: String, secrets: [String?], to handler: ((String) -> Void)?) {
    guard let handler else { return }
    let redacted = redactSensitiveText(text, secrets: secrets)
    for line in redacted.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            handler(trimmed)
        }
    }
}

private func userFacingSSHFailureMessage(stderr: String, stdout: String, exitCode: Int32, usedExpect: Bool) -> String {
    let combined = (stderr + "\n" + stdout)
    let lines = combined
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    
    func normalizedCandidate(_ line: String) -> String? {
        let lower = line.lowercased()
        
        if lower == "prompt_timeout" {
            return "Timed out waiting for authentication response."
        }
        
        if lower.hasPrefix("last line:") {
            let candidate = String(line.dropFirst("Last line:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? nil : candidate
        }

        if lower.hasPrefix("keyboard-interactive did not present a prompt") ||
            lower.hasPrefix("keyboard-interactive was denied before a prompt") {
            return "Keyboard-interactive authentication was denied before Shuttler received a prompt."
        }
        
        let internalPrefixes = [
            "starting ssh authentication",
            "waiting for server authentication",
            "detected potential password prompt",
            "detected user@host prompt",
            "detected password prompt",
            "password sent",
            "sending password",
            "sending stored password",
            "sending user response",
            "received authentication prompt",
            "interactive mfa prompt detected",
            "mfa challenge received",
            "autopush detected",
            "autopush approved",
            "command output captured",
            "using expect"
        ]
        
        if internalPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return nil
        }
        
        return line
    }
    
    let priorityMarkers = [
        "permission denied",
        "authentication failed",
        "too many authentication failures",
        "keyboard-interactive",
        "connection timed out",
        "connection refused",
        "could not resolve hostname",
        "no route to host",
        "server refused connection",
        "maxstartups",
        "prompt_timeout"
    ]
    
    for line in lines.reversed() {
        guard let candidate = normalizedCandidate(line) else { continue }
        let lower = candidate.lowercased()
        if priorityMarkers.contains(where: { lower.contains($0) }) {
            return candidate
        }
    }
    
    for line in lines.reversed() {
        if let candidate = normalizedCandidate(line) {
            return candidate
        }
    }
    
    var fallback = "SSH connection failed with exit code \(exitCode)"
    if usedExpect {
        fallback += " during interactive authentication"
    }
    return fallback
}

private struct AskpassBridge {
    let directory: URL
    let scriptFile: URL
    let responseFile: URL
    let promptDirectory: URL
    let stateFile: URL
    let passwordFile: URL?
}

private func bundledAskpassHelperURL() throws -> URL {
    guard let helperURL = Bundle.main.url(forResource: "ShuttlerAskpass", withExtension: "sh") else {
        throw TransferError(message: "Bundled askpass helper is missing from the app bundle.")
    }
    
    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
        throw TransferError(message: "Bundled askpass helper is not executable.")
    }
    
    return helperURL
}

private func makeAskpassBridge(password: String?, autoStoredPassword: Bool) throws -> AskpassBridge {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("shuttler_askpass_\(UUID().uuidString)", isDirectory: true)
    let promptDirectory = directory.appendingPathComponent("prompts", isDirectory: true)
    let scriptFile = try bundledAskpassHelperURL()
    let responseFile = directory.appendingPathComponent("response.txt")
    let stateFile = directory.appendingPathComponent("state.txt")
    var passwordFile: URL?
    
    try FileManager.default.createDirectory(at: promptDirectory, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: promptDirectory.path)
    
    if let password {
        let file = directory.appendingPathComponent("password.txt")
        try (password + "\n").write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        passwordFile = file
    }

    return AskpassBridge(
        directory: directory,
        scriptFile: scriptFile,
        responseFile: responseFile,
        promptDirectory: promptDirectory,
        stateFile: stateFile,
        passwordFile: passwordFile
    )
}

private func startAskpassPromptPoller(bridge: AskpassBridge, outputHandler: ((String) -> Void)?) {
    guard outputHandler != nil else { return }
    
    DispatchQueue.global(qos: .userInitiated).async {
        var seenPromptFiles = Set<String>()
        
        while FileManager.default.fileExists(atPath: bridge.directory.path) {
            let promptFiles = (try? FileManager.default.contentsOfDirectory(
                at: bridge.promptDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            
            for promptFile in promptFiles where promptFile.pathExtension == "txt" {
                guard seenPromptFiles.insert(promptFile.path).inserted else { continue }
                outputHandler?("PROMPT_FILE::\(bridge.responseFile.path)::\(promptFile.path)")
            }
            
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}

private func sshControlDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("shuttler-ssh-control", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    return directory
}

@discardableResult
func runProcess(
    launchPath: String,
    arguments: [String],
    input: Data? = nil,
    password: String? = nil,
    timeout: TimeInterval = 30,
    outputHandler: ((String) -> Void)? = nil,
    interactiveAuthentication: Bool = false,
    allowSSHAgent: Bool = false
) throws -> (status: Int32, stdout: Data, stderr: Data) {
    let process = Process()
    let actualLaunchPath = launchPath
    let actualArguments = arguments
    let launchId = UUID().uuidString
    let sensitiveValues = [password]
    
    // #region agent log
    debugLog(
        location: "SSHTransport.swift:runProcess:start",
        message: "Starting runProcess",
        data: [
            "launchPath": actualLaunchPath,
            "argsPreview": Array(actualArguments.prefix(12)),
            "hasPassword": password != nil,
            "allowSSHAgent": allowSSHAgent,
            "launchId": launchId
        ],
        hypothesisId: "LOG"
    )
    // #endregion

    // OpenSSH reads keyboard-interactive/password prompts through /dev/tty.
    // Sandboxed app processes may not have one, so bridge prompts through SSH_ASKPASS.
    let useAskpass = interactiveAuthentication
    var useExpect = false
    var expectPassword: String? = nil
    var askpassBridge: AskpassBridge? = nil
    
    do {
        var env = ProcessInfo.processInfo.environment
        env["SSH_USE_STRICT_RDNS"] = "no"
        if !useAskpass, password != nil, env["SHUTTLER_ENABLE_EXPECT_AUTH"] == "1" {
            useExpect = true
            expectPassword = password
        }
        
        if password != nil && !allowSSHAgent {
            // Unset SSH_AUTH_SOCK to prevent SSH from using ssh-agent
            env.removeValue(forKey: "SSH_AUTH_SOCK")
        }
        
        if useAskpass {
            let bridge = try makeAskpassBridge(
                password: password,
                autoStoredPassword: password != nil && !actualArguments.contains("-i")
            )
            askpassBridge = bridge
            env["SSH_ASKPASS"] = bridge.scriptFile.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? "shuttler:0"
            env["SHUTTLER_ASKPASS_MODE"] = "1"
            env["SHUTTLER_ASKPASS_RESPONSE_FILE"] = bridge.responseFile.path
            env["SHUTTLER_ASKPASS_PROMPT_DIR"] = bridge.promptDirectory.path
            env["SHUTTLER_ASKPASS_STATE_FILE"] = bridge.stateFile.path
            env["SHUTTLER_ASKPASS_AUTO_PASSWORD"] = password != nil && !actualArguments.contains("-i") ? "1" : "0"
            if let passwordFile = bridge.passwordFile {
                env["SHUTTLER_ASKPASS_PASSWORD_FILE"] = passwordFile.path
            }
            
            outputHandler?("Starting SSH authentication...")
            outputHandler?("Waiting for server authentication...")
            
            debugLog(
                location: "SSHTransport.swift:runProcess:askpass",
                message: "Using SSH_ASKPASS bridge for interactive auth",
                data: [
                    "askpassPath": bridge.scriptFile.path,
                    "autoStoredPassword": password != nil && !actualArguments.contains("-i")
                ],
                hypothesisId: "ASKPASS"
            )
        }
        
        process.environment = env
    } catch {
        throw TransferError(message: "Failed to create askpass bridge: \(error.localizedDescription)")
    }
    
    // If using expect for password authentication, wrap the command
    var expectScriptFile: URL? = nil
    if useExpect {
        // Use expect to automate password entry
        // expect script: spawn ssh command, wait for password prompt, send password
        // Embed password directly in script to avoid file I/O corruption issues
        
        // #region agent log
        debugLog(
            location: "SSHTransport.swift:runProcess:expect",
            message: "Using expect for password auth",
            data: ["launchPath": actualLaunchPath, "argsPreview": Array(actualArguments.prefix(6))],
            hypothesisId: "LOG"
        )
        // #endregion
        
        // Escape password for use directly in expect script
        // Escape special Tcl characters that could break the script
        let escapedPassword = (expectPassword ?? "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        
        let spawnCommand = ([actualLaunchPath] + actualArguments).map { arg in
            let escaped = arg
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "{", with: "\\{")
                .replacingOccurrences(of: "}", with: "\\}")
            return "{\(escaped)}"
        }.joined(separator: " ")
        let hasPassword = expectPassword?.isEmpty == false ? 1 : 0
        let hasPrivateKey = actualArguments.contains("-i") ? 1 : 0
        
        // Build expect script - use password directly instead of file
        // Extract host and user info for error messages
        let hostInfo = actualArguments.last(where: { $0.contains("@") }) ?? "server"

        // #region agent log
        debugLog(location: "SSHTransport.swift:171", message: "Building expect script", data: ["host": hostInfo, "launchPath": actualLaunchPath, "hasPassword": !escapedPassword.isEmpty], hypothesisId: "A")
        // #endregion
        
        // Paths for prompt-response bridge (used for MFA/keyboard-interactive)
        let tempDir = FileManager.default.temporaryDirectory
        let responseFile = tempDir.appendingPathComponent("shuttler_expect_response_\(UUID().uuidString).txt").path
        
        let expectScript = """
        set timeout 300
        log_user 0
        puts stderr "Starting SSH authentication..."
        set password "\(escapedPassword)"
        set hasPassword \(hasPassword)
        set hasPrivateKey \(hasPrivateKey)
        set responseFile "\(responseFile)"
        
        # Helper: emit prompt to Swift side and wait for response file
        proc send_prompt_and_wait {prompt responseFile} {
            # Emit valid single-line JSON so Swift can parse prompts that contain newlines.
            set safePrompt [string map {\\ \\\\ \" \\\" \n \\n \r \\r \t \\t} $prompt]
            puts stderr "PROMPT::{\"prompt\":\"$safePrompt\",\"responseFile\":\"$responseFile\"}"
            set waited 0
            set maxwait 240
            while {![file exists $responseFile] && $waited < $maxwait} {
                sleep 1
                incr waited
            }
            if {![file exists $responseFile]} {
                puts stderr "PROMPT_TIMEOUT"
                exit 1
            }
            set fh [open $responseFile r]
            set resp [read $fh]
            close $fh
            file delete -force $responseFile
            return [string trim $resp]
        }
        
        # Suppress stty warnings by redirecting stderr for stty commands
        spawn \(spawnCommand)
        # Note: avoid forcing stty raw/echo changes here; prior attempts triggered
        # "Operation not permitted" and may suppress interactive prompts.
        
        # Track password attempts and capture all output
        set passwordAttempts 0
        set maxPasswordAttempts 3
        set output ""
        set sawAutopush 0
        set passwordSent 0
        set promptSeen 0
        set mfaPromptBuffer ""
        puts stderr "Waiting for server authentication..."
        
        expect {
            # Private key passphrase prompt
            -re {[^\\r\\n]*[Pp]assphrase[^\\r\\n]*:[[:space:]]*$} {
                append output $expect_out(buffer)
                set promptLine [string trim $expect_out(0,string)]
                set promptSeen 1
                set userResp [send_prompt_and_wait $promptLine $responseFile]
                puts stderr "Sending user response to key passphrase prompt"
                send -- "$userResp\r"
                exp_continue
            }
            # Pattern 0: Match lines with colon at end that look like password prompts.
            # This catches keyboard-interactive prompts that might not match other patterns
            -re {[^\\r\\n]*[Pp]assword[^\\r\\n]*:[[:space:]]*$} {
                append output $expect_out(buffer)
                set promptLine [string trim $expect_out(0,string)]
                puts stderr "Detected potential password prompt (pattern 0): '$promptLine'"
                
                if {!$passwordSent} {
                    if {!$hasPassword} {
                        set userResp [send_prompt_and_wait $promptLine $responseFile]
                        send -- "$userResp\r"
                        set passwordSent 1
                        set promptSeen 1
                        sleep 0.5
                        exp_continue
                    }
                    incr passwordAttempts
                    if {$passwordAttempts > $maxPasswordAttempts} {
                        puts stderr "Authentication failed: Maximum password attempts exceeded"
                        exit 1
                    }
                    puts stderr "Sending stored password to password prompt"
                    sleep 0.1
                    send -- "$password\r"
                    set passwordSent 1
                    set promptSeen 1
                    sleep 0.5
                }
                exp_continue
            }
            # Pattern 0b: Match user@host patterns followed by colon (keyboard-interactive format)
            -re {\\(.*@.*\\)[[:space:]]*:[[:space:]]*$} {
                append output $expect_out(buffer)
                set promptLine [string trim $expect_out(0,string)]
                puts stderr "Detected user@host prompt pattern: '$promptLine'"
                
                # This might be a password prompt, try sending password
                if {!$passwordSent} {
                    if {!$hasPassword} {
                        set userResp [send_prompt_and_wait $promptLine $responseFile]
                        send -- "$userResp\r"
                        set passwordSent 1
                        set promptSeen 1
                        sleep 0.5
                        exp_continue
                    }
                    incr passwordAttempts
                    if {$passwordAttempts > $maxPasswordAttempts} {
                        puts stderr "Authentication failed: Maximum password attempts exceeded"
                        exit 1
                    }
                    puts stderr "Sending stored password to keyboard-interactive password prompt"
                    sleep 0.1
                    send -- "$password\r"
                    set passwordSent 1
                    set promptSeen 1
                    sleep 0.5
                }
                exp_continue
            }
            # Pattern 1: Simple "Password:" or "password:" at end of line
            -re {[Pp]assword:[[:space:]]*$} {
                append output $expect_out(buffer)
                if {!$passwordSent} {
                    if {!$hasPassword} {
                        set userResp [send_prompt_and_wait "Password:" $responseFile]
                        send -- "$userResp\r"
                        set passwordSent 1
                        set promptSeen 1
                        sleep 0.5
                        exp_continue
                    }
                    incr passwordAttempts
                    if {$passwordAttempts > $maxPasswordAttempts} {
                        puts stderr "Authentication failed: Maximum password attempts exceeded"
                        exit 1
                    }
                    sleep 0.1
                    send -- "$password\r"
                    set passwordSent 1
                    set promptSeen 1
                    puts stderr "Password sent in response to simple Password: prompt"
                }
                exp_continue
            }
            # Pattern 2: "(user@host) Password:" format (common with keyboard-interactive)
            -re {\\(.*@.*\\)[[:space:]]*[Pp]assword:[[:space:]]*$} {
                append output $expect_out(buffer)
                if {!$passwordSent} {
                if {!$hasPassword} {
                    set promptLine [string trim $expect_out(0,string)]
                    set userResp [send_prompt_and_wait $promptLine $responseFile]
                    send -- "$userResp\r"
                    set passwordSent 1
                    set promptSeen 1
                    sleep 0.5
                    exp_continue
                }
                incr passwordAttempts
                if {$passwordAttempts > $maxPasswordAttempts} {
                    puts stderr "Authentication failed: Maximum password attempts exceeded"
                    exit 1
                }
                sleep 0.1
                send -- "$password\r"
                    set passwordSent 1
                    set promptSeen 1
                    puts stderr "Password sent in response to (user@host) Password: prompt"
                }
                exp_continue
            }
            # Pattern 2b: "user@host's password:" format
            -re {[^\\r\\n]*'s [Pp]assword:[[:space:]]*$} {
                append output $expect_out(buffer)
                if {!$hasPassword} {
                    set promptLine [string trim $expect_out(0,string)]
                    set userResp [send_prompt_and_wait $promptLine $responseFile]
                    send -- "$userResp\r"
                    set passwordSent 1
                    exp_continue
                }
                incr passwordAttempts
                if {$passwordAttempts > $maxPasswordAttempts} {
                    puts stderr "Authentication failed: Maximum password attempts exceeded"
                    exit 1
                }
                sleep 0.1
                send -- "$password\r"
                set passwordSent 1
                exp_continue
            }
            # Pattern 3: "Password:" anywhere in line (fallback) - most permissive
            -re {[^\\r\\n]*[Pp]assword[^\\r\\n]*:[[:space:]]*$} {
                append output $expect_out(buffer)
                # Check if we've already sent password for this prompt
                if {$passwordSent && [string match "*permission denied*" [string tolower $expect_out(buffer)]]} {
                    # This is an error message, not a prompt
                    exp_continue
                }
                if {!$hasPassword} {
                    set promptLine [string trim $expect_out(0,string)]
                    set userResp [send_prompt_and_wait $promptLine $responseFile]
                    send -- "$userResp\r"
                    set passwordSent 1
                    sleep 0.5
                    exp_continue
                }
                incr passwordAttempts
                if {$passwordAttempts > $maxPasswordAttempts} {
                    puts stderr "Authentication failed: Maximum password attempts exceeded"
                    exit 1
                }
                puts stderr "Detected password prompt (pattern 3), sending password"
                sleep 0.1
                send -- "$password\r"
                set passwordSent 1
                # After sending password, wait a moment for any keyboard-interactive prompts
                sleep 0.5
                exp_continue
            }
            # Handle keyboard-interactive prompts that might appear as generic prompts
            # Match prompts that look like authentication prompts (not error messages)
            # This should come AFTER password patterns to avoid false matches
            -re {([^\\r\\n]*([Pp]asscode|[Vv]erification code|[Ee]nter[^\\r\\n]*code|[Cc]hoose[^\\r\\n]*option|[Ss]elect[^\\r\\n]*method|[Pp]assword)[^\\r\\n]*:)[[:space:]]*$} {
                append output $expect_out(buffer)
                set prompt [string trim "$mfaPromptBuffer$expect_out(buffer)"]
                set mfaPromptBuffer ""
                puts stderr "Received authentication prompt: '$prompt'"
                
                # Check if this looks like a password prompt
                set lowerPrompt [string tolower $prompt]
                if {[string match "*password*" $lowerPrompt]} {
                    if {!$hasPassword} {
                        set userResp [send_prompt_and_wait $prompt $responseFile]
                        puts stderr "Sending user response to authentication prompt"
                        send -- "$userResp\r"
                        sleep 0.3
                        exp_continue
                    }
                    incr passwordAttempts
                    if {$passwordAttempts > $maxPasswordAttempts} {
                        puts stderr "Authentication failed: Maximum password attempts exceeded"
                        exit 1
                    }
                    puts stderr "Sending password in response to keyboard-interactive prompt"
                    send -- "$password\r"
                    set passwordSent 1
                    sleep 0.3
                    exp_continue
                } else {
                    # Other authentication prompt (MFA) - forward to Swift and wait for response
                    set promptSeen 1
                    set userResp [send_prompt_and_wait $prompt $responseFile]
                    puts stderr "Sending user response to authentication prompt"
                    send -- "$userResp\r"
                    exp_continue
                }
            }
            # Autopush detection - detect push approval flows and WAIT for success
            # This MUST come BEFORE "permission denied" to handle autopush flow properly
            # Match various forms of autopush messages
            -re {([Aa]utopushing|[Aa]utopush.*request|[Dd]uo [Pp]ush|[Pp]ushed.*login request|[Pp]ush.*sent|[Ss]ent.*push|[Ll]ogin request.*phone|[Ll]ogin request.*device|[Aa]pprove.*login|[Ww]aiting.*approval)} {
                append output $expect_out(buffer)
                append mfaPromptBuffer $expect_out(buffer)
                set sawAutopush 1
                puts stderr "Autopush detected. Waiting for approval..."
                # Continue waiting - don't exit, wait for success message
                exp_continue
            }
            # Detect success message after autopush - must come before permission denied
            -re {([Ss]uccess.*logging.*you.*in|[Aa]uthenticated|[Aa]uthentication successful|[Aa]pproved)} {
                append output $expect_out(buffer)
                set sawAutopush 1
                puts stderr "Autopush approved. Authentication successful."
                # Continue waiting for command output
                exp_continue
            }
            # Interactive MFA/Duo prompt that requires user input (not autopush)
            # This should come after autopush detection but before permission denied
            -re {([^\\r\\n]*([Pp]asscode|[Vv]erification code|[Ee]nter[^\\r\\n]*passcode|[Ee]nter[^\\r\\n]*code|[Cc]hoose[^\\r\\n]*option|[Ss]elect[^\\r\\n]*method|[Ss]elect[^\\r\\n]*option|[Pp]asscode or option|[Ee]nter[^\\r\\n]*number|[Oo]ne-time code|[Oo][Tt][Pp]|[Tt]oken)[^\\r\\n]*:)[[:space:]]*$} {
                append output $expect_out(buffer)
                # If we've seen autopush, these prompts might be informational - just continue
                if {$sawAutopush} {
                    # Already saw autopush, these are likely informational messages
                    exp_continue
                } else {
                    # Real interactive prompt - forward it to Swift and wait for the user's response.
                    set mfaPrompt [string trim "$mfaPromptBuffer$expect_out(buffer)"]
                    set mfaPromptBuffer ""
                    set promptSeen 1
                    puts stderr "Interactive MFA prompt detected. Waiting for user response..."
                    set userResp [send_prompt_and_wait $mfaPrompt $responseFile]
                    puts stderr "Sending user response to MFA prompt"
                    send -- "$userResp\r"
                    exp_continue
                }
            }
            # Final auth prompt fallback. Some keyboard-interactive/PAM prompts have
            # site-specific wording; if they end with a colon, answer the first one
            # with the stored password, then forward later prompts to the user.
            -re {([^\\r\\n]*:[[:space:]]*)$} {
                append output $expect_out(buffer)
                set promptLine [string trim $expect_out(1,string)]
                set lowerPrompt [string tolower $promptLine]
                
                if {[string match "*permission denied*" $lowerPrompt] || [string match "*connection*" $lowerPrompt]} {
                    exp_continue
                }
                
                if {!$passwordSent && $hasPassword} {
                    incr passwordAttempts
                    if {$passwordAttempts > $maxPasswordAttempts} {
                        puts stderr "Authentication failed: Maximum password attempts exceeded"
                        exit 1
                    }
                    puts stderr "Sending stored password to authentication prompt"
                    send -- "$password\r"
                    set passwordSent 1
                    set promptSeen 1
                    sleep 0.3
                    exp_continue
                }
                
                set promptSeen 1
                set userPrompt [string trim "$mfaPromptBuffer$promptLine"]
                set mfaPromptBuffer ""
                puts stderr "Interactive authentication prompt detected. Waiting for user response..."
                set userResp [send_prompt_and_wait $userPrompt $responseFile]
                puts stderr "Sending user response to authentication prompt"
                send -- "$userResp\r"
                exp_continue
            }
            # Permission denied with retry message
            -re {[Pp]ermission denied.*try again} {
                append output $expect_out(buffer)
                incr passwordAttempts
                if {$passwordAttempts >= $maxPasswordAttempts} {
                    puts stderr "Authentication failed: Maximum password attempts exceeded"
                    exit 1
                }
                if {$hasPassword && !$passwordSent} {
                    puts stderr "Retry requested before password prompt; sending stored password"
                    sleep 0.1
                    send -- "$password\r"
                    set passwordSent 1
                    set promptSeen 1
                    sleep 0.5
                }
                exp_continue
            }
            # Permission denied with keyboard-interactive before a prompt means OpenSSH did not
            # give us a safe prompt to answer. Let OpenSSH continue so it can try password
            # auth or emit the real final failure line at EOF.
            -re {[Pp]ermission denied.*keyboard-interactive} {
                append output $expect_out(buffer)
                if {$hasPassword && !$promptSeen && !$passwordSent} {
                    puts stderr "Keyboard-interactive did not present a prompt; continuing authentication..."
                    exp_continue
                }
                puts stderr "Permission denied (keyboard-interactive)."
                exit 1
            }
            # Permission denied (keyboard-interactive) as plain text (fallback glob-style match)
            "permission denied (keyboard-interactive)." {
                append output $expect_out(buffer)
                if {$hasPassword && !$promptSeen && !$passwordSent} {
                    puts stderr "Keyboard-interactive did not present a prompt; continuing authentication..."
                    exp_continue
                }
                puts stderr "Permission denied (keyboard-interactive)."
                exit 1
            }
            -re {[Pp]ermission denied} {
                append output $expect_out(buffer)
                # If we sent password recently, wait longer for autopush messages
                if {$passwordSent && !$sawAutopush} {
                    # Give more time for autopush messages to appear
                    sleep 3
                    exp_continue
                }
                # If we saw autopush messages, wait even longer
                if {$sawAutopush || [string match -nocase "*autopush*" $output]} {
                    # We saw autopush but got permission denied - wait longer for success
                    sleep 5
                    exp_continue
                }
                # No autopush seen and enough time has passed - this is a real permission denied
                puts stderr "Permission denied"
                exit 1
            }
            -re {[Ee]xceeded [Mm]ax[Ss]tartups} {
                append output $expect_out(buffer)
                puts stderr "Server refused connection: Exceeded MaxStartups (too many unauthenticated connections)"
                exit 1
            }
            -re {kex_exchange_identification:.*[Mm]ax[Ss]tartups} {
                append output $expect_out(buffer)
                puts stderr "Server closed during kex: MaxStartups hit"
                exit 1
            }
            # Connection errors
            -re "Connection.*refused" {
                append output $expect_out(buffer)
                puts stderr "Connection refused"
                exit 1
            }
            -re "Could not resolve hostname" {
                append output $expect_out(buffer)
                puts stderr "Could not resolve hostname"
                exit 1
            }
            -re "No route to host" {
                append output $expect_out(buffer)
                puts stderr "No route to host"
                exit 1
            }
            # SSH errors - log and continue
            -re "ssh:" {
                append output $expect_out(buffer)
                puts stderr $expect_out(buffer)
                exp_continue
            }
            # Success - command completed
            eof {
                append output $expect_out(buffer)
                catch wait result
                set exitCode [lindex $result 3]
                # For "echo ok" command, check if we got "ok" in output
                set buffer [string tolower $expect_out(buffer)]
                if {[string match "*ok*" $buffer]} {
                    exit 0
                }
                # If exit code is non-zero, output any error we see
                if {$exitCode != 0} {
                    puts stderr "Command failed with exit code $exitCode"
                    puts stderr "Command output captured; sensitive values are hidden in Shuttler."
                    # Output the last part of the buffer if it looks like an error
                    set selectedLine ""
                    set lines [split $output "\\r\\n"]
                    foreach line [lreverse $lines] {
                        set trimmed [string trim $line]
                        set lowerTrimmed [string tolower $trimmed]
                        if {$trimmed != "" && ([string match "*permission denied*" $lowerTrimmed] || [string match "*authentication failed*" $lowerTrimmed] || [string match "*connection refused*" $lowerTrimmed] || [string match "*could not resolve*" $lowerTrimmed] || [string match "*no route to host*" $lowerTrimmed])} {
                            set selectedLine $trimmed
                            break
                        }
                    }
                    if {$selectedLine == ""} {
                        set lines [split $expect_out(buffer) "\\r\\n"]
                    }
                    foreach line [lreverse $lines] {
                        set trimmed [string trim $line]
                        if {$trimmed != ""} {
                            if {$selectedLine == ""} {
                                set selectedLine $trimmed
                            }
                            break
                        }
                    }
                    if {$selectedLine != ""} {
                        puts stderr "Last line: $selectedLine"
                    }
                }
                exit $exitCode
            }
            # Timeout
            timeout {
                append output $expect_out(buffer)
                puts stderr "Connection timed out after 120 seconds"
                puts stderr "Output captured before timeout."
                exit 1
            }
        }
        """
        
        // Write expect script to a temporary file
        let scriptFile = tempDir.appendingPathComponent("shuttler_expect_\(UUID().uuidString).exp")
        
        // Clean up password file after script execution (will be done in defer above)
        expectScriptFile = scriptFile
        
        do {
            try expectScript.write(to: scriptFile, atomically: true, encoding: String.Encoding.utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptFile.path)
            
            // #region agent log
            debugLog(location: "SSHTransport.swift:359", message: "Expect script written", data: ["scriptPath": scriptFile.path, "scriptLength": expectScript.count], hypothesisId: "B")
            // #endregion
        } catch {
            // #region agent log
            debugLog(location: "SSHTransport.swift:368", message: "Failed to write expect script", data: ["error": error.localizedDescription], hypothesisId: "C")
            // #endregion
            throw TransferError(message: "Failed to create expect script: \(error.localizedDescription)")
        }
        
        // Use expect to run the command with debug flag if needed
        // First verify expect exists
        if !FileManager.default.fileExists(atPath: "/usr/bin/expect") {
            debugLog(location: "SSHTransport.swift:472", message: "expect command not found at /usr/bin/expect", data: [:], hypothesisId: "G")
            throw TransferError(message: "expect command not found. Please install expect: brew install expect")
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        process.arguments = [scriptFile.path]
        
        // #region agent log
        debugLog(location: "SSHTransport.swift:474", message: "Expect command configured", data: ["scriptPath": scriptFile.path, "expectPath": "/usr/bin/expect"], hypothesisId: "H")
        // #endregion
    } else {
        process.executableURL = URL(fileURLWithPath: actualLaunchPath)
        process.arguments = actualArguments
    }

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    // Always capture real-time output for debugging, even if no handler provided
    var capturedStdout = Data()
    var capturedStderr = Data()
    
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        
    // Capture stdout in real time and redact secrets before anything reaches UI/debug logs.
        outHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                capturedStdout.append(data)
                if let string = String(data: data, encoding: .utf8) {
                    let redacted = redactSensitiveText(string, secrets: sensitiveValues)
                    print("🔍 DEBUG: Expect stdout: \(redacted)")
                    emitSanitizedLines(from: string, secrets: sensitiveValues, to: outputHandler)
                }
            }
        }
        
    // Capture stderr in real time and redact secrets before anything reaches UI/debug logs.
        errHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                capturedStderr.append(data)
                if let string = String(data: data, encoding: .utf8) {
                    let redacted = redactSensitiveText(string, secrets: sensitiveValues)
                    print("🔍 DEBUG: Expect stderr: \(redacted)")
                    emitSanitizedLines(from: string, secrets: sensitiveValues, to: outputHandler)
                }
            }
        }

    // Real-time output capture is now handled above for all cases

    do {
        // #region agent log
        let controlDirectory = try sshControlDirectory()
        process.currentDirectoryURL = controlDirectory
        
        debugLog(
            location: "SSHTransport.swift:467",
            message: "Starting process",
            data: [
                "launchPath": process.executableURL?.path ?? "unknown",
                "arguments": process.arguments ?? [],
                "workingDirectory": controlDirectory.path
            ],
            hypothesisId: "E"
        )
        // #endregion
        
        let inPipe = input == nil ? nil : Pipe()
        if let inPipe {
            process.standardInput = inPipe
        }
        
        try process.run()
        
        if let bridge = askpassBridge {
            startAskpassPromptPoller(bridge: bridge, outputHandler: outputHandler)
        }
        
        if let input, let inPipe {
            inPipe.fileHandleForWriting.write(input)
            inPipe.fileHandleForWriting.closeFile()
        }
    } catch {
        // #region agent log
        debugLog(location: "SSHTransport.swift:477", message: "Failed to launch process", data: ["error": error.localizedDescription], hypothesisId: "F")
        // #endregion
        if let directory = askpassBridge?.directory {
            try? FileManager.default.removeItem(at: directory)
        }
        throw TransferError(message: "Failed to launch command: \(error.localizedDescription)")
    }

    let group = DispatchGroup()
    group.enter()
    
    // Set up termination handler for cleanup
    let scriptToCleanup = expectScriptFile
    let askpassDirectoryToCleanup = askpassBridge?.directory
    process.terminationHandler = { _ in
        // Always clear handlers
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        if let script = scriptToCleanup {
            try? FileManager.default.removeItem(at: script)
        }
        if let directory = askpassDirectoryToCleanup {
            try? FileManager.default.removeItem(at: directory)
        }
        group.leave()
    }

    let deadline = DispatchTime.now() + timeout
    if group.wait(timeout: deadline) == .timedOut {
        process.terminate()
        if let directory = askpassDirectoryToCleanup {
            try? FileManager.default.removeItem(at: directory)
        }
        throw TransferError(message: "Command timed out")
    }

	    // Use captured data if available, otherwise read from pipes
	    let stdout = capturedStdout.isEmpty ? outPipe.fileHandleForReading.readDataToEndOfFile() : capturedStdout
	    let stderr = capturedStderr.isEmpty ? errPipe.fileHandleForReading.readDataToEndOfFile() : capturedStderr
	    
	        // #region agent log
	        let stderrStr = String(data: stderr, encoding: .utf8) ?? ""
	        let stdoutStr = String(data: stdout, encoding: .utf8) ?? ""
        let safeStderrStr = redactSensitiveText(stderrStr, secrets: sensitiveValues)
        let safeStdoutStr = redactSensitiveText(stdoutStr, secrets: sensitiveValues)
        
        // #region agent log
        // Summarize auth-related markers so we don't need to parse huge buffers later
        let lowerCombined = (stderrStr + "\n" + stdoutStr).lowercased()
        let promptMarkers: [String: Bool] = [
            "permissionDenied": lowerCombined.contains("permission denied"),
            "duo": lowerCombined.contains("duo"),
            "verification": lowerCombined.contains("verification code") || lowerCombined.contains("verification"),
            "passcode": lowerCombined.contains("passcode"),
            "keyboardInteractive": lowerCombined.contains("keyboard-interactive"),
            "passwordPrompt": lowerCombined.contains("password:")
        ]
        debugLog(
            location: "SSHTransport.swift:authMarkers",
            message: "Auth markers summary",
            data: [
                "exitCode": process.terminationStatus,
                "markers": promptMarkers,
                "launchId": launchId,
                "stderrLen": stderrStr.count,
                "stdoutLen": stdoutStr.count,
	                "stderrHead": String(safeStderrStr.prefix(400)),
	                "stdoutHead": String(safeStdoutStr.prefix(400))
	            ],
	            hypothesisId: "H5"
	        )
	        // #endregion
	        
	        if !safeStderrStr.isEmpty {
	            print("🔍 DEBUG: Expect stderr output:\n\(safeStderrStr)")
	        }
	        if !safeStdoutStr.isEmpty {
	            print("🔍 DEBUG: Expect stdout output:\n\(safeStdoutStr)")
	        }
	        
	        debugLog(location: "SSHTransport.swift:452", message: "Process completed", data: ["exitCode": process.terminationStatus, "stderrLength": stderrStr.count, "stdoutLength": stdoutStr.count, "stderrPreview": String(safeStderrStr.prefix(500)), "stdoutPreview": String(safeStdoutStr.prefix(500)), "fullStderr": safeStderrStr, "fullStdout": safeStdoutStr, "launchId": launchId], hypothesisId: "D")
        // #endregion
    
        // If process failed, provide better error message
        if process.terminationStatus != 0 {
            // Debug: Log the command that failed (for troubleshooting)
            let commandStr = "\(actualLaunchPath) \(actualArguments.joined(separator: " "))"
            print("SSH command failed: \(commandStr)")
            if password != nil {
                print("Using expect for password authentication")
            }
            print("Exit code: \(process.terminationStatus)")
	            print("Stderr: \(safeStderrStr)")
	            print("Stdout: \(safeStdoutStr)")
            
            var errorMsg = userFacingSSHFailureMessage(
                stderr: stderrStr,
                stdout: stdoutStr,
                exitCode: process.terminationStatus,
                usedExpect: useExpect
            )
            
            // Clean up unusual system error suffixes such as ": -65563".
            if errorMsg.contains(": -") {
                if let sshErrorRange = errorMsg.range(of: "ssh:") {
                    let sshError = String(errorMsg[sshErrorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let codeRange = sshError.range(of: ": -") {
                        let cleanError = String(sshError[..<codeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleanError.isEmpty {
                            errorMsg = "ssh: " + cleanError
                        }
                    } else if !sshError.isEmpty {
                        errorMsg = "ssh: " + sshError
                    }
                } else if let colonRange = errorMsg.range(of: ": -") {
                    errorMsg = String(errorMsg[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            
	        throw TransferError(message: redactSensitiveText(errorMsg, secrets: sensitiveValues))
	    }

    return (process.terminationStatus, stdout, stderr)
}

func parseLsLong(_ data: Data, baseDirectory: String = "/") -> [RemoteItem] {
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    var items: [RemoteItem] = []
    for line in text.split(separator: "\n") {
        let rawLine = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawLine.isEmpty,
              !rawLine.hasPrefix("sftp>"),
              !rawLine.hasPrefix("Fetching "),
              !rawLine.hasPrefix("Uploading "),
              !rawLine.hasPrefix("Connected to "),
              !rawLine.hasPrefix("Remote working directory: "),
              !rawLine.hasPrefix("total ") else {
            continue
        }
        
        // crude parser for lines like: drwxr-xr-x  2 user group    4096 Jan  1 12:00 Documents
        let parts = rawLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 9 else { continue }
        let perms = parts[0]
        let isDir = perms.first == "d"
        // size typically at index 4, but may vary; attempt to find a numeric field
        let sizeField = parts.first { Int64($0) != nil }
        let size = sizeField.flatMap { Int64($0) } ?? 0
        let name = parts.suffix(from: 8).joined(separator: " ")
        guard name != "." && name != ".." else { continue }
        let normalizedBase = baseDirectory.isEmpty ? "/" : baseDirectory
        let path = name.hasPrefix("/")
            ? name
            : normalizedBase == "/" ? "/\(name)" : "\(normalizedBase)/\(name)"
        let item = RemoteItem(name: name, path: path, isDirectory: isDir, size: size, permissions: String(perms))
        items.append(item)
    }
    return items
}

// MARK: - SFTP

final class SFTPClient: Transporting {
    private let connection: Connection
    private let auth: SSHAuthConfig

    init(connection: Connection) {
        self.connection = connection
        // Use privateKeyPath only if usesKeyAuth is true and path is provided
        let keyPath = connection.usesKeyAuth ? connection.privateKeyPath : nil
        // Trim hostname and username to prevent DNS resolution issues
        let trimmedHost = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.auth = SSHAuthConfig(host: trimmedHost, port: connection.port, username: trimmedUser, privateKeyPath: keyPath, password: connection.getPassword())
    }

    func connect(outputHandler: ((String) -> Void)? = nil) async throws {
        // #region agent log
        debugLog(
            location: "SSHTransport.swift:SFTPClient.connect",
            message: "connect_start",
            data: [
                "host": auth.host,
                "port": auth.port,
                "username": auth.username,
                "usesKeyAuth": auth.privateKeyPath != nil,
                "hasPassword": auth.password != nil
            ],
            hypothesisId: "H3"
        )
        // #endregion
        
        var keywordLogCount = 0
        let wrappedHandler: ((String) -> Void)? = { line in
            outputHandler?(line)
            let lower = line.lowercased()
            if keywordLogCount < 5 &&
                (lower.contains("password") || lower.contains("passcode") || lower.contains("verification") || lower.contains("duo") || lower.contains("keyboard")) {
                keywordLogCount += 1
                // #region agent log
                debugLog(
                    location: "SSHTransport.swift:SFTPClient.connect",
                    message: "ssh_output_line",
                    data: ["line": line, "count": keywordLogCount],
                    hypothesisId: "H3"
                )
                // #endregion
            }
        }
        
        let _ = try runSFTPBatch(
            commands: ["pwd"],
            timeout: 300,
            outputHandler: wrappedHandler,
            interactiveAuthentication: true
        )
        // runProcess now throws on error, so if we get here, it succeeded
    }

    func list(directory: RemotePath) async throws -> [RemoteItem] {
        let dir = directory.rawValue.isEmpty ? "." : directory.rawValue
        let result = try runSFTPBatch(commands: ["ls -la \(sftpQuote(dir))"], timeout: 60)
        // runProcess now throws on error, so if we get here, it succeeded
        return parseLsLong(result.stdout, baseDirectory: directory.rawValue)
    }

    func openDirectory(_ item: RemoteItem) async throws -> RemotePath {
        RemotePath(rawValue: item.path)
    }

    func download(item: RemoteItem, to localURL: URL, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        let command = "get -r \(sftpQuote(item.path)) \(sftpQuote(localURL.path))"
        let _ = try runSFTPBatch(commands: [command], timeout: 60 * 60)
        // runProcess throws on error, so if we get here, it succeeded
    }

    func upload(localURL: URL, to directory: RemotePath, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        let command = "put -r \(sftpQuote(localURL.path)) \(sftpQuote(directory.rawValue))"
        let _ = try runSFTPBatch(commands: [command], timeout: 60 * 60)
        // runProcess throws on error, so if we get here, it succeeded
    }
    
    func delete(item: RemoteItem) async throws {
        let command = item.isDirectory ? "rmdir \(sftpQuote(item.path))" : "rm \(sftpQuote(item.path))"
        let _ = try runSFTPBatch(commands: [command], timeout: 60)
    }
    
    func rename(item: RemoteItem, to newName: String) async throws {
        let directory = (item.path as NSString).deletingLastPathComponent
        let newPath = directory.hasSuffix("/") ? "\(directory)\(newName)" : "\(directory)/\(newName)"
        let _ = try runSFTPBatch(commands: ["rename \(sftpQuote(item.path)) \(sftpQuote(newPath))"], timeout: 60)
    }
    
    func createDirectory(name: String, in directory: RemotePath) async throws {
        let baseDir = directory.rawValue
        let newPath = baseDir.hasSuffix("/") ? "\(baseDir)\(name)" : "\(baseDir)/\(name)"
        let _ = try runSFTPBatch(commands: ["mkdir \(sftpQuote(newPath))"], timeout: 60)
    }
    
    func changePermissions(item: RemoteItem, permissions: String) async throws {
        let _ = try runSFTPBatch(commands: ["chmod \(permissions) \(sftpQuote(item.path))"], timeout: 60)
    }
    
    private func runSFTPBatch(commands: [String], timeout: TimeInterval, outputHandler: ((String) -> Void)? = nil, interactiveAuthentication: Bool = false) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let batchURL = FileManager.default.temporaryDirectory.appendingPathComponent("shuttler_sftp_\(UUID().uuidString).batch")
        let batch = commands.joined(separator: "\n") + "\n"
        try batch.write(to: batchURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: batchURL)
        }
        
        let args = SSHExec.sftpArgs(auth, extra: ["-b", batchURL.path], allowPrompts: interactiveAuthentication)
        return try runProcess(
            launchPath: "/usr/bin/sftp",
            arguments: args,
            password: auth.password,
            timeout: timeout,
            outputHandler: outputHandler,
            interactiveAuthentication: interactiveAuthentication
        )
    }
    
    private func sftpQuote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// MARK: - SCP

final class SCPClient: Transporting {
    private let connection: Connection
    private let auth: SSHAuthConfig

    init(connection: Connection) {
        self.connection = connection
        // Use privateKeyPath only if usesKeyAuth is true and path is provided
        let keyPath = connection.usesKeyAuth ? connection.privateKeyPath : nil
        // Trim hostname and username to prevent DNS resolution issues
        let trimmedHost = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.auth = SSHAuthConfig(host: trimmedHost, port: connection.port, username: trimmedUser, privateKeyPath: keyPath, password: connection.getPassword())
    }

    func connect(outputHandler: ((String) -> Void)? = nil) async throws {
        // #region agent log
        debugLog(
            location: "SSHTransport.swift:SCPClient.connect",
            message: "connect_start",
            data: [
                "host": auth.host,
                "port": auth.port,
                "username": auth.username,
                "usesKeyAuth": auth.privateKeyPath != nil,
                "hasPassword": auth.password != nil
            ],
            hypothesisId: "H4"
        )
        // #endregion

        var keywordLogCount = 0
        let wrappedHandler: ((String) -> Void)? = { line in
            outputHandler?(line)
            let lower = line.lowercased()
            if keywordLogCount < 5 &&
                (lower.contains("password") || lower.contains("passcode") || lower.contains("verification") || lower.contains("duo") || lower.contains("keyboard")) {
                keywordLogCount += 1
                // #region agent log
                debugLog(
                    location: "SSHTransport.swift:SCPClient.connect",
                    message: "ssh_output_line",
                    data: ["line": line, "count": keywordLogCount],
                    hypothesisId: "H4"
                )
                // #endregion
            }
        }

        // Some keyboard-interactive stacks, including Duo/PAM configurations,
        // will deny before presenting prompts unless the SSH session has a TTY.
        let args = SSHExec.sshArgs(auth, extra: ["echo", "ok"], allowPrompts: true, requestTTY: true)
        do {
            let _ = try runProcess(
                launchPath: "/usr/bin/ssh",
                arguments: args,
                password: auth.password,
                timeout: 300,
                outputHandler: wrappedHandler,
                interactiveAuthentication: true
            )
        } catch let error as TransferError {
            guard shouldRetryWithDefaultKeys(after: error) else {
                throw error
            }
            
            outputHandler?("Keyboard-interactive was denied before any prompt; retrying with local SSH keys enabled...")
            let fallbackArgs = SSHExec.sshArgs(
                auth,
                extra: ["echo", "ok"],
                allowPrompts: true,
                requestTTY: true,
                allowDefaultKeys: true
            )
            let _ = try runProcess(
                launchPath: "/usr/bin/ssh",
                arguments: fallbackArgs,
                password: auth.password,
                timeout: 300,
                outputHandler: wrappedHandler,
                interactiveAuthentication: true,
                allowSSHAgent: true
            )
        }
        // runProcess throws on error, so if we get here, it succeeded
    }

    private func shouldRetryWithDefaultKeys(after error: TransferError) -> Bool {
        guard auth.password != nil, auth.privateKeyPath == nil else { return false }
        return error.message.lowercased().contains("keyboard-interactive authentication was denied before shuttler received a prompt")
    }

    func list(directory: RemotePath) async throws -> [RemoteItem] {
        // SCP has no native list; use ssh ls
        let dir = directory.rawValue.isEmpty ? "." : directory.rawValue
        let args = SSHExec.sshArgs(auth, extra: ["ls", "-la", dir])
        let result = try runProcess(launchPath: "/usr/bin/ssh", arguments: args, password: auth.password)
        // runProcess throws on error, so if we get here, it succeeded
        return parseLsLong(result.stdout, baseDirectory: directory.rawValue)
    }

    func openDirectory(_ item: RemoteItem) async throws -> RemotePath {
        RemotePath(rawValue: item.path)
    }

    func download(item: RemoteItem, to localURL: URL, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        let remote = "\(auth.username)@\(auth.host):\(item.path)"
        var args = SSHExec.scpArgs(auth, extra: ["-r"]) // -r to handle directories
        args += [remote, localURL.path]
        let _ = try runProcess(launchPath: "/usr/bin/scp", arguments: args, password: auth.password, timeout: 60 * 60)
        // runProcess throws on error, so if we get here, it succeeded
    }

    func upload(localURL: URL, to directory: RemotePath, progressCallback: ((Int64, Int64) -> Void)? = nil) async throws {
        let remote = "\(auth.username)@\(auth.host):\(directory.rawValue)"
        var args = SSHExec.scpArgs(auth, extra: ["-r"]) // -r to handle directories
        args += [localURL.path, remote]
        let _ = try runProcess(launchPath: "/usr/bin/scp", arguments: args, password: auth.password, timeout: 60 * 60)
        // runProcess throws on error, so if we get here, it succeeded
    }
    
    func delete(item: RemoteItem) async throws {
        let command = item.isDirectory ? "rm -rf" : "rm"
        let args = SSHExec.sshArgs(auth, extra: [command, item.path])
        let _ = try runProcess(launchPath: "/usr/bin/ssh", arguments: args, password: auth.password)
    }
    
    func rename(item: RemoteItem, to newName: String) async throws {
        let directory = (item.path as NSString).deletingLastPathComponent
        let newPath = directory.hasSuffix("/") ? "\(directory)\(newName)" : "\(directory)/\(newName)"
        let args = SSHExec.sshArgs(auth, extra: ["mv", item.path, newPath])
        let _ = try runProcess(launchPath: "/usr/bin/ssh", arguments: args, password: auth.password)
    }
    
    func createDirectory(name: String, in directory: RemotePath) async throws {
        let baseDir = directory.rawValue
        let newPath = baseDir.hasSuffix("/") ? "\(baseDir)\(name)" : "\(baseDir)/\(name)"
        let args = SSHExec.sshArgs(auth, extra: ["mkdir", "-p", newPath])
        let _ = try runProcess(launchPath: "/usr/bin/ssh", arguments: args, password: auth.password)
    }
}
