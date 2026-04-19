import SwiftUI

public struct AppCommands: Commands {
    @ObservedObject private var sessionController: CleaningSessionController

    public init(sessionController: CleaningSessionController) {
        _sessionController = ObservedObject(wrappedValue: sessionController)
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) { }

        CommandMenu(L10n.string(.menuCleaning)) {
            Button(L10n.string(.menuStartWholeMac)) {
                sessionController.startCleaning(mode: .wholeMac)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(sessionController.isCleaning)

            Button(L10n.string(.menuStartScreenOnly)) {
                sessionController.startCleaning(mode: .screenOnly)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(sessionController.isCleaning)

            Button(L10n.string(.menuStartKeyboardOnly)) {
                sessionController.startCleaning(mode: .keyboardOnly)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(sessionController.isCleaning || sessionController.keyboardPermissionState != .granted)

            Divider()

            if sessionController.keyboardPermissionState == .notDetermined {
                Button(L10n.string(.menuRequestKeyboardAccess)) {
                    sessionController.requestKeyboardPermission()
                }
            }

            if sessionController.keyboardPermissionState == .denied {
                Button(L10n.string(.menuOpenKeyboardSettings)) {
                    sessionController.openKeyboardPermissionSettings()
                }
            }

            if sessionController.keyboardPermissionState != .granted {
                Divider()
            }

            Button(L10n.string(.menuExitCleaning)) {
                sessionController.stopCleaning(trigger: .menuCommand)
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!sessionController.isCleaning)
        }
    }
}
