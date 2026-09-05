import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
  case general
  case behavior
  case appearance

  var id: String { rawValue }

  var label: String {
    switch self {
    case .general: "通用"
    case .behavior: "行为"
    case .appearance: "外观"
    }
  }

  var symbolName: String {
    switch self {
    case .general: "switch.2"
    case .behavior: "cursorarrow.motionlines"
    case .appearance: "paintbrush"
    }
  }
}

struct HoverFocusSettingsView: View {
  @EnvironmentObject private var appState: AppState
  @State private var selection: SettingsSection? = .general

  var body: some View {
    NavigationSplitView {
      List(SettingsSection.allCases, selection: $selection) { section in
        Label(section.label, systemImage: section.symbolName)
          .tag(section)
      }
      .navigationTitle("设置")
      .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 210)
    } detail: {
      ScrollView {
        Group {
          switch selection ?? .general {
          case .general:
            GeneralSettingsView()
          case .behavior:
            BehaviorSettingsView()
          case .appearance:
            AppearanceSettingsView()
          }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 650, minHeight: 470)
    .background(SettingsWindowRegistration())
  }
}

// Register only the full settings window. MenuBarExtra's panel must remain
// excluded even though it belongs to the same process.
private struct SettingsWindowRegistration: NSViewRepresentable {
  func makeNSView(context: Context) -> RegistrationView { RegistrationView() }
  func updateNSView(_ nsView: RegistrationView, context: Context) {}

  final class RegistrationView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.identifier = AccessibilityWindowResolver.settingsWindowIdentifier
      window?.acceptsMouseMovedEvents = true
    }
  }
}

private struct GeneralSettingsView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    SettingsPage(
      title: "通用",
      subtitle: "控制运行状态、启动方式与系统权限。"
    ) {
      SettingsCard {
        HStack(spacing: 14) {
          Image(systemName: appState.menuBarIconName)
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(statusColor)
            .frame(width: 42)

          VStack(alignment: .leading, spacing: 3) {
            Text("悬停聚焦")
              .font(.headline)
            Text(appState.status.label)
              .foregroundStyle(.secondary)
          }

          Spacer()

          Toggle(
            "",
            isOn: Binding(
              get: { appState.isEnabled },
              set: { appState.setEnabled($0) }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.large)
        }
      }

      SettingsCard {
        Toggle(
          "登录时自动启动",
          isOn: Binding(
            get: { appState.launchAtLogin },
            set: { appState.setLaunchAtLogin($0) }
          )
        )

        Divider()

        LabeledContent("暂停或恢复") {
          Text(AppState.hotKeyDescription)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
        }

        if !appState.isHotKeyAvailable {
          Text("快捷键已被其他应用占用。")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }

      SettingsCard {
        HStack {
          Label(
            appState.isAccessibilityTrusted ? "辅助功能权限已授予" : "需要辅助功能权限",
            systemImage: appState.isAccessibilityTrusted
              ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
          )
          .foregroundStyle(appState.isAccessibilityTrusted ? .green : .orange)

          Spacer()

          Button(appState.isAccessibilityTrusted ? "重新检查" : "打开系统设置") {
            if appState.isAccessibilityTrusted {
              appState.refreshAccessibilityPermission()
            } else {
              appState.requestAccessibilityPermission()
              appState.openAccessibilitySettings()
            }
          }
        }
      }
    }
  }

  private var statusColor: Color {
    switch appState.status {
    case .running: .green
    case .paused: .secondary
    case .permissionRequired: .orange
    }
  }
}

private struct BehaviorSettingsView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    SettingsPage(
      title: "行为",
      subtitle: "调整触发速度，并控制容易误切换的场景。"
    ) {
      SettingsCard {
        settingHeader(
          "悬停时间",
          value: formattedDuration(appState.dwellMilliseconds),
          description: "鼠标在同一窗口中持续停留多久后切换焦点。"
        )

        Slider(
          value: Binding(
            get: { Double(appState.dwellMilliseconds) },
            set: { appState.setDwellMilliseconds(Int($0.rounded())) }
          ),
          in: Double(
            AppState.dwellMillisecondsRange.lowerBound)...Double(
              AppState.dwellMillisecondsRange.upperBound),
          step: 50
        )

        HStack {
          Text("更灵敏")
          Spacer()
          Text("更稳妥")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      SettingsCard {
        settingHeader(
          "切换冷却",
          value: formattedDuration(appState.cooldownMilliseconds),
          description: "切换窗口后暂时停止触发，防止焦点来回跳动。"
        )

        Slider(
          value: Binding(
            get: { Double(appState.cooldownMilliseconds) },
            set: { appState.setCooldownMilliseconds(Int($0.rounded())) }
          ),
          in: Double(
            AppState.cooldownMillisecondsRange.lowerBound)...Double(
              AppState.cooldownMillisecondsRange.upperBound),
          step: 50
        )
      }

      SettingsCard {
        Toggle(
          "滚动网页或文档时暂停切换",
          isOn: Binding(
            get: { appState.protectDuringScrolling },
            set: { appState.setProtectDuringScrolling($0) }
          )
        )

        Divider()

        Toggle(
          "键盘输入时暂停切换",
          isOn: Binding(
            get: { appState.protectDuringTyping },
            set: { appState.setProtectDuringTyping($0) }
          )
        )

        Text("拖动窗口、拖选文字和按住鼠标时始终暂停，以避免误操作。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func settingHeader(
    _ title: String,
    value: String,
    description: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title)
          .font(.headline)
        Spacer()
        Text(value)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct AppearanceSettingsView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    SettingsPage(
      title: "外观",
      subtitle: "选择最适合菜单栏的图标样式。"
    ) {
      SettingsCard {
        Text("菜单栏图标")
          .font(.headline)

        HStack(spacing: 10) {
          ForEach(MenuBarIconStyle.allCases) { style in
            Button {
              appState.setMenuBarIconStyle(style)
            } label: {
              VStack(spacing: 9) {
                Image(systemName: style.symbolName)
                  .font(.system(size: 23, weight: .medium))
                  .frame(height: 26)
                Text(style.label)
                  .font(.caption)
              }
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
              .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                  .fill(
                    appState.menuBarIconStyle == style
                      ? Color.accentColor.opacity(0.14) : Color.clear
                  )
              )
              .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                  .stroke(
                    appState.menuBarIconStyle == style
                      ? Color.accentColor : Color.secondary.opacity(0.2),
                    lineWidth: appState.menuBarIconStyle == style ? 1.5 : 1
                  )
              }
            }
            .buttonStyle(.plain)
          }
        }
      }

      SettingsCard {
        HStack(spacing: 15) {
          ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(Color.accentColor.gradient)
            Image(systemName: appState.menuBarIconStyle.symbolName)
              .font(.system(size: 31, weight: .semibold))
              .foregroundStyle(.white)
          }
          .frame(width: 64, height: 64)

          VStack(alignment: .leading, spacing: 5) {
            Text("应用图标")
              .font(.headline)
            Text("菜单栏图标已经可以自定义。用于 Finder 和 GitHub 的完整应用图标将在下一轮单独设计。")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }
}

private struct SettingsPage<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: Content

  init(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 5) {
        Text(title)
          .font(.system(size: 26, weight: .bold))
        Text(subtitle)
          .foregroundStyle(.secondary)
      }

      content
    }
    .frame(maxWidth: 560, alignment: .leading)
  }
}

private struct SettingsCard<Content: View>: View {
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
    }
  }
}
