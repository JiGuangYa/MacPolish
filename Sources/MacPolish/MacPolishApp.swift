import AppKit
import MacPolishKit
import SwiftUI

@main
struct MacPolishApp: App {
    @NSApplicationDelegateAdaptor(MacPolishAppDelegate.self) private var appDelegate
    @StateObject private var sessionController = CleaningSessionController()

    var body: some Scene {
        WindowGroup(L10n.string(.appTitle)) {
            MainView(sessionController: sessionController)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 920, height: 470)
        .commands {
            AppCommands(sessionController: sessionController)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                sessionController.refreshKeyboardPermissionState()
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase
}

final class MacPolishAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
