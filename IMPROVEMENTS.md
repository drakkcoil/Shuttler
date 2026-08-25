# Shuttler App - Enhancement & Fix Recommendations

This document outlines identified bugs, unfinished features, and potential enhancements for the Shuttler file transfer application.

## 🔴 Critical Issues

### 1. **Security: Passwords Not Stored in Keychain**
**Current State**: Passwords are stored in plain text in `connections.json` file.
**Location**: `Models.swift` - Connection struct stores password as optional String
**Impact**: HIGH - Security risk. README claims passwords are stored in Keychain, but this is not implemented.
**Recommendation**: 
- Implement Keychain storage for passwords using `Security.framework`
- Store passwords with service identifier: `com.shuttler.connection.password`
- Update Connection model to store password reference instead of actual password
- Implement migration path for existing connections

**Files to modify:**
- `Models.swift` - Update Connection struct
- Create `KeychainManager.swift` - New utility class for Keychain operations
- `PreferencesView.swift` - Update connection creation/editing to use Keychain

---

### 2. **SSH Key Authentication Not Fully Implemented**
**Current State**: TODO comments indicate private key loading is not implemented for native clients.
**Locations**: 
- `NativeSFTPClient.swift:1094` - `// TODO: Load and parse private key from privateKeyPath`
- `NativeSCPClient.swift:630` - `// TODO: Load and parse private key from privateKeyPath`
**Impact**: HIGH - SSH key authentication is broken for native SFTP/SCP implementations.
**Recommendation**:
- Implement private key loading and parsing (support PEM, PKCS8, OpenSSH formats)
- Integrate with NIOSSH's public key authentication
- Add key passphrase support (store in Keychain)

---

## 🟠 Unfinished Features (from README TODO)

### 3. **Multi-Select File Selection Issues**
**Current State**: Multi-select appears to be implemented (`selectedItems: Set<RemoteItem>`), but user reports it's not working.
**Location**: `ContentView.swift` - Lines 850, 1907-1939
**Recommendation**:
- Test multi-select functionality thoroughly
- Verify Command-click and Shift-click selection works correctly
- Check if UI properly reflects multiple selections visually
- Ensure all operations (download, delete, copy, etc.) work with multi-select
- Consider adding a selection count indicator

---

### 4. **Quick Look Preview Issues**
**Current State**: Quick Look is implemented but downloads file to temp location first.
**Location**: `ContentView.swift:1367-1382`
**Issues**:
- Downloads entire file before preview (slow for large files)
- Temp file cleanup uses fixed 10-second delay (could fail if app closes)
- No progress indicator during download for preview
**Recommendation**:
- Implement streaming preview for supported file types (images, text files)
- Use proper temp file cleanup with file coordinators
- Add download progress indicator for large files
- Consider implementing native preview generation for common formats

---

### 5. **Edit Remote File - Missing Upload Back**
**Current State**: `editFile()` downloads file to temp location and opens it, but there's no mechanism to upload changes back.
**Location**: 
- `RemoteBrowserViewModel.swift:338-347` - Downloads file
- `ContentView.swift:2307-2317` - Opens file in default app
**Impact**: Feature is incomplete - users can edit files but changes aren't saved.
**Recommendation**:
- Implement file watching for temp file changes
- Add UI prompt to upload changes when file is modified
- Use FileCoordinator or FSEvents to detect file changes
- Add "Upload Changes" button or automatic sync
- Handle conflicts if remote file changed while editing

**Implementation approach**:
```swift
// Monitor temp file for changes
// When file is closed/modified, prompt user to upload
// Upload back to same remote path
```

---

### 6. **SCP MFA/Interactive Authentication Not Working**
**Current State**: 
- `InteractiveAuthPromptView.swift` exists and looks well-designed
- Native SCP client doesn't handle interactive auth prompts
- SSHTransport uses expect script but may not handle MFA properly
**Location**: 
- `NativeSCPClient.swift` - Uses NIOSSH but no interactive auth handler
- `SSHTransport.swift` - Expect script handles password but not MFA prompts
**Impact**: Users cannot connect to servers requiring MFA (e.g., Cisco Duo).
**Recommendation**:
- For native SCP: Implement `NIOSSHClientUserAuthDelegate` to handle interactive authentication challenges
- For SSHTransport: Enhance expect script to detect MFA prompts and use InteractiveAuthPromptView
- Detect Duo/Cisco MFA prompts and show InteractiveAuthPromptView
- Integrate user response back into authentication flow

**Implementation approach**:
```swift
// In NativeSCPClient, implement challenge handler
// Detect interactive auth prompts
// Show InteractiveAuthPromptView modal
// Pass user response back to NIOSSH
```

---

## 🟡 Bugs & Issues

### 7. **Temp File Cleanup in Quick Look**
**Issue**: Fixed 10-second delay for cleanup can fail if app closes or user navigates away.
**Location**: `ContentView.swift:1377`
**Recommendation**: 
- Use FileCoordinator or Track temp files with UUID mapping
- Clean up on app termination
- Clean up immediately when preview window closes
- Use proper resource management

---

### 8. **Connection State Management Complexity**
**Issue**: Complex logic in `RemoteBrowserViewModel.updateConnection()` and `restoreConnectionIfNeeded()` suggests potential race conditions or state sync issues.
**Location**: `RemoteBrowserViewModel.swift:39-102`
**Recommendation**:
- Simplify connection state management
- Add state machine for connection lifecycle
- Better error handling for connection restore failures
- Add logging for state transitions

---

### 9. **Password Storage in Memory**
**Issue**: Passwords may remain in memory longer than necessary.
**Recommendation**:
- Use secure memory allocation where possible
- Clear password variables immediately after use
- Consider using Data instead of String for passwords

---

### 10. **Error Handling for Large File Transfers**
**Issue**: No clear handling for network interruptions during large transfers.
**Recommendation**:
- Implement transfer resumption for SFTP
- Add retry logic with exponential backoff
- Better error messages for network issues
- Allow users to pause/resume transfers

---

## 🟢 Enhancements

### 11. **Transfer Queue Management**
**Recommendation**:
- Allow users to queue multiple transfers
- Prioritize transfers (high/medium/low)
- Pause/resume individual transfers
- Better visualization of queued vs. active transfers

---

### 12. **Directory Transfer Progress**
**Current State**: Directory transfers show individual file progress but not overall directory progress.
**Recommendation**:
- Add aggregate progress for directory transfers
- Show file count (e.g., "5 of 20 files")
- Better visualization of nested directory transfers

---

### 13. **File Search/Filter**
**Recommendation**:
- Add search bar to filter files in current directory
- Support regex patterns
- Filter by name, size, date, type
- Quick filter buttons for common types

---

### 14. **Favorite Directories**
**Recommendation**:
- Allow users to bookmark favorite remote directories
- Quick navigation to bookmarked directories
- Show bookmarks in sidebar or breadcrumb menu

---

### 15. **Connection Profiles**
**Recommendation**:
- Support connection templates/profiles
- Save common connection configurations
- Quick connect from profiles
- Export/import connection profiles

---

### 16. **Better Transfer History**
**Current State**: Transfer window shows active/completed transfers.
**Recommendation**:
- Persistent transfer history (across app restarts)
- Filter by date, connection, success/failure
- Export transfer logs
- Statistics (total transferred, average speed, etc.)

---

### 17. **Keyboard Shortcuts Improvements**
**Recommendation**:
- Add more keyboard shortcuts for common actions
- Customizable keyboard shortcuts
- Shortcut conflicts detection
- Help overlay showing all shortcuts

---

### 18. **File Type Icons**
**Current State**: Basic file type detection with system icons.
**Location**: `ContentView.swift:1987-2020`
**Recommendation**:
- More comprehensive file type detection
- Custom icons for common file types
- Better folder/directory icon differentiation
- Support for custom file associations

---

### 19. **Connection Testing**
**Recommendation**:
- "Test Connection" button in connection editor
- Validate connection before saving
- Connection diagnostics tool
- Ping/latency information

---

### 20. **Batch Operations**
**Recommendation**:
- Batch rename files
- Batch change permissions
- Batch move/copy operations
- Undo/redo for file operations

---

### 21. **Sync/Mirror Functionality**
**Recommendation**:
- Sync local and remote directories
- Two-way sync option
- Conflict resolution UI
- Scheduled sync

---

### 22. **Transfer Speed Limiting**
**Recommendation**:
- Allow users to limit transfer speed
- Schedule transfers for off-peak hours
- Bandwidth management per connection

---

### 23. **Remote File Preview Improvements**
**Recommendation**:
- Thumbnail generation for images
- Text file preview in-app (no download needed)
- Code syntax highlighting for text previews
- PDF preview in-app

---

### 24. **Better Error Messages**
**Recommendation**:
- More user-friendly error messages
- Error recovery suggestions
- Links to documentation for common errors
- Error reporting/logging

---

### 25. **Connection Timeout Configuration**
**Current State**: Hardcoded timeouts in various places.
**Recommendation**:
- User-configurable timeouts
- Per-connection timeout settings
- Automatic retry with backoff

---

### 26. **File Comparison**
**Recommendation**:
- Compare local and remote files
- Show diff for text files
- Highlight differences
- Sync based on comparison

---

### 27. **SSH Host Key Management**
**Current State**: All host keys are accepted (`AcceptAllHostKeysDelegate`).
**Recommendation**:
- Store known host keys
- Warn on host key changes
- Allow user to verify and accept host keys
- Better security posture

---

### 28. **Logging & Debugging**
**Recommendation**:
- Comprehensive logging system
- Log levels (debug, info, warn, error)
- Export logs for troubleshooting
- In-app log viewer
- Performance metrics logging

---

### 29. **Accessibility Improvements**
**Recommendation**:
- VoiceOver support improvements
- Keyboard navigation enhancements
- High contrast mode support
- Accessibility labels for all UI elements

---

### 30. **Dark Mode Polish**
**Recommendation**:
- Ensure all UI elements support dark mode properly
- Custom color schemes
- User preference for appearance

---

## 📋 Priority Summary

### P0 (Critical - Fix Immediately)
1. Password Keychain storage (#1)
2. SSH key authentication (#2)
3. SCP MFA support (#6)

### P1 (High Priority - Next Release)
4. Edit file upload back (#5)
5. Quick Look improvements (#4)
6. Multi-select fixes (#3)
7. Temp file cleanup (#7)

### P2 (Medium Priority - Future Releases)
8. Transfer queue management (#11)
9. File search/filter (#13)
10. Better error handling (#10)
11. Connection testing (#19)

### P3 (Nice to Have)
12. All other enhancements (#12-30)

---

## 🔍 Code Quality Improvements

### Technical Debt
- **Large ContentView.swift file** (3144 lines) - Consider breaking into smaller views
- **State management** - Consider using more structured state management (e.g., TCA, Swift Composable Architecture)
- **Error types** - Create more specific error types instead of generic `TransferError`
- **Testing** - Add unit tests for core functionality (transfers, connection management)
- **Documentation** - Add inline documentation for complex functions
- **Code organization** - Consider feature-based folder structure instead of type-based

---

## 📝 Notes

- The app has a solid foundation with good separation of concerns
- Native SFTP/SCP implementations are well-structured but incomplete
- UI is modern and follows macOS design guidelines
- Consider creating a formal bug tracking system or issue tracker
- Regular code reviews would help catch issues earlier

---

*Generated from code review on 2025-01-XX*
