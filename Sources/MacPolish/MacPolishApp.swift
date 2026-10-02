import AppKit
import MacPolishKit
import SwiftUI

@main
struct MacPolishApp: App {
    @NSApplicationDelegateAdaptor(MacPolishAppDelegate.self) private var appDelegate
    @StateObject private var appSettings: AppSettings
    @StateObject private var sessionController: CleaningSessionController

    init() {
        let settings = AppSettings()
        _appSettings = StateObject(wrappedValue: settings)
        _sessionController = StateObject(
            wrappedValue: CleaningSessionController(appSettings: settings)
        )
    }

    var body: some Scene {
        MacPolishScenes(sessionController: sessionController, appSettings: appSettings)
    }
}

final class MacPolishAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
