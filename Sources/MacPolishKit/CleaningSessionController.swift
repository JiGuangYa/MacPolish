import AppKit
import Combine
import Foundation

public enum ExitTrigger: Equatable, Sendable {
    case escapeKey
    case emergencyShortcut
    case button
    case menuCommand
    case mainWindowUnavailable
    case mainWindowLeftActiveSpace
    case applicationHidden
    case applicationTerminating
    case systemSleep
    case sessionResignedActive
    case displayConfigurationChanged
    case keyboardProtectionLost
    case secureInputEnabled
    case applicationDeactivated

    var shouldRestoreMainWindow: Bool {
        switch self {
        case .escapeKey, .emergencyShortcut, .button, .menuCommand, .keyboardProtectionLost:
            return true
        case .mainWindowUnavailable, .mainWindowLeftActiveSpace, .applicationHidden, .applicationTerminating,
             .systemSleep, .sessionResignedActive, .displayConfigurationChanged, .secureInputEnabled, .applicationDeactivated:
            return false
        }
    }
}

@MainActor
public protocol MainWindowControlling: AnyObject {
    var isReadyForKeyboardCleaning: Bool { get }
    func hide()
    func showAndFocus()
}

@MainActor
public protocol ApplicationControlling: AnyObject {
    var isActive: Bool { get }
    func activate(ignoringOtherApps: Bool)
}

extension NSApplication: ApplicationControlling { }

@MainActor
public final class AppMainWindowController: MainWindowControlling {
    private weak var window: NSWindow?

    public init(window: NSWindow) {
        self.window = window
    }

    public var isReadyForKeyboardCleaning: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isVisible && !window.isMiniaturized && window.isKeyWindow && window.isOnActiveSpace
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
    @Published public private(set) var isRelaunching = false
    @Published public private(set) var isOpeningMainWindow = false
    @Published public private(set) var activeMode: CleaningMode?
    @Published public private(set) var activeKeyboardProtection: KeyboardProtection = .none
    @Published public private(set) var sessionStartedAt: Date?
    @Published public private(set) var notice: CleaningSessionNotice?
    @Published public private(set) var keyboardPermissionState: KeyboardPermissionState
    @Published public private(set) var keyboardProtectionAvailability: KeyboardProtectionAvailability

    public let appSettings: AppSettings
    public let emergencyExitGesture: EmergencyExitGesture

    private let screenShieldService: ScreenShielding
    private let keyboardCaptureService: KeyboardCapturing
    private let settingsOpener: KeyboardPermissionOpening
    private let applicationController: ApplicationControlling
    private let applicationRelauncher: ApplicationRelaunching
    private let lifecycleMonitor: CleaningSessionLifecycleMonitor
    private let dateProvider: () -> Date
    private let uptimeProvider: () -> TimeInterval
    private var sessionStartedUptime: TimeInterval?
    private let keyboardOnlyButtonExitDelay: TimeInterval
    private let mainWindowOpeningTimeout: TimeInterval
    private var mainWindowController: MainWindowControlling?
    private var availabilityPollingTask: Task<Void, Never>?
    private var protectionMonitoring: AnyCancellable?
    private var requiresAppRelaunch = false
    private var activeSessionID: UUID?
    private var relaunchRequestID: UUID?
    private var mainWindowOpeningID: UUID?
    private var mainWindowOpeningTask: Task<Void, Never>?

    public private(set) var lastExitTrigger: ExitTrigger?

    public init(
        appSettings: AppSettings = AppSettings(),
        emergencyExitGesture: EmergencyExitGesture = EmergencyExitGesture(),
        screenShieldService: ScreenShielding? = nil,
        keyboardCaptureService: KeyboardCapturing = SystemKeyboardCaptureService(),
        settingsOpener: KeyboardPermissionOpening = InputMonitoringSettingsOpener(),
        applicationController: ApplicationControlling = NSApplication.shared,
        applicationRelauncher: ApplicationRelaunching = AppRelauncher(),
        mainWindowController: MainWindowControlling? = nil,
        dateProvider: @escaping () -> Date = Date.init,
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        keyboardOnlyButtonExitDelay: TimeInterval = 0.45,
        mainWindowOpeningTimeout: TimeInterval = 5,
        displayConfigurationProvider: @escaping @MainActor () -> DisplayConfiguration = DisplayConfiguration.current,
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.appSettings = appSettings
        self.emergencyExitGesture = emergencyExitGesture
        self.screenShieldService = screenShieldService ?? ScreenShieldService(appSettings: appSettings, emergencyExitGesture: emergencyExitGesture)
        self.keyboardCaptureService = keyboardCaptureService
        self.settingsOpener = settingsOpener
        self.applicationController = applicationController
        self.applicationRelauncher = applicationRelauncher
        self.lifecycleMonitor = CleaningSessionLifecycleMonitor(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            displayConfigurationProvider: displayConfigurationProvider
        )
        self.mainWindowController = mainWindowController
        self.dateProvider = dateProvider
        self.uptimeProvider = uptimeProvider
        self.keyboardOnlyButtonExitDelay = keyboardOnlyButtonExitDelay
        self.mainWindowOpeningTimeout = mainWindowOpeningTimeout.isFinite && mainWindowOpeningTimeout > 0
            ? mainWindowOpeningTimeout : 5

        let permissionState = keyboardCaptureService.permissionState
        self.keyboardPermissionState = permissionState
        self.keyboardProtectionAvailability = permissionState == .granted
            ? (keyboardCaptureService.isSecureInputEnabled ? .blockedBySecureInput : .ready)
            : .needsPermission
    }

    deinit {
        availabilityPollingTask?.cancel()
        mainWindowOpeningTask?.cancel()
    }

    public func registerMainWindow(_ window: NSWindow) {
        mainWindowController = AppMainWindowController(window: window)
        lifecycleMonitor.registerMainWindow(window)
    }

    public var canStartWholeMac: Bool {
        !isCleaning && !isRelaunching && !isOpeningMainWindow
    }

    /// Duration and the startup click guard must not change when macOS adjusts
    /// its wall clock. The calendar start date remains available for display.
    public var elapsedCleaningTime: TimeInterval {
        guard let sessionStartedUptime else { return 0 }
        let elapsed = uptimeProvider() - sessionStartedUptime
        return elapsed.isFinite ? max(0, elapsed) : 0
    }

    public var canStartKeyboardOnly: Bool {
        !isRelaunching && !isOpeningMainWindow && (activeMode == .keyboardOnly || (!isCleaning && keyboardProtectionAvailability == .ready))
    }

    public var showsKeyboardPermissionBanner: Bool {
        false
    }

    public var globalKeyboardPermissionPrimaryAction: KeyboardPermissionAction {
        switch keyboardProtectionAvailability {
        case .needsPermission:
            return keyboardPermissionState == .denied ? .openSettings : .requestAccess
        case .waitingForSystem, .blockedBySecureInput:
            return .refreshNow
        case .needsRelaunch:
            return .relaunchNow
        case .ready:
            return .startWholeMacCleaning
        }
    }

    public var wholeMacPermissionPrimaryAction: KeyboardPermissionAction {
        switch keyboardProtectionAvailability {
        case .needsPermission:
            return keyboardPermissionState == .denied ? .openSettings : .requestAccess
        case .waitingForSystem, .blockedBySecureInput:
            return .refreshNow
        case .needsRelaunch:
            return .relaunchNow
        case .ready:
            return .startWholeMacCleaning
        }
    }

    public var keyboardPermissionPrimaryAction: KeyboardPermissionAction {
        switch keyboardProtectionAvailability {
        case .needsPermission:
            return keyboardPermissionState == .denied ? .openSettings : .requestAccess
        case .waitingForSystem, .blockedBySecureInput:
            return .refreshNow
        case .needsRelaunch:
            return .relaunchNow
        case .ready:
            return .startKeyboardCleaning
        }
    }

    @discardableResult
    public func refreshKeyboardPermissionState() -> KeyboardPermissionState {
        let state = keyboardCaptureService.refreshPermissionState()
        keyboardPermissionState = state
        return state
    }

    @discardableResult
    public func refreshKeyboardProtectionAvailability(startPollingIfNeeded: Bool = false) -> KeyboardProtectionAvailability {
        let permissionState = refreshKeyboardPermissionState()
        let isSecureInputEnabled = keyboardCaptureService.isSecureInputEnabled

        if activeKeyboardProtection == .global &&
            (permissionState != .granted || isSecureInputEnabled || !keyboardCaptureService.isCapturing) {
            requiresAppRelaunch = permissionState == .granted && !isSecureInputEnabled
            stopCleaning(trigger: permissionState == .granted && isSecureInputEnabled ? .secureInputEnabled : .keyboardProtectionLost)
            return keyboardProtectionAvailability
        }

        switch permissionState {
        case .notDetermined, .denied:
            availabilityPollingTask?.cancel()
            availabilityPollingTask = nil
            requiresAppRelaunch = false
            keyboardProtectionAvailability = .needsPermission

        case .granted:
            if isSecureInputEnabled {
                keyboardProtectionAvailability = .blockedBySecureInput
                if startPollingIfNeeded {
                    startAvailabilityPolling()
                }
                return keyboardProtectionAvailability
            }

            if requiresAppRelaunch {
                availabilityPollingTask?.cancel()
                availabilityPollingTask = nil
                keyboardProtectionAvailability = .needsRelaunch
                return keyboardProtectionAvailability
            }

            if keyboardCaptureService.probeCaptureAvailability() {
                availabilityPollingTask?.cancel()
                availabilityPollingTask = nil
                keyboardProtectionAvailability = .ready
            } else {
                keyboardProtectionAvailability = .waitingForSystem
                if startPollingIfNeeded {
                    startAvailabilityPolling()
                }
            }
        }

        return keyboardProtectionAvailability
    }

    @discardableResult
    public func requestKeyboardPermission() -> KeyboardPermissionState {
        guard !isCleaning && !isRelaunching && !isOpeningMainWindow else { return keyboardPermissionState }
        requiresAppRelaunch = false
        _ = keyboardCaptureService.requestPermission()
        _ = refreshKeyboardProtectionAvailability(startPollingIfNeeded: true)
        return keyboardPermissionState
    }

    public func openKeyboardPermissionSettings() {
        guard !isCleaning && !isRelaunching && !isOpeningMainWindow else { return }
        settingsOpener.openInputMonitoringSettings()
    }

    public func refreshKeyboardProtectionNow() {
        guard !isCleaning && !isRelaunching && !isOpeningMainWindow else { return }
        _ = refreshKeyboardProtectionAvailability(startPollingIfNeeded: true)
    }

    public func relaunchApplication() {
        guard !isCleaning && !isRelaunching && !isOpeningMainWindow else { return }
        let requestID = UUID()
        relaunchRequestID = requestID
        isRelaunching = true
        notice = nil
        availabilityPollingTask?.cancel()
        availabilityPollingTask = nil
        applicationRelauncher.relaunch { [weak self] succeeded in
            guard let self, self.relaunchRequestID == requestID else { return }
            self.relaunchRequestID = nil
            // Keep actions disabled during a successful handoff until this
            // instance terminates. A failure always leaves it usable.
            if !succeeded {
                self.isRelaunching = false
                self.notice = .relaunchFailed
            }
        }
    }

    public func isModeActive(_ mode: CleaningMode) -> Bool {
        activeMode == mode
    }

    public func permissionPrimaryAction(for mode: CleaningMode) -> KeyboardPermissionAction? {
        switch mode {
        case .wholeMac:
            return nil
        case .keyboardOnly:
            return keyboardPermissionPrimaryAction
        case .screenOnly:
            return nil
        }
    }

    public func canPerformPrimaryAction(for mode: CleaningMode) -> Bool {
        guard !isRelaunching && !isOpeningMainWindow else { return false }
        if activeMode == .keyboardOnly && mode == .keyboardOnly {
            return true
        }

        return !isCleaning
    }

    /// Menu actions can run after the main window has closed. Wait for SwiftUI
    /// to restore a visible, focused window before taking over the keyboard or
    /// presenting its permission flow. Whole Mac also needs foreground focus
    /// if global capture becomes unavailable and it uses local protection.
    /// No keyboard capture runs while waiting.
    public func performPrimaryActionFromMenu(for mode: CleaningMode, openMainWindow: @MainActor () -> Void) {
        guard canPerformPrimaryAction(for: mode) else { return }
        guard mode != .screenOnly && !isCleaning else {
            performPrimaryAction(for: mode)
            return
        }

        let requestID = UUID()
        let requestedAction: KeyboardPermissionAction = mode == .wholeMac ? .startWholeMacCleaning : keyboardPermissionPrimaryAction
        mainWindowOpeningID = requestID
        isOpeningMainWindow = true
        notice = nil
        lifecycleMonitor.start(mode: .keyboardOnly, keyboardProtection: .none) { [weak self] _ in
            guard let self, self.mainWindowOpeningID == requestID else { return }
            self.cancelOpeningMainWindow()
        }
        openMainWindow()
        guard mainWindowOpeningID == requestID else { return }
        if completeMainWindowOpeningIfReady(requestID: requestID, requestedAction: requestedAction) { return }

        let deadline = ProcessInfo.processInfo.systemUptime + mainWindowOpeningTimeout
        mainWindowOpeningTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
                guard !Task.isCancelled, let self, self.mainWindowOpeningID == requestID else { return }
                if self.completeMainWindowOpeningIfReady(requestID: requestID, requestedAction: requestedAction) { return }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    self.cancelOpeningMainWindow()
                    self.notice = .mainWindowOpeningFailed
                    return
                }
            }
        }
    }

    public func cancelOpeningMainWindow() {
        guard mainWindowOpeningID != nil else { return }
        mainWindowOpeningID = nil
        isOpeningMainWindow = false
        mainWindowOpeningTask?.cancel()
        mainWindowOpeningTask = nil
        lifecycleMonitor.stop()
    }

    private func completeMainWindowOpeningIfReady(requestID: UUID, requestedAction: KeyboardPermissionAction) -> Bool {
        guard mainWindowOpeningID == requestID, mainWindowController?.isReadyForKeyboardCleaning == true else { return false }
        cancelOpeningMainWindow()
        _ = refreshKeyboardProtectionAvailability()
        // A permission or refresh command must not silently turn into a start
        // if authorization changes while SwiftUI is opening the window.
        switch requestedAction {
        case .requestAccess:
            if keyboardPermissionState != .granted { _ = requestKeyboardPermission() }
        case .openSettings:
            openKeyboardPermissionSettings()
        case .refreshNow:
            break
        case .relaunchNow:
            relaunchApplication()
        case .startKeyboardCleaning:
            performPrimaryAction(for: .keyboardOnly)
        case .startWholeMacCleaning:
            performPrimaryAction(for: .wholeMac)
        }
        return true
    }

    public func performPrimaryAction(for mode: CleaningMode) {
        guard canPerformPrimaryAction(for: mode) else { return }
        if activeMode == .keyboardOnly && mode == .keyboardOnly {
            guard canExitKeyboardOnlyFromPrimaryButton() else {
                return
            }

            stopCleaning(trigger: .button)
            return
        }

        guard mode.requiresGlobalKeyboardCaptureBeforeStart else {
            startCleaning(mode: mode)
            return
        }

        switch permissionPrimaryAction(for: mode) {
        case .requestAccess:
            _ = requestKeyboardPermission()
        case .openSettings:
            openKeyboardPermissionSettings()
        case .refreshNow:
            refreshKeyboardProtectionNow()
        case .relaunchNow:
            relaunchApplication()
        case .startWholeMacCleaning, .startKeyboardCleaning:
            startCleaning(mode: mode)
        case .none:
            startCleaning(mode: mode)
        }
    }

    public func startCleaning(mode: CleaningMode) {
        guard !isCleaning && !isRelaunching && !isOpeningMainWindow else {
            return
        }

        let sessionID = UUID()
        let didStartGlobalKeyboardCapture = startGlobalKeyboardCaptureIfNeeded(for: mode, sessionID: sessionID)
        guard didStartGlobalKeyboardCapture || mode.canStartWithoutGlobalKeyboardCapture else {
            return
        }

        let protection: KeyboardProtection = didStartGlobalKeyboardCapture ? .global : (mode == .wholeMac ? .local : .none)
        guard protection != .local || applicationController.isActive else {
            // An activation request can be refused. Without foreground focus,
            // a black shield cannot provide the local protection it promises.
            notice = .mainWindowOpeningFailed
            return
        }
        let started = screenShieldService.start(mode: mode, keyboardProtection: protection) { [weak self] trigger in
            guard let self, self.activeSessionID == sessionID else { return }
            self.stopCleaning(trigger: trigger)
        }

        guard started else {
            if didStartGlobalKeyboardCapture {
                keyboardCaptureService.stopCapturing()
            }
            screenShieldService.stop()
            notice = .shieldUnavailable
            return
        }

        appSettings.markModeUsed(mode)

        activeMode = mode
        activeKeyboardProtection = protection
        isCleaning = true
        lastExitTrigger = nil
        notice = nil
        sessionStartedAt = dateProvider()
        sessionStartedUptime = uptimeProvider()
        activeSessionID = sessionID
        if mode != .screenOnly {
            emergencyExitGesture.start { [weak self] in
                guard let self, self.activeSessionID == sessionID else { return }
                self.stopCleaning(trigger: .emergencyShortcut)
            }
        }
        lifecycleMonitor.start(mode: mode, keyboardProtection: protection) { [weak self] trigger in
            self?.stopCleaning(trigger: trigger)
        }
        if protection == .global {
            startProtectionMonitoring(sessionID: sessionID)
        }

        if mode != .screenOnly {
            applicationController.activate(ignoringOtherApps: true)
        }
    }

    public func stopCleaning(trigger: ExitTrigger) {
        cancelOpeningMainWindow()
        guard isCleaning else {
            return
        }

        // Clear the session before tearing down windows, which can deliver
        // further notifications or exit callbacks during teardown.
        lifecycleMonitor.stop()
        isCleaning = false
        activeMode = nil
        activeKeyboardProtection = .none
        lastExitTrigger = trigger
        sessionStartedAt = nil
        sessionStartedUptime = nil
        activeSessionID = nil
        emergencyExitGesture.stop()
        availabilityPollingTask?.cancel()
        availabilityPollingTask = nil
        protectionMonitoring?.cancel()
        protectionMonitoring = nil

        switch trigger {
        case .escapeKey, .emergencyShortcut, .button, .menuCommand, .applicationTerminating:
            notice = nil
        default:
            notice = .interrupted(trigger)
        }

        keyboardCaptureService.stopCapturing()
        screenShieldService.stop()

        if trigger.shouldRestoreMainWindow && appSettings.reopenMainWindowAfterCleaning {
            mainWindowController?.showAndFocus()
            applicationController.activate(ignoringOtherApps: true)
        }

        _ = refreshKeyboardProtectionAvailability(startPollingIfNeeded: false)
    }

    public func dismissNotice() {
        notice = nil
    }

    private func startProtectionMonitoring(sessionID: UUID) {
        protectionMonitoring?.cancel()
        // A menu or drag must not defer detection of lost keyboard protection.
        // The subscription cancels when the session stops or its owner is released.
        protectionMonitoring = Timer.publish(every: 1, tolerance: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.activeSessionID == sessionID, self.activeKeyboardProtection == .global else { return }
                _ = self.refreshKeyboardProtectionAvailability()
            }
    }

    private func startAvailabilityPolling() {
        guard !isRelaunching else { return }
        availabilityPollingTask?.cancel()

        availabilityPollingTask = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else {
                    return
                }

                let availability = self.refreshKeyboardProtectionAvailability(startPollingIfNeeded: false)
                if availability != .waitingForSystem && availability != .blockedBySecureInput {
                    self.availabilityPollingTask = nil
                    return
                }
            }

            self?.availabilityPollingTask = nil
        }
    }

    private func startGlobalKeyboardCaptureIfNeeded(for mode: CleaningMode, sessionID: UUID) -> Bool {
        guard mode.usesGlobalKeyboardCapture else {
            return false
        }

        guard refreshKeyboardProtectionAvailability(startPollingIfNeeded: false) == .ready else {
            return false
        }

        guard keyboardCaptureService.startCapturing(for: mode, onEmergencyInput: { [weak self] input in
            guard let self, self.activeSessionID == sessionID else { return }
            self.emergencyExitGesture.handle(input)
        }) else {
            keyboardCaptureService.stopCapturing()
            requiresAppRelaunch = !keyboardCaptureService.isSecureInputEnabled
            _ = refreshKeyboardProtectionAvailability(startPollingIfNeeded: false)
            return false
        }

        return true
    }

    private func canExitKeyboardOnlyFromPrimaryButton() -> Bool {
        guard sessionStartedUptime != nil else {
            return true
        }

        return elapsedCleaningTime >= keyboardOnlyButtonExitDelay
    }
}

private extension CleaningMode {
    var usesGlobalKeyboardCapture: Bool {
        switch self {
        case .wholeMac, .keyboardOnly:
            return true
        case .screenOnly:
            return false
        }
    }

    var requiresGlobalKeyboardCaptureBeforeStart: Bool {
        self == .keyboardOnly
    }

    var canStartWithoutGlobalKeyboardCapture: Bool {
        self != .keyboardOnly
    }
}
