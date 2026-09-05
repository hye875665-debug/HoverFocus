import AppKit
import ApplicationServices
import CoreGraphics
import HoverFocusCore

struct WindowTarget: @unchecked Sendable {
  let element: AXUIElement?
  let processID: pid_t
  let id: HoverWindowID
  let localWindowNumber: Int?

  init(
    element: AXUIElement?, processID: pid_t, id: HoverWindowID,
    localWindowNumber: Int? = nil
  ) {
    self.element = element
    self.processID = processID
    self.id = id
    self.localWindowNumber = localWindowNumber
  }

  func representsSameWindow(as other: WindowTarget) -> Bool {
    id == other.id
  }
}

@MainActor
protocol WindowResolving: AnyObject {
  func target(at point: CGPoint) -> WindowTarget?
  func isFocused(_ target: WindowTarget) -> Bool
  @discardableResult func activate(_ target: WindowTarget) -> Bool
}

@MainActor
final class AccessibilityWindowResolver: WindowResolving {
  static let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("HoverFocus.settings")
  private let systemWideElement = AXUIElementCreateSystemWide()
  private let allowedWindowSubroles: Set<String> = [
    kAXStandardWindowSubrole as String,
    kAXDialogSubrole as String,
    kAXSystemDialogSubrole as String,
  ]
  private let excludedBundleIdentifiers: Set<String> = [
    "com.apple.dock",
    "com.apple.systemuiserver",
    "com.apple.controlcenter",
    "com.apple.notificationcenterui",
    "com.apple.loginwindow",
  ]
  private let customRenderedBundleIdentifiers: Set<String> = [
    "com.tencent.xinWeChat"
  ]
  private var cachedQuartzWindows: [NSDictionary] = []
  private var quartzWindowCacheTime: TimeInterval = -.infinity
  private let quartzWindowCacheDuration: TimeInterval = 0.15

  func target(at point: CGPoint) -> WindowTarget? {
    guard AXIsProcessTrusted() else { return nil }

    if let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
      excludedBundleIdentifiers.contains(frontmostBundleID)
    {
      return nil
    }

    guard let quartzWindow = topmostQuartzWindow(at: point) else { return nil }

    if quartzWindow.processID == ProcessInfo.processInfo.processIdentifier {
      return localSettingsTarget(windowID: quartzWindow.windowID)
    }

    if let windowElement = directlyHitWindow(at: point),
      let directTarget = validatedTarget(for: windowElement),
      directTarget.processID == activationProcessID(forWindowOwner: quartzWindow.processID),
      let directFrame = windowFrame(windowElement),
      frameDistance(directFrame, from: quartzWindow.bounds) <= 24
    {
      return targetWithStableQuartzIdentity(directTarget, quartzWindow: quartzWindow)
    }

    // Custom-rendered apps such as WeChat may expose a standard top-level
    // window but omit AXWindow on elements inside the content area. Fall back
    // to Window Server bounds, then map the owning process back to one of its
    // standard Accessibility windows. No pixels or window titles are read.
    return fallbackTarget(at: point, quartzWindow: quartzWindow)
  }

  private func localSettingsTarget(windowID: CGWindowID) -> WindowTarget? {
    guard let window = localSettingsWindow(number: Int(windowID)) else { return nil }
    let processID = ProcessInfo.processInfo.processIdentifier
    return WindowTarget(
      element: nil,
      processID: processID,
      id: quartzIdentity(processID: processID, windowID: windowID),
      localWindowNumber: window.windowNumber
    )
  }

  private func localSettingsWindow(number: Int) -> NSWindow? {
    NSApp.windows.first {
      $0.windowNumber == number && $0.identifier == Self.settingsWindowIdentifier
        && $0.isVisible && !$0.isMiniaturized && $0.isOnActiveSpace
        && $0.level == .normal && $0.canBecomeKey
    }
  }

  private func directlyHitWindow(at point: CGPoint) -> AXUIElement? {
    var hitElement: AXUIElement?
    let hitError = AXUIElementCopyElementAtPosition(
      systemWideElement,
      Float(point.x),
      Float(point.y),
      &hitElement
    )
    guard hitError == .success, let hitElement else { return nil }

    if stringAttribute(kAXRoleAttribute, of: hitElement) == (kAXWindowRole as String) {
      return hitElement
    }
    return elementAttribute(kAXWindowAttribute, of: hitElement)
  }

  private func validatedTarget(for windowElement: AXUIElement) -> WindowTarget? {
    guard stringAttribute(kAXRoleAttribute, of: windowElement) == (kAXWindowRole as String),
      boolAttribute(kAXMinimizedAttribute, of: windowElement) != true
    else {
      return nil
    }

    var processID: pid_t = 0
    guard AXUIElementGetPid(windowElement, &processID) == .success,
      isEligibleApplication(processID: processID)
    else {
      return nil
    }

    let subrole = stringAttribute(kAXSubroleAttribute, of: windowElement)
    let bundleIdentifier = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
    let isKnownCustomWindow =
      bundleIdentifier.map(customRenderedBundleIdentifiers.contains) ?? false
    guard
      subrole.map(allowedWindowSubroles.contains) == true
        || (subrole == nil && isKnownCustomWindow)
    else {
      return nil
    }

    return WindowTarget(
      element: Optional(windowElement),
      processID: processID,
      id: HoverWindowID(
        processID: processID,
        accessibilityToken: CFHash(windowElement)
      )
    )
  }

  private func fallbackTarget(
    at point: CGPoint,
    quartzWindow: QuartzWindowTarget?
  ) -> WindowTarget? {
    guard let quartzWindow,
      let processID = activationProcessID(forWindowOwner: quartzWindow.processID)
    else { return nil }

    let applicationElement = AXUIElementCreateApplication(processID)
    let candidates = elementArrayAttribute(kAXWindowsAttribute, of: applicationElement)
      .compactMap { window -> (target: WindowTarget, frame: CGRect)? in
        guard let target = validatedTarget(for: window),
          let frame = windowFrame(window),
          frame.insetBy(dx: -4, dy: -4).contains(point),
          frameDistance(frame, from: quartzWindow.bounds) <= 24
        else {
          return nil
        }
        return (target, frame)
      }

    if let candidate = candidates.min(by: { lhs, rhs in
      frameDistance(lhs.frame, from: quartzWindow.bounds)
        < frameDistance(rhs.frame, from: quartzWindow.bounds)
    })?.target {
      return targetWithStableQuartzIdentity(candidate, quartzWindow: quartzWindow)
    }

    // WeChat 4.x can advertise its visible Window Server surface while
    // withholding a usable AX window for the same content. In that one known
    // case, retaining the stable Quartz window identity is sufficient to
    // activate the owning app without synthesizing any click.
    guard isKnownCustomRenderedApplication(processID: processID),
      hasOnlyOneVisibleContentWindow(processID: processID, windowID: quartzWindow.windowID)
    else {
      return nil
    }
    return WindowTarget(
      element: nil,
      processID: processID,
      id: quartzIdentity(processID: processID, windowID: quartzWindow.windowID)
    )
  }

  private struct QuartzWindowTarget {
    let windowID: CGWindowID
    let processID: pid_t
    let bounds: CGRect
  }

  private func hasOnlyOneVisibleContentWindow(processID: pid_t, windowID: CGWindowID) -> Bool {
    let windowIDs = quartzWindows().compactMap { info -> CGWindowID? in
      guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
        (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0.01,
        let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: dictionary),
        bounds.width >= 80, bounds.height >= 50,
        let number = info[kCGWindowNumber as String] as? NSNumber
      else { return nil }
      return number.uint32Value
    }
    // App activation alone cannot select one of several windows reliably.
    return windowIDs == [windowID]
  }

  private func topmostQuartzWindow(at point: CGPoint) -> QuartzWindowTarget? {
    guard let primaryScreen = NSScreen.screens.first else { return nil }
    // Quartz uses a top-left origin; AppKit's screen coordinates use bottom-left.
    // The primary screen's top edge is the shared reference, including for
    // displays positioned above or to the left of it.
    let appKitPoint = CGPoint(x: point.x, y: primaryScreen.frame.maxY - point.y)
    let number = NSWindow.windowNumber(at: appKitPoint, belowWindowWithWindowNumber: 0)
    guard number > 0, let windowID = CGWindowID(exactly: number) else { return nil }

    // This public AppKit hit test identifies the window that would receive a
    // mouseDown WITHOUT generating one. Bounds-only z-order scanning incorrectly
    // treats the Dock's full-screen, click-through surface as a blocking window.
    var info = quartzWindows().first {
      ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
    }
    if info == nil {
      quartzWindowCacheTime = -.infinity
      info = quartzWindows().first {
        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
      }
    }
    guard let info,
      let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: dictionary),
      let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
      let layer = info[kCGWindowLayer as String] as? NSNumber,
      let alpha = info[kCGWindowAlpha as String] as? NSNumber,
      layer.intValue == 0, alpha.doubleValue > 0.01,
      bounds.contains(point), bounds.width >= 80, bounds.height >= 50
    else { return nil }
    // Never look below a hit menu, Dock item, system overlay, or unknown window.
    return QuartzWindowTarget(
      windowID: windowID, processID: pid_t(ownerPID.int32Value), bounds: bounds)
  }

  private func targetWithStableQuartzIdentity(
    _ target: WindowTarget,
    quartzWindow: QuartzWindowTarget?
  ) -> WindowTarget {
    guard let quartzWindow,
      let activationProcessID = activationProcessID(forWindowOwner: quartzWindow.processID),
      activationProcessID == target.processID,
      let targetElement = target.element,
      let targetFrame = windowFrame(targetElement),
      frameDistance(targetFrame, from: quartzWindow.bounds) <= 24
    else {
      return target
    }

    // AXUIElement wrappers supplied by some custom-rendered applications are
    // not identity-stable across hit tests. A Window Server ID is stable for
    // the lifetime of the actual window, so the hover timer is not restarted
    // merely because WeChat returned a fresh AX wrapper.
    return WindowTarget(
      element: target.element,
      processID: target.processID,
      id: quartzIdentity(processID: target.processID, windowID: quartzWindow.windowID)
    )
  }

  private func quartzIdentity(processID: pid_t, windowID: CGWindowID) -> HoverWindowID {
    let quartzToken = UInt(windowID) | (UInt(1) << (UInt.bitWidth - 1))
    return HoverWindowID(processID: processID, accessibilityToken: quartzToken)
  }

  private func isKnownCustomRenderedApplication(processID: pid_t) -> Bool {
    guard
      let bundleIdentifier = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
    else {
      return false
    }
    return customRenderedBundleIdentifiers.contains(bundleIdentifier)
  }

  private func activationProcessID(forWindowOwner ownerProcessID: pid_t) -> pid_t? {
    if isEligibleApplication(processID: ownerProcessID) {
      return ownerProcessID
    }

    // A custom-rendered surface can be owned by a helper process. Map it back
    // to the outer regular application before asking Accessibility for its
    // top-level windows.
    guard let ownerApplication = NSRunningApplication(processIdentifier: ownerProcessID),
      let ownerExecutableURL = ownerApplication.executableURL
    else {
      return nil
    }

    return NSWorkspace.shared.runningApplications
      .filter { isEligibleApplication(processID: $0.processIdentifier) }
      .filter { application in
        guard let bundleURL = application.bundleURL else { return false }
        return ownerExecutableURL.path.hasPrefix(bundleURL.path + "/")
      }
      .max { lhs, rhs in
        (lhs.bundleURL?.path.count ?? 0) < (rhs.bundleURL?.path.count ?? 0)
      }?
      .processIdentifier
  }

  private func quartzWindows() -> [NSDictionary] {
    let now = ProcessInfo.processInfo.systemUptime
    if now - quartzWindowCacheTime > quartzWindowCacheDuration {
      quartzWindowCacheTime = now
      let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
      cachedQuartzWindows =
        CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [NSDictionary] ?? []
    }
    return cachedQuartzWindows
  }

  private func isEligibleApplication(processID: pid_t) -> Bool {
    guard processID > 0,
      processID != ProcessInfo.processInfo.processIdentifier,
      let application = NSRunningApplication(processIdentifier: processID),
      application.activationPolicy != .prohibited
    else {
      return false
    }

    if let bundleID = application.bundleIdentifier,
      excludedBundleIdentifiers.contains(bundleID)
    {
      return false
    }
    return true
  }

  private func windowFrame(_ element: AXUIElement) -> CGRect? {
    guard let position = pointAttribute(kAXPositionAttribute, of: element),
      let size = sizeAttribute(kAXSizeAttribute, of: element)
    else {
      return nil
    }
    return CGRect(origin: position, size: size)
  }

  private func frameDistance(_ lhs: CGRect, from rhs: CGRect) -> CGFloat {
    abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY) + abs(lhs.width - rhs.width)
      + abs(lhs.height - rhs.height)
  }

  func isFocused(_ target: WindowTarget) -> Bool {
    if let number = target.localWindowNumber {
      return NSApp.isActive && localSettingsWindow(number: number)?.isKeyWindow == true
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else {
      return false
    }

    guard let targetElement = target.element else {
      return true
    }

    let applicationElement = AXUIElementCreateApplication(target.processID)
    guard let focusedWindow = elementAttribute(kAXFocusedWindowAttribute, of: applicationElement)
    else {
      // If focus cannot be inspected, avoid repeatedly raising the
      // frontmost application's window.
      return true
    }
    return CFEqual(focusedWindow, targetElement)
  }

  @discardableResult
  func activate(_ target: WindowTarget) -> Bool {
    if let number = target.localWindowNumber {
      guard let window = localSettingsWindow(number: number) else { return false }
      let requestedActivation = NSRunningApplication.current.activate(options: [])
      window.makeKeyAndOrderFront(nil)
      // App activation completes on a later run-loop turn when we are in the
      // background; a successfully submitted request is not an immediate focus.
      return requestedActivation || window.isKeyWindow
    }
    guard let runningApplication = NSRunningApplication(processIdentifier: target.processID) else {
      return false
    }

    let applicationElement = AXUIElementCreateApplication(target.processID)

    if runningApplication.isHidden {
      runningApplication.unhide()
    }

    if let targetElement = target.element,
      isAttributeSettable(kAXMainAttribute, of: targetElement)
    {
      _ = AXUIElementSetAttributeValue(
        targetElement,
        kAXMainAttribute as CFString,
        kCFBooleanTrue
      )
    }

    let focused: Bool
    if let targetElement = target.element {
      focused =
        AXUIElementSetAttributeValue(
          applicationElement,
          kAXFocusedWindowAttribute as CFString,
          targetElement
        ) == .success
    } else {
      focused = false
    }
    let madeFrontmost =
      AXUIElementSetAttributeValue(
        applicationElement,
        kAXFrontmostAttribute as CFString,
        kCFBooleanTrue
      ) == .success
    let applicationActivated = runningApplication.activate(options: [])
    let raised: Bool
    if let targetElement = target.element {
      raised = AXUIElementPerformAction(targetElement, kAXRaiseAction as CFString) == .success
    } else {
      raised = false
    }

    return applicationActivated || madeFrontmost || raised || focused
  }

  private func elementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return (value as! AXUIElement)
  }

  private func elementArrayAttribute(_ attribute: String, of element: AXUIElement) -> [AXUIElement]
  {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
      let value,
      CFGetTypeID(value) == CFArrayGetTypeID()
    else {
      return []
    }
    return value as? [AXUIElement] ?? []
  }

  private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value as? String
  }

  private func boolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value as? Bool
  }

  private func pointAttribute(_ attribute: String, of element: AXUIElement) -> CGPoint? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
      let value,
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }

    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
  }

  private func sizeAttribute(_ attribute: String, of element: AXUIElement) -> CGSize? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
      let value,
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }

    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
  }

  private func isAttributeSettable(_ attribute: String, of element: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
    else {
      return false
    }
    return settable.boolValue
  }
}
