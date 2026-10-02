import AppKit
import SwiftUI

public struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var controller: CleaningSessionController

    public init(sessionController: CleaningSessionController) {
        _controller = ObservedObject(wrappedValue: sessionController)
    }

    public var body: some View {
        if controller.notice == .mainWindowOpeningFailed {
            Text(verbatim: L10n.string(.statusMainWindowOpeningFailed))
            Divider()
        }
        if controller.isOpeningMainWindow {
            Text(verbatim: L10n.string(.statusOpeningMainWindow))
            Button(L10n.string(.actionCancel)) { controller.cancelOpeningMainWindow() }
            Divider()
        }
        if controller.isRelaunching {
            Text(verbatim: L10n.string(.statusRelaunching))
            Divider()
        }
        if let mode = controller.activeMode {
            Text(verbatim: L10n.string(mode.titleKey) + " · " + L10n.string(.statusCleaning))
            Text(verbatim: L10n.string(controller.activeKeyboardProtection.descriptionKey))
            Button(L10n.string(.menuExitCleaning)) {
                controller.stopCleaning(trigger: .menuCommand)
            }
            Divider()
        }

        Button(L10n.string(.menuOpenMainWindow)) {
            openWindow(id: AppWindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }

        if !controller.isCleaning {
            Divider()
            ForEach(CleaningMode.allCases) { mode in
                Button(L10n.string(controller.permissionPrimaryAction(for: mode)?.titleKey ?? mode.actionKey)) {
                    controller.performPrimaryActionFromMenu(for: mode) {
                        openWindow(id: AppWindowID.main)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                .disabled(!controller.canPerformPrimaryAction(for: mode))
            }
        }

        Divider()
        Button(L10n.string(.menuQuit)) {
            controller.stopCleaning(trigger: .applicationTerminating)
            NSApp.terminate(nil)
        }
    }
}
