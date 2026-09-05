import Carbon

final class GlobalHotKeyManager: @unchecked Sendable {
  private let handler: @Sendable () -> Void
  private var hotKeyReference: EventHotKeyRef?
  private var eventHandlerReference: EventHandlerRef?

  init(handler: @escaping @Sendable () -> Void) {
    self.handler = handler
  }

  @discardableResult
  func start() -> Bool {
    stop()

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let userData = Unmanaged.passUnretained(self).toOpaque()
    let installStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      hoverFocusHotKeyEventHandler,
      1,
      &eventType,
      userData,
      &eventHandlerReference
    )
    guard installStatus == noErr else { return false }

    let hotKeyID = EventHotKeyID(
      signature: OSType(0x484F_5646),  // "HOVF"
      id: 1
    )
    let modifiers = UInt32(controlKey | optionKey | cmdKey)
    let registerStatus = RegisterEventHotKey(
      UInt32(kVK_ANSI_H),
      modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyReference
    )

    guard registerStatus == noErr else {
      if let eventHandlerReference {
        RemoveEventHandler(eventHandlerReference)
        self.eventHandlerReference = nil
      }
      return false
    }
    return true
  }

  func stop() {
    if let hotKeyReference {
      UnregisterEventHotKey(hotKeyReference)
      self.hotKeyReference = nil
    }
    if let eventHandlerReference {
      RemoveEventHandler(eventHandlerReference)
      self.eventHandlerReference = nil
    }
  }

  fileprivate func invoke() {
    handler()
  }

  deinit {
    stop()
  }
}

private func hoverFocusHotKeyEventHandler(
  _ nextHandler: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let userData else { return OSStatus(eventNotHandledErr) }
  let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
  manager.invoke()
  return noErr
}
