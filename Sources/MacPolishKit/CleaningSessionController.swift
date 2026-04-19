import AppKit
import Combine
import Foundation

public enum ExitTrigger: Equatable {
    case escapeKey
    case button
    case menuCommand
}

@MainActor
public protocol MainWindowControlling: AnyObject {
    func hide()
    func showAndFocus()
}

@MainActor
public protocol ApplicationControlling: AnyObject {
    func activate(ignoringOtherApps: Bool)
}

extension NSApplication: ApplicationControlling { }

@MainActor
public final class AppMainWindowController: MainWindowControlling {
    private weak var window: NSWindow?

    public init(window: NSWindow) {
        self.window = window
    }

    public func hide() {
        window?.orderOut(nil)
    }

    public func showAndFocus() {
        guard let window else {
            return
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

@MainActor
public final class CleaningSessionController: ObservableObject {
    @Published public private(set) var isCleaning = false
    @Published public private(set) var activeMode: CleaningMode?
    @Published public private(set) var keyboardPermissionState: KeyboardPermissionState

    private let screenShieldService: ScreenShielding
    private let keyboardCaptureService: KeyboardCapturing
    private let settingsOpener: KeyboardPermissionOpening
    private let applicationController: ApplicationControlling
    private var mainWindowController: MainWindowControlling?

    public private(set) var lastExitTrigger: ExitTrigger?

    public init(
        screenShieldService: ScreenShielding = ScreenShieldService(),
        keyboardCaptureService: KeyboardCapturing = SystemKeyboardCaptureService(),
        settingsOpener: KeyboardPermissionOpening = InputMonitoringSettingsOpener(),
        applicationController: ApplicationControlling = NSApplication.shared,
        mainWindowController: MainWindowControlling? = nil
    ) {
        self.screenShieldService = screenShieldService
        self.keyboardCaptureService = keyboardCaptureService
        self.settingsOpener = settingsOpener
        self.applicationController = applicationController
        self.mainWindowController = mainWindowController
        self.keyboardPermissionState = keyboardCaptureService.permissionState
    }

    public func registerMainWindow(_ window: NSWindow) {
        mainWindowController = AppMainWindowController(window: window)
    }

    @discardableResult
    public func refreshKeyboardPermissionState() -> KeyboardPermissionState {
        let state = keyboardCaptureService.refreshPermissionState()
        keyboardPermissionState = state
        return state
    }

    @discardableResult
    public func requestKeyboardPermission() -> KeyboardPermissionState {
        let state = keyboardCaptureService.requestPermission()
        keyboardPermissionState = state
        return state
    }

    public func openKeyboardPermissionSettings() {
        settingsOpener.openInputMonitoringSettings()
    }

    public func startCleaning(mode: CleaningMode) {
        guard !isCleaning else {
            return
        }

        if mode == .keyboardOnly {
            guard refreshKeyboardPermissionState() == .granted else {
                return
            }

            guard keyboardCaptureService.startCapturing() else {
                keyboardPermissionState = keyboardCaptureService.refreshPermissionState()
                return
            }
        }

        let started = screenShieldService.start(mode: mode) { [weak self] trigger in
            self?.stopCleaning(trigger: trigger)
        }

        guard started else {
            if mode == .keyboardOnly {
                keyboardCaptureService.stopCapturing()
            }
            return
        }

        activeMode = mode
        isCleaning = true
        lastExitTrigger = nil

        mainWindowController?.hide()
        if mode == .wholeMac {
            applicationController.activate(ignoringOtherApps: true)
        }
    }

    public func stopCleaning(trigger: ExitTrigger) {
        guard isCleaning else {
            return
        }

        screenShieldService.stop()
        keyboardCaptureService.stopCapturing()

        isCleaning = false
        activeMode = nil
        lastExitTrigger = trigger

        mainWindowController?.showAndFocus()
        applicationController.activate(ignoringOtherApps: true)
        keyboardPermissionState = keyboardCaptureService.refreshPermissionState()
    }
}
