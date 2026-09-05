import AppKit

struct PointerPosition: Sendable {
  let x: Double
  let y: Double

  var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

enum ObservedInputEvent: Sendable {
  case mouseMoved(position: PointerPosition, timestamp: TimeInterval)
  case mouseButtonActivity(timestamp: TimeInterval)
  case mouseDragged(timestamp: TimeInterval)
  case scroll(timestamp: TimeInterval)
  case keyboardActivity(timestamp: TimeInterval)
}

@MainActor
final class GlobalInputMonitor: @unchecked Sendable {
  private var monitorTokens: [Any] = []

  @discardableResult
  func start(
    handler: @escaping @MainActor @Sendable (ObservedInputEvent) -> Void
  ) -> Bool {
    stop()

    let pointerMask: NSEvent.EventTypeMask = [
      .mouseMoved,
      .leftMouseDown,
      .leftMouseUp,
      .rightMouseDown,
      .rightMouseUp,
      .otherMouseDown,
      .otherMouseUp,
      .leftMouseDragged,
      .rightMouseDragged,
      .otherMouseDragged,
      .scrollWheel,
    ]

    let pointerToken = NSEvent.addGlobalMonitorForEvents(
      matching: pointerMask,
      handler: { event in
        guard let observedEvent = Self.snapshot(event) else { return }
        Task { @MainActor in
          handler(observedEvent)
        }
      })
    if let pointerToken {
      monitorTokens.append(pointerToken)
    }

    let keyboardMask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
    let keyboardToken = NSEvent.addGlobalMonitorForEvents(
      matching: keyboardMask,
      handler: { event in
        let observedEvent = ObservedInputEvent.keyboardActivity(timestamp: event.timestamp)
        Task { @MainActor in
          handler(observedEvent)
        }
      })
    if let keyboardToken {
      monitorTokens.append(keyboardToken)
    }

    // Global monitors omit events delivered to this process. Observe local
    // events too, especially input protection while editing our settings.
    // Always return the original event so controls and text input work normally.
    let localToken = NSEvent.addLocalMonitorForEvents(
      matching: pointerMask.union(keyboardMask),
      handler: { event in
        if let observedEvent = Self.snapshot(event) {
          MainActor.assumeIsolated {
            handler(observedEvent)
          }
        }
        return event
      })
    if let localToken {
      monitorTokens.append(localToken)
    }

    return pointerToken != nil && localToken != nil
  }

  func stop() {
    monitorTokens.forEach(NSEvent.removeMonitor)
    monitorTokens.removeAll()
  }

  private nonisolated static func snapshot(_ event: NSEvent) -> ObservedInputEvent? {
    switch event.type {
    case .mouseMoved:
      guard let point = event.cgEvent?.location else { return nil }
      return .mouseMoved(
        position: PointerPosition(x: point.x, y: point.y),
        timestamp: event.timestamp
      )
    case .leftMouseDown, .leftMouseUp,
      .rightMouseDown, .rightMouseUp,
      .otherMouseDown, .otherMouseUp:
      return .mouseButtonActivity(timestamp: event.timestamp)
    case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      return .mouseDragged(timestamp: event.timestamp)
    case .scrollWheel:
      return .scroll(timestamp: event.timestamp)
    case .keyDown, .flagsChanged:
      return .keyboardActivity(timestamp: event.timestamp)
    default:
      return nil
    }
  }
}
