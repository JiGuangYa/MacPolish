import AppKit
import SwiftUI

/// Shared by the shipping app and its opt-in native window-flow verifier.
package struct MacPolishScenes: Scene {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var appSettings: AppSettings
    @ObservedObject private var sessionController: CleaningSessionController
    private let windowTitle: String

    package init(sessionController: CleaningSessionController, appSettings: AppSettings, windowTitle: String = L10n.string(.appTitle)) {
        self.sessionController = sessionController
        self.appSettings = appSettings
        self.windowTitle = windowTitle
    }

    package var body: some Scene {
        Window(windowTitle, id: AppWindowID.main) {
            MainView(
                sessionController: sessionController,
                appSettings: appSettings
            )
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                sessionController.refreshKeyboardProtectionAvailability(startPollingIfNeeded: true)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: WindowMetrics.defaultWidth, height: WindowMetrics.defaultHeight)
        .commands {
            AppCommands(sessionController: sessionController)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                sessionController.refreshKeyboardProtectionAvailability(startPollingIfNeeded: true)
            }
        }

        Settings {
            SettingsView(
                sessionController: sessionController,
                appSettings: appSettings
            )
        }
        .defaultSize(width: 560, height: 520)
        .windowResizability(.contentMinSize)

        MenuBarExtra(isInserted: Binding(
            get: { appSettings.showMenuBarItem || sessionController.isCleaning },
            set: { inserted in
                guard !sessionController.isCleaning, appSettings.showMenuBarItem != inserted else { return }
                appSettings.showMenuBarItem = inserted
            }
        )) {
            MenuBarContent(sessionController: sessionController)
        } label: {
            Image(systemName: sessionController.activeKeyboardProtection == .global ? "lock.fill" : "sparkles")
                .accessibilityLabel(Text(verbatim: L10n.string(.appTitle)))
        }
        .menuBarExtraStyle(.menu)
    }
}
