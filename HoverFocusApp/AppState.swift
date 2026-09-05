import AppKit
import ApplicationServices
import ServiceManagement

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
  case cursor
  case target
  case eye
  case window

  var id: String { rawValue }

  var label: String {
    switch self {
    case .cursor: "光标"
    case .target: "焦点"
    case .eye: "注视"
    case .window: "窗口"
    }
  }

  var symbolName: String {
    switch self {
    case .cursor: "cursorarrow.rays"
    case .target: "scope"
    case .eye: "eye"
    case .window: "macwindow"
    }
  }
}

enum HoverFocusStatus: Equatable {
  case running
  case paused
  case permissionRequired

  var iconName: String {
    switch self {
    case .running: "cursorarrow.rays"
    case .paused: "pause.circle"
    case .permissionRequired: "exclamationmark.triangle"
    }
  }

  var label: String {
    switch self {
    case .running: "运行中"
    case .paused: "已暂停"
    case .permissionRequired: "需要辅助功能权限"
    }
  }
}

@MainActor
final class AppState: ObservableObject {
  static let shared = AppState()

  static let supportedDwellMilliseconds = [300, 500, 800, 1_200, 1_500]
  static let dwellMillisecondsRange = 200...2_000
  static let cooldownMillisecondsRange = 0...1_500
  static let hotKeyDescription = "⌃⌥⌘H"

  @Published private(set) var isEnabled: Bool
  @Published private(set) var dwellMilliseconds: Int
  @Published private(set) var cooldownMilliseconds: Int
  @Published private(set) var protectDuringScrolling: Bool
  @Published private(set) var protectDuringTyping: Bool
  @Published private(set) var menuBarIconStyle: MenuBarIconStyle
  @Published private(set) var launchAtLogin: Bool
  @Published private(set) var isAccessibilityTrusted: Bool
  @Published private(set) var isHotKeyAvailable = true
  @Published private(set) var lastErrorMessage: String?

  var status: HoverFocusStatus {
    if !isAccessibilityTrusted { return .permissionRequired }
    return isEnabled ? .running : .paused
  }

  var menuBarIconName: String {
    switch status {
    case .running: menuBarIconStyle.symbolName
    case .paused: HoverFocusStatus.paused.iconName
    case .permissionRequired: HoverFocusStatus.permissionRequired.iconName
    }
  }

  private enum DefaultsKey {
    static let isEnabled = "HoverFocus.isEnabled"
    static let dwellMilliseconds = "HoverFocus.dwellMilliseconds"
    static let cooldownMilliseconds = "HoverFocus.cooldownMilliseconds"
    static let protectDuringScrolling = "HoverFocus.protectDuringScrolling"
    static let protectDuringTyping = "HoverFocus.protectDuringTyping"
    static let menuBarIconStyle = "HoverFocus.menuBarIconStyle"
    static let launchAtLogin = "HoverFocus.launchAtLogin"
    static let hasShownPermissionExplanation = "HoverFocus.hasShownPermissionExplanation"
  }

  private let defaults: UserDefaults
  private var activationController: HoverActivationController?
  private var hotKeyManager: GlobalHotKeyManager?
  private var hasStarted = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.isEnabled = defaults.object(forKey: DefaultsKey.isEnabled) as? Bool ?? true

    let storedDwell = defaults.object(forKey: DefaultsKey.dwellMilliseconds) as? Int ?? 800
    self.dwellMilliseconds = min(
      max(storedDwell, Self.dwellMillisecondsRange.lowerBound),
      Self.dwellMillisecondsRange.upperBound
    )

    let storedCooldown = defaults.object(forKey: DefaultsKey.cooldownMilliseconds) as? Int ?? 500
    self.cooldownMilliseconds = min(
      max(storedCooldown, Self.cooldownMillisecondsRange.lowerBound),
      Self.cooldownMillisecondsRange.upperBound
    )
    self.protectDuringScrolling =
      defaults.object(forKey: DefaultsKey.protectDuringScrolling) as? Bool ?? true
    self.protectDuringTyping =
      defaults.object(forKey: DefaultsKey.protectDuringTyping) as? Bool ?? true
    self.menuBarIconStyle =
      defaults.string(forKey: DefaultsKey.menuBarIconStyle).flatMap(
        MenuBarIconStyle.init(rawValue:))
      ?? .cursor

    let loginStatus = SMAppService.mainApp.status
    self.launchAtLogin = loginStatus == .enabled || loginStatus == .requiresApproval
    self.isAccessibilityTrusted = AXIsProcessTrusted()
  }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    NSApp.setActivationPolicy(.accessory)

    let controller = HoverActivationController(
      dwellDuration: TimeInterval(dwellMilliseconds) / 1_000,
      isEnabled: isEnabled,
      cooldownDuration: TimeInterval(cooldownMilliseconds) / 1_000,
      protectDuringScrolling: protectDuringScrolling,
      protectDuringTyping: protectDuringTyping
    )
    controller.onPermissionChanged = { [weak self] trusted in
      self?.isAccessibilityTrusted = trusted
    }
    controller.onMonitoringError = { [weak self] message in
      self?.lastErrorMessage = message
    }
    activationController = controller
    controller.start()

    let hotKeyManager = GlobalHotKeyManager { [weak self] in
      Task { @MainActor [weak self] in
        self?.toggleEnabled()
      }
    }
    self.hotKeyManager = hotKeyManager
    isHotKeyAvailable = hotKeyManager.start()
    if !isHotKeyAvailable {
      lastErrorMessage = "全局快捷键 \(Self.hotKeyDescription) 已被其他应用占用。菜单栏开关仍可使用。"
    }

    showFirstLaunchExplanationIfNeeded()
  }

  func stop() {
    activationController?.stop()
    hotKeyManager?.stop()
  }

  func toggleEnabled() {
    setEnabled(!isEnabled)
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    defaults.set(enabled, forKey: DefaultsKey.isEnabled)
    activationController?.setEnabled(enabled)
    if enabled {
      refreshAccessibilityPermission()
    }
  }

  func setDwellMilliseconds(_ milliseconds: Int) {
    let clamped = min(
      max(milliseconds, Self.dwellMillisecondsRange.lowerBound),
      Self.dwellMillisecondsRange.upperBound
    )
    dwellMilliseconds = clamped
    defaults.set(clamped, forKey: DefaultsKey.dwellMilliseconds)
    activationController?.setDwellDuration(TimeInterval(clamped) / 1_000)
  }

  func setCooldownMilliseconds(_ milliseconds: Int) {
    let clamped = min(
      max(milliseconds, Self.cooldownMillisecondsRange.lowerBound),
      Self.cooldownMillisecondsRange.upperBound
    )
    cooldownMilliseconds = clamped
    defaults.set(clamped, forKey: DefaultsKey.cooldownMilliseconds)
    activationController?.setCooldownDuration(TimeInterval(clamped) / 1_000)
  }

  func setProtectDuringScrolling(_ enabled: Bool) {
    protectDuringScrolling = enabled
    defaults.set(enabled, forKey: DefaultsKey.protectDuringScrolling)
    activationController?.setProtectDuringScrolling(enabled)
  }

  func setProtectDuringTyping(_ enabled: Bool) {
    protectDuringTyping = enabled
    defaults.set(enabled, forKey: DefaultsKey.protectDuringTyping)
    activationController?.setProtectDuringTyping(enabled)
  }

  func setMenuBarIconStyle(_ style: MenuBarIconStyle) {
    menuBarIconStyle = style
    defaults.set(style.rawValue, forKey: DefaultsKey.menuBarIconStyle)
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    lastErrorMessage = nil
    do {
      let service = SMAppService.mainApp
      if enabled {
        if service.status == .notRegistered {
          try service.register()
        }
      } else if service.status != .notRegistered {
        try service.unregister()
      }

      let currentStatus = service.status
      launchAtLogin = currentStatus == .enabled || currentStatus == .requiresApproval
      defaults.set(launchAtLogin, forKey: DefaultsKey.launchAtLogin)
      if currentStatus == .requiresApproval {
        lastErrorMessage = "登录启动等待系统批准，请在“系统设置 → 通用 → 登录项”中允许悬停聚焦。"
      }
    } catch {
      let service = SMAppService.mainApp
      launchAtLogin = service.status == .enabled || service.status == .requiresApproval
      defaults.set(launchAtLogin, forKey: DefaultsKey.launchAtLogin)
      lastErrorMessage = "无法更改登录启动设置：\(error.localizedDescription)"
    }
  }

  func refreshAccessibilityPermission() {
    if let activationController {
      isAccessibilityTrusted = activationController.refreshPermission(force: true)
    } else {
      isAccessibilityTrusted = AXIsProcessTrusted()
    }
  }

  func requestAccessibilityPermission() {
    // The exported Core Foundation variable is not annotated for Swift 6
    // concurrency. Its documented string value is safe to use directly.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    activationController?.refreshPermission(force: true)
  }

  func openAccessibilitySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  func quit() {
    NSApp.terminate(nil)
  }

  private func showFirstLaunchExplanationIfNeeded() {
    guard !isAccessibilityTrusted,
      !defaults.bool(forKey: DefaultsKey.hasShownPermissionExplanation)
    else {
      return
    }

    defaults.set(true, forKey: DefaultsKey.hasShownPermissionExplanation)
    NSRunningApplication.current.activate(options: [])

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "悬停聚焦需要辅助功能权限"
    alert.informativeText = "此权限只用于识别并置前鼠标停留的窗口。应用不会模拟点击、读取网页或文档内容，也不会申请截屏权限。"
    alert.addButton(withTitle: "继续授权")
    alert.addButton(withTitle: "稍后")

    if alert.runModal() == .alertFirstButtonReturn {
      requestAccessibilityPermission()
    }
  }
}
