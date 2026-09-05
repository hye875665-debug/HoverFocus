import AppKit
import ApplicationServices

/// Integration check that raises one explicitly named app's exposed window.
/// No mouse/keyboard events are generated and no window contents are read.
@main
@MainActor
struct WindowActivationCheck {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
      await runCheck()
      app.terminate(nil)
    }
    app.run()
  }

  static func runCheck() async {
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" {
      print("BLOCKED: unlock the desktop before checking window activation")
      exit(2)
    }
    guard let bundle = CommandLine.arguments.dropFirst().first,
      let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        .first,
      AXIsProcessTrusted()
    else {
      print("BLOCKED: specify a running app bundle ID; Accessibility permission is required")
      exit(2)
    }
    let resolver = AccessibilityWindowResolver()
    let windows =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    var selected: WindowTarget?
    for info in windows {
      guard info[kCGWindowOwnerPID as String] as? Int32 == application.processIdentifier,
        info[kCGWindowLayer as String] as? Int == 0,
        let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: dictionary)
      else { continue }
      for x in [0.1, 0.5, 0.9] {
        for y in [0.1, 0.5, 0.9] {
          let point = CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
          if let target = resolver.target(at: point),
            target.processID == application.processIdentifier
          {
            selected = target
          }
        }
      }
    }
    guard let target = selected else {
      print("BLOCKED: no exposed, eligible target window")
      exit(2)
    }
    let accepted = resolver.activate(target)
    try? await Task.sleep(for: .milliseconds(400))
    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID
    let focused = resolver.isFocused(target)
    print(
      "activationAccepted=\(accepted) frontmost=\(foreground) exactWindowFocused=\(focused) hasAX=\(target.element != nil)"
    )
    precondition(foreground && focused, "The target window did not acquire focus")
    print("PASS: exposed target resolved and focused without a synthetic click")
  }
}
