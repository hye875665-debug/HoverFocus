import AppKit
import ApplicationServices

@main
@MainActor
struct WindowRegressionChecks {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard AXIsProcessTrusted() else {
      fatalError("Window integration checks require Accessibility permission.")
    }
    Task { @MainActor in
      await runChecks()
      app.terminate(nil)
    }
    app.run()
  }

  static func runChecks() async {
    let window = NSWindow(
      contentRect: NSRect(x: 60, y: 180, width: 360, height: 200),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "HoverFocus 窗口检查"
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    defer { window.close() }
    try? await Task.sleep(for: .milliseconds(250))

    let nativePoint = CGPoint(x: window.frame.midX, y: window.frame.midY)
    precondition(
      NSWindow.windowNumber(at: nativePoint, belowWindowWithWindowNumber: 0) == window.windowNumber,
      "Test window must be visible before assertions")

    let point = CGPoint(
      x: window.frame.midX,
      y: NSScreen.screens[0].frame.maxY - window.frame.midY)
    let resolver = AccessibilityWindowResolver()
    precondition(resolver.target(at: point) == nil, "Unregistered own windows must be excluded")

    window.identifier = AccessibilityWindowResolver.settingsWindowIdentifier
    guard let target = resolver.target(at: point) else {
      fatalError("Registered settings window was not resolved")
    }
    precondition(target.localWindowNumber == window.windowNumber)
    precondition(target.processID == ProcessInfo.processInfo.processIdentifier)
    precondition(resolver.activate(target), "Settings window should become key")
    try? await Task.sleep(for: .milliseconds(150))
    precondition(resolver.isFocused(target), "Focused settings must not be repeatedly raised")

    let panel = NSPanel(
      contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = .popUpMenu
    panel.orderFrontRegardless()
    try? await Task.sleep(for: .milliseconds(150))
    precondition(resolver.target(at: point) == nil, "A menu panel must block the window below it")
    panel.orderOut(nil)
    panel.close()

    window.orderOut(nil)
    precondition(
      !resolver.activate(target), "A closed or hidden settings window must not be restored")
    print("PASS: own settings eligibility, native focus, menu exclusion, stale-window protection")
  }
}
