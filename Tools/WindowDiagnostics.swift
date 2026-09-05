import AppKit
import ApplicationServices
import CoreGraphics

/// Read-only developer check. Reports window geometry and AX error codes,
/// never titles, text contents, pixels, input events, or user preferences.
@main
@MainActor
struct WindowDiagnostics {
  static func main() {
    _ = NSApplication.shared
    let requestedBundle = CommandLine.arguments.dropFirst().first ?? "com.tencent.xinWeChat"
    let roots = NSRunningApplication.runningApplications(withBundleIdentifier: requestedBundle)
    let applications = NSWorkspace.shared.runningApplications.filter { app in
      app.bundleIdentifier == requestedBundle
        || roots.contains { root in
          guard let bundle = root.bundleURL, let executable = app.executableURL else {
            return false
          }
          return executable.path.hasPrefix(bundle.path + "/")
        }
    }
    print("accessibilityTrusted=\(AXIsProcessTrusted())")
    print("frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
    for app in applications {
      let element = AXUIElementCreateApplication(app.processIdentifier)
      AXUIElementSetMessagingTimeout(element, 0.5)
      var value: CFTypeRef?
      let error = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
      let windows = value as? [AXUIElement] ?? []
      print(
        "application bundle=\(app.bundleIdentifier ?? "unknown") pid=\(app.processIdentifier) policy=\(app.activationPolicy.rawValue) hidden=\(app.isHidden) active=\(app.isActive) AXWindowsError=\(error.rawValue) windowCount=\(windows.count)"
      )
      for window in windows {
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
        let subroleError = AXUIElementCopyAttributeValue(
          window, kAXSubroleAttribute as CFString, &subrole)
        print(
          "  AXWindow role=\(role as? String ?? "nil") roleError=\(roleError.rawValue) subrole=\(subrole as? String ?? "nil") subroleError=\(subroleError.rawValue)"
        )
      }
    }

    let processIDs = Set(applications.map(\.processIdentifier))
    let allWindows =
      CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    let windows =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    print("onscreenCount=\(windows.count) allCount=\(allWindows.count)")
    let resolver = AccessibilityWindowResolver()
    for (index, info) in windows.enumerated() {
      guard let owner = info[kCGWindowOwnerPID as String] as? Int32,
        processIDs.contains(owner),
        let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
      else { continue }
      let visible = info[kCGWindowIsOnscreen as String] as? Bool ?? false
      let layer = info[kCGWindowLayer as String] as? Int ?? -1
      print(
        "quartz index=\(index) id=\(info[kCGWindowNumber as String] ?? "nil") pid=\(owner) visible=\(visible) layer=\(layer) alpha=\(info[kCGWindowAlpha as String] ?? "nil") bounds=\(bounds)"
      )
      guard visible, bounds.width >= 80, bounds.height >= 50 else { continue }
      for (x, y) in [(0.1, 0.1), (0.5, 0.5), (0.9, 0.9)] {
        let point = CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
        let appKitPoint = CGPoint(
          x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        print(
          "  nativeHit=\(NSWindow.windowNumber(at: appKitPoint, belowWindowWithWindowNumber: 0))")
        var hit: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(
          AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
        var hitPID: pid_t = 0
        if let hit { AXUIElementGetPid(hit, &hitPID) }
        print("  hitError=\(hitError.rawValue) hitPID=\(hitPID)")
        let surfaces = windows.filter { surface in
          guard surface[kCGWindowIsOnscreen as String] as? Bool == true,
            let dictionary = surface[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: dictionary)
          else { return false }
          return rect.contains(point)
        }
        for surface in surfaces.prefix(4) {
          print(
            "  surface owner=\(surface[kCGWindowOwnerName as String] ?? "nil") pid=\(surface[kCGWindowOwnerPID as String] ?? "nil") id=\(surface[kCGWindowNumber as String] ?? "nil") layer=\(surface[kCGWindowLayer as String] ?? "nil") alpha=\(surface[kCGWindowAlpha as String] ?? "nil") bounds=\(surface[kCGWindowBounds as String] ?? "nil")"
          )
        }
        if let target = resolver.target(at: point) {
          print(
            "  sample=\(x),\(y) targetPID=\(target.processID) token=\(target.id.accessibilityToken) hasAX=\(target.element != nil) focused=\(resolver.isFocused(target))"
          )
        } else {
          print("  sample=\(x),\(y) target=nil")
        }
      }
    }
  }
}
