import AppKit
import ApplicationServices
import HoverFocusCore

@MainActor
final class HoverActivationController: @unchecked Sendable {
  var onPermissionChanged: ((Bool) -> Void)?
  var onMonitoringError: ((String) -> Void)?

  private let resolver: WindowResolving
  private let inputMonitor: GlobalInputMonitor
  private var decisionEngine: HoverDecisionEngine
  private var activationWorkItem: DispatchWorkItem?

  private var isStarted = false
  private var isEnabled: Bool
  private var protectDuringScrolling: Bool
  private var protectDuringTyping: Bool
  private var lastResolvedAt: TimeInterval = -.infinity
  private var lastPermissionCheckAt: TimeInterval = -.infinity
  private var cachedPermission = AXIsProcessTrusted()

  private let minimumResolveInterval: TimeInterval = 1.0 / 30.0
  private let mouseButtonProtection: TimeInterval = 0.3
  private let scrollProtection: TimeInterval = 0.5
  private let keyboardProtection: TimeInterval = 0.8
  private let permissionCheckInterval: TimeInterval = 1.0

  init(
    dwellDuration: TimeInterval,
    isEnabled: Bool,
    cooldownDuration: TimeInterval = 0.5,
    protectDuringScrolling: Bool = true,
    protectDuringTyping: Bool = true,
    resolver: WindowResolving = AccessibilityWindowResolver(),
    inputMonitor: GlobalInputMonitor = GlobalInputMonitor()
  ) {
    self.resolver = resolver
    self.inputMonitor = inputMonitor
    self.decisionEngine = HoverDecisionEngine(
      dwellDuration: dwellDuration,
      cooldownDuration: cooldownDuration
    )
    self.isEnabled = isEnabled
    self.protectDuringScrolling = protectDuringScrolling
    self.protectDuringTyping = protectDuringTyping
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    refreshPermission(force: true)
    if isEnabled {
      startMonitoring()
    }
  }

  func stop() {
    cancelScheduledActivation()
    inputMonitor.stop()
    _ = decisionEngine.reset()
    isStarted = false
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    cancelScheduledActivation()
    _ = decisionEngine.reset()

    guard isStarted else { return }
    if enabled {
      refreshPermission(force: true)
      startMonitoring()
    } else {
      inputMonitor.stop()
    }
  }

  func setDwellDuration(_ duration: TimeInterval) {
    cancelScheduledActivation()
    _ = decisionEngine.updateDwellDuration(duration)
  }

  func setCooldownDuration(_ duration: TimeInterval) {
    cancelScheduledActivation()
    _ = decisionEngine.updateCooldownDuration(duration)
  }

  func setProtectDuringScrolling(_ enabled: Bool) {
    protectDuringScrolling = enabled
    cancelCandidate()
  }

  func setProtectDuringTyping(_ enabled: Bool) {
    protectDuringTyping = enabled
    cancelCandidate()
  }

  @discardableResult
  func refreshPermission(force: Bool = false) -> Bool {
    let now = ProcessInfo.processInfo.systemUptime
    if force || now - lastPermissionCheckAt >= permissionCheckInterval {
      lastPermissionCheckAt = now
      let currentPermission = AXIsProcessTrusted()
      if currentPermission != cachedPermission {
        cachedPermission = currentPermission
        onPermissionChanged?(currentPermission)
      } else if force {
        onPermissionChanged?(currentPermission)
      }
    }
    return cachedPermission
  }

  private func startMonitoring() {
    let started = inputMonitor.start { [weak self] event in
      self?.handle(event)
    }
    if !started {
      onMonitoringError?("无法监听鼠标移动。请重新启动应用并检查辅助功能权限。")
    }
  }

  private func handle(_ event: ObservedInputEvent) {
    guard isEnabled else { return }

    switch event {
    case .mouseMoved(let position, let timestamp):
      handleMouseMoved(at: position.cgPoint, timestamp: timestamp)
    case .mouseButtonActivity(let timestamp), .mouseDragged(let timestamp):
      block(at: timestamp, duration: mouseButtonProtection)
    case .scroll(let timestamp):
      if protectDuringScrolling {
        block(at: timestamp, duration: scrollProtection)
      }
    case .keyboardActivity(let timestamp):
      if protectDuringTyping {
        block(at: timestamp, duration: keyboardProtection)
      }
    }
  }

  private func handleMouseMoved(at point: CGPoint, timestamp: TimeInterval) {
    guard NSEvent.pressedMouseButtons == 0 else {
      block(at: timestamp, duration: mouseButtonProtection)
      return
    }

    guard refreshPermission() else {
      cancelCandidate()
      return
    }

    if timestamp >= lastResolvedAt,
      timestamp - lastResolvedAt < minimumResolveInterval
    {
      return
    }
    lastResolvedAt = timestamp

    let target = resolver.target(at: point)
    let eligibleTarget = target.flatMap { resolver.isFocused($0) ? nil : $0 }
    let decision = decisionEngine.observe(windowID: eligibleTarget?.id, at: timestamp)

    switch decision {
    case .none:
      break
    case .cancel:
      cancelScheduledActivation()
    case .schedule(let windowID, let delay):
      guard let eligibleTarget else {
        cancelScheduledActivation()
        return
      }
      scheduleActivation(for: eligibleTarget, expectedID: windowID, after: delay)
    }
  }

  private func block(at timestamp: TimeInterval, duration: TimeInterval) {
    cancelScheduledActivation()
    _ = decisionEngine.block(at: timestamp, for: duration)
  }

  private func cancelCandidate() {
    cancelScheduledActivation()
    _ = decisionEngine.reset()
  }

  private func scheduleActivation(
    for target: WindowTarget,
    expectedID: HoverWindowID,
    after delay: TimeInterval
  ) {
    cancelScheduledActivation()

    let workItem = DispatchWorkItem { [weak self] in
      self?.scheduledActivationFired(for: target, expectedID: expectedID)
    }
    activationWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func scheduledActivationFired(
    for target: WindowTarget,
    expectedID: HoverWindowID
  ) {
    activationWorkItem = nil
    guard isEnabled, refreshPermission(force: true) else {
      cancelCandidate()
      return
    }

    let now = ProcessInfo.processInfo.systemUptime
    switch decisionEngine.timerFired(for: expectedID, at: now) {
    case .cancel:
      return
    case .reschedule(let delay):
      scheduleActivation(for: target, expectedID: expectedID, after: delay)
    case .activate:
      guard NSEvent.pressedMouseButtons == 0,
        let currentPoint = CGEvent(source: nil)?.location,
        let currentTarget = resolver.target(at: currentPoint),
        target.representsSameWindow(as: currentTarget),
        !resolver.isFocused(currentTarget)
      else {
        return
      }
      _ = resolver.activate(currentTarget)
    }
  }

  private func cancelScheduledActivation() {
    activationWorkItem?.cancel()
    activationWorkItem = nil
  }
}
