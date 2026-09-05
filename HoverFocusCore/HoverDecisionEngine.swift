import Foundation

/// A stable identity for a window during one hover decision.
public struct HoverWindowID: Hashable, Sendable {
  public let processID: Int32
  public let accessibilityToken: UInt

  public init(processID: Int32, accessibilityToken: UInt) {
    self.processID = processID
    self.accessibilityToken = accessibilityToken
  }
}

public enum HoverSchedulingDecision: Equatable, Sendable {
  case none
  case cancel
  case schedule(windowID: HoverWindowID, delay: TimeInterval)
}

public enum HoverTimerDecision: Equatable, Sendable {
  case cancel
  case reschedule(delay: TimeInterval)
  case activate(windowID: HoverWindowID)
}

/// Pure state machine for hover timing and activity protection.
///
/// It deliberately knows nothing about AppKit or Accessibility so its safety
/// rules can be tested without controlling real windows.
public struct HoverDecisionEngine: Sendable {
  public private(set) var dwellDuration: TimeInterval
  public private(set) var cooldownDuration: TimeInterval

  private var candidateWindowID: HoverWindowID?
  private var candidateStartedAt: TimeInterval?
  private var blockedUntil: TimeInterval = 0

  public init(dwellDuration: TimeInterval, cooldownDuration: TimeInterval = 0.5) {
    self.dwellDuration = max(0, dwellDuration)
    self.cooldownDuration = max(0, cooldownDuration)
  }

  /// Observes the window currently under the pointer. Movement inside the
  /// same window does not restart the dwell timer.
  public mutating func observe(
    windowID: HoverWindowID?,
    at time: TimeInterval
  ) -> HoverSchedulingDecision {
    guard time >= blockedUntil else {
      let hadCandidate = candidateWindowID != nil
      clearCandidate()
      return hadCandidate ? .cancel : .none
    }

    guard let windowID else {
      let hadCandidate = candidateWindowID != nil
      clearCandidate()
      return hadCandidate ? .cancel : .none
    }

    if candidateWindowID == windowID {
      return .none
    }

    candidateWindowID = windowID
    candidateStartedAt = time
    return .schedule(windowID: windowID, delay: dwellDuration)
  }

  /// Cancels any pending activation and requires a new mouse-move event once
  /// the protection interval has elapsed.
  @discardableResult
  public mutating func block(
    at time: TimeInterval,
    for duration: TimeInterval
  ) -> HoverSchedulingDecision {
    blockedUntil = max(blockedUntil, time + max(0, duration))
    clearCandidate()
    return .cancel
  }

  /// Revalidates a scheduled activation. Timers should not normally fire
  /// early, but returning a remaining delay makes that case deterministic.
  public mutating func timerFired(
    for windowID: HoverWindowID,
    at time: TimeInterval
  ) -> HoverTimerDecision {
    guard
      candidateWindowID == windowID,
      let candidateStartedAt
    else {
      return .cancel
    }

    guard time >= blockedUntil else {
      clearCandidate()
      return .cancel
    }

    let remaining = dwellDuration - (time - candidateStartedAt)
    if remaining > 0.001 {
      return .reschedule(delay: remaining)
    }

    clearCandidate()
    blockedUntil = time + cooldownDuration
    return .activate(windowID: windowID)
  }

  @discardableResult
  public mutating func updateDwellDuration(_ duration: TimeInterval) -> HoverSchedulingDecision {
    dwellDuration = max(0, duration)
    clearCandidate()
    return .cancel
  }

  @discardableResult
  public mutating func updateCooldownDuration(_ duration: TimeInterval) -> HoverSchedulingDecision {
    cooldownDuration = max(0, duration)
    clearCandidate()
    return .cancel
  }

  @discardableResult
  public mutating func reset() -> HoverSchedulingDecision {
    clearCandidate()
    return .cancel
  }

  private mutating func clearCandidate() {
    candidateWindowID = nil
    candidateStartedAt = nil
  }
}
