import AppKit
import SwiftUI

struct HoverFocusMenuView: View {
  @Environment(\.openWindow) private var openWindow
  @EnvironmentObject private var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      Divider()

      Toggle(
        "启用悬停聚焦",
        isOn: Binding(
          get: { appState.isEnabled },
          set: { appState.setEnabled($0) }
        )
      )
      .toggleStyle(.switch)
      .controlSize(.large)

      HStack {
        Label("停留时间", systemImage: "timer")
        Spacer()
        Picker(
          "停留时间",
          selection: Binding(
            get: { appState.dwellMilliseconds },
            set: { appState.setDwellMilliseconds($0) }
          )
        ) {
          ForEach(AppState.supportedDwellMilliseconds, id: \.self) { milliseconds in
            Text(formattedDuration(milliseconds)).tag(milliseconds)
          }
          if !AppState.supportedDwellMilliseconds.contains(appState.dwellMilliseconds) {
            Text(formattedDuration(appState.dwellMilliseconds)).tag(appState.dwellMilliseconds)
          }
        }
        .labelsHidden()
        .frame(width: 112)
      }

      permissionRow

      Text("快捷键：\(AppState.hotKeyDescription)")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let message = appState.lastErrorMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()

      HStack(spacing: 8) {
        Button {
          NSRunningApplication.current.activate(options: [])
          openWindow(id: "settings")
        } label: {
          Label("设置", systemImage: "gearshape")
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)

        Button {
          appState.quit()
        } label: {
          Image(systemName: "power")
        }
        .help("退出悬停聚焦")
        .controlSize(.large)
      }
    }
    .padding(16)
    .frame(width: 320)
    .onAppear(perform: appState.refreshAccessibilityPermission)
  }

  private var header: some View {
    HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(statusColor.opacity(0.14))
        Image(systemName: appState.menuBarIconStyle.symbolName)
          .font(.system(size: 21, weight: .semibold))
          .foregroundStyle(statusColor)
      }
      .frame(width: 44, height: 44)

      VStack(alignment: .leading, spacing: 3) {
        Text("悬停聚焦")
          .font(.headline)
        HStack(spacing: 5) {
          Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
          Text(appState.status.label)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()
    }
  }

  @ViewBuilder
  private var permissionRow: some View {
    if appState.isAccessibilityTrusted {
      Label("辅助功能权限已授予", systemImage: "checkmark.shield")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else {
      Button {
        appState.requestAccessibilityPermission()
        appState.openAccessibilitySettings()
      } label: {
        Label("需要辅助功能权限", systemImage: "exclamationmark.shield")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.borderedProminent)
      .tint(.orange)
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

func formattedDuration(_ milliseconds: Int) -> String {
  if milliseconds >= 1_000 {
    let seconds = Double(milliseconds) / 1_000
    return seconds.rounded() == seconds
      ? "\(Int(seconds)) 秒"
      : String(format: "%.1f 秒", seconds)
  }
  return "\(milliseconds) 毫秒"
}
