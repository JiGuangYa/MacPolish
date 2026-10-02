import SwiftUI

public struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var sessionController: CleaningSessionController

    public init(sessionController: CleaningSessionController) {
        _sessionController = ObservedObject(wrappedValue: sessionController)
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) { }

        CommandMenu(L10n.string(.menuCleaning)) {
            Button(L10n.string(.menuStartWholeMac)) {
                sessionController.performPrimaryActionFromMenu(for: .wholeMac) {
                    openWindow(id: AppWindowID.main)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!sessionController.canStartWholeMac)

            Button(L10n.string(.menuStartScreenOnly)) {
                sessionController.startCleaning(mode: .screenOnly)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!sessionController.canPerformPrimaryAction(for: .screenOnly))

            Button(L10n.string(sessionController.keyboardPermissionPrimaryAction.titleKey)) {
                sessionController.performPrimaryActionFromMenu(for: .keyboardOnly) {
                    openWindow(id: AppWindowID.main)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(sessionController.isCleaning || !sessionController.canPerformPrimaryAction(for: .keyboardOnly))

            Divider()

            if sessionController.activeMode == .screenOnly {
                exitButton.keyboardShortcut(.escape, modifiers: [])
            } else {
                exitButton
            }
        }
    }

    private var exitButton: some View {
        Button(L10n.string(.menuExitCleaning)) {
            sessionController.stopCleaning(trigger: .menuCommand)
        }
        .disabled(!sessionController.isCleaning)
    }
}
