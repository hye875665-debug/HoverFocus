import AppKit
import SwiftUI

@main
struct HoverFocusApp: App {
  @NSApplicationDelegateAdaptor(HoverFocusAppDelegate.self) private var appDelegate
  @StateObject private var appState = AppState.shared

  var body: some Scene {
    MenuBarExtra {
      HoverFocusMenuView()
        .environmentObject(appState)
    } label: {
      Image(systemName: appState.menuBarIconName)
        .accessibilityLabel("悬停聚焦：\(appState.status.label)")
    }
    .menuBarExtraStyle(.window)

    Window("悬停聚焦设置", id: "settings") {
      HoverFocusSettingsView()
        .environmentObject(appState)
    }
    .defaultSize(width: 720, height: 520)
    .windowResizability(.contentMinSize)
  }
}

@MainActor
final class HoverFocusAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    AppState.shared.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    AppState.shared.stop()
  }
}
