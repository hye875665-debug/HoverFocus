import XCTest

@testable import HoverFocusCore

final class HoverDecisionEngineTests: XCTestCase {
  private let firstWindow = HoverWindowID(processID: 101, accessibilityToken: 1)
  private let secondWindow = HoverWindowID(processID: 202, accessibilityToken: 2)

  func testStableWindowActivatesAfterDwellDuration() {
    var engine = HoverDecisionEngine(dwellDuration: 0.8)

    XCTAssertEqual(
      engine.observe(windowID: firstWindow, at: 10),
      .schedule(windowID: firstWindow, delay: 0.8)
    )
    XCTAssertEqual(engine.observe(windowID: firstWindow, at: 10.4), .none)
    XCTAssertEqual(engine.timerFired(for: firstWindow, at: 10.8), .activate(windowID: firstWindow))
  }

  func testMovingToAnotherWindowRestartsTimer() {
    var engine = HoverDecisionEngine(dwellDuration: 0.8)

    _ = engine.observe(windowID: firstWindow, at: 1)
    XCTAssertEqual(
      engine.observe(windowID: secondWindow, at: 1.5),
      .schedule(windowID: secondWindow, delay: 0.8)
    )
    XCTAssertEqual(engine.timerFired(for: firstWindow, at: 1.8), .cancel)
    XCTAssertEqual(engine.timerFired(for: secondWindow, at: 2.3), .activate(windowID: secondWindow))
  }

  func testLeavingEligibleWindowCancelsCandidate() {
    var engine = HoverDecisionEngine(dwellDuration: 0.8)

    _ = engine.observe(windowID: firstWindow, at: 5)
    XCTAssertEqual(engine.observe(windowID: nil, at: 5.2), .cancel)
    XCTAssertEqual(engine.timerFired(for: firstWindow, at: 5.8), .cancel)
  }

  func testBlockingActivityRequiresFreshMovement() {
    var engine = HoverDecisionEngine(dwellDuration: 0.8)

    _ = engine.observe(windowID: firstWindow, at: 20)
    XCTAssertEqual(engine.block(at: 20.4, for: 0.8), .cancel)
    XCTAssertEqual(engine.timerFired(for: firstWindow, at: 20.8), .cancel)
    XCTAssertEqual(engine.observe(windowID: firstWindow, at: 21), .none)
    XCTAssertEqual(
      engine.observe(windowID: firstWindow, at: 21.21),
      .schedule(windowID: firstWindow, delay: 0.8)
    )
  }

  func testCooldownPreventsImmediatePingPong() {
    var engine = HoverDecisionEngine(dwellDuration: 0.8, cooldownDuration: 0.5)

    _ = engine.observe(windowID: firstWindow, at: 1)
    XCTAssertEqual(engine.timerFired(for: firstWindow, at: 1.8), .activate(windowID: firstWindow))
    XCTAssertEqual(engine.observe(windowID: secondWindow, at: 2), .none)
    XCTAssertEqual(
      engine.observe(windowID: secondWindow, at: 2.31),
      .schedule(windowID: secondWindow, delay: 0.8)
    )
  }

  func testEarlyTimerIsRescheduledForRemainingDuration() {
    var engine = HoverDecisionEngine(dwellDuration: 0.8)

    _ = engine.observe(windowID: firstWindow, at: 100)
    guard case .reschedule(let delay) = engine.timerFired(for: firstWindow, at: 100.5) else {
      return XCTFail("Expected an early timer to be rescheduled")
    }
    XCTAssertEqual(delay, 0.3, accuracy: 0.000_001)
  }

  func testChangingDwellDurationCancelsPendingCandidate() {
    var engine = HoverDecisionEngine(dwellDuration: 0.8)

    _ = engine.observe(windowID: firstWindow, at: 1)
    XCTAssertEqual(engine.updateDwellDuration(1.2), .cancel)
    XCTAssertEqual(engine.timerFired(for: firstWindow, at: 2.2), .cancel)
    XCTAssertEqual(
      engine.observe(windowID: firstWindow, at: 3),
      .schedule(windowID: firstWindow, delay: 1.2)
    )
  }

  func testChangingCooldownDurationAppliesToNextActivation() {
    var engine = HoverDecisionEngine(dwellDuration: 0.8, cooldownDuration: 0.5)

    _ = engine.observe(windowID: firstWindow, at: 1)
    XCTAssertEqual(engine.updateCooldownDuration(1.2), .cancel)
    _ = engine.observe(windowID: firstWindow, at: 2)
    XCTAssertEqual(engine.timerFired(for: firstWindow, at: 2.8), .activate(windowID: firstWindow))
    XCTAssertEqual(engine.observe(windowID: secondWindow, at: 3.5), .none)
    XCTAssertEqual(
      engine.observe(windowID: secondWindow, at: 4.01),
      .schedule(windowID: secondWindow, delay: 0.8)
    )
  }
}
