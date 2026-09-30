import AppKit
import CoreBluetooth
import SmartScreenCore

// 골격: CI 가 macOS 러너에서 AppKit/CoreBluetooth 로 링크되는지만 본다.
let app = NSApplication.shared
print("SmartScreen \(BuildInfo.version)")
if CommandLine.arguments.contains("--version") { exit(0) }
app.setActivationPolicy(.accessory)
app.run()
