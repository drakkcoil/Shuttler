# Adding SwiftNIO SSH Dependency

To add SwiftNIO SSH to your Xcode project:

1. Open `Shuttler.xcodeproj` in Xcode
2. Select the project in the navigator
3. Select the `Shuttler` target
4. Go to the "Package Dependencies" tab
5. Click the "+" button
6. Enter the package URL: `https://github.com/apple/swift-nio-ssh.git`
7. Select version: `0.9.2` or later
8. Click "Add Package"
9. Select the products to add:
   - `NIOSSH`
   - `NIOCore` (if not already included)
   - `NIOPosix` (if not already included)
10. Click "Add Package"

After adding the dependency, the `NativeSCPClient.swift` file should compile.

