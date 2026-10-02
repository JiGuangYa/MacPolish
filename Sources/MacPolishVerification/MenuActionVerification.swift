import AppKit
import MacPolishKit

/// Menu requests exercise the production controller while substituting window
/// readiness. No test opens a desktop window or installs keyboard capture.
@MainActor
enum MenuActionVerification {
    static func run() async {
        verifyVisibleWindow()
        verifyScreenModes()
        await verifyWholeMacForegroundReadiness()
        verifyPermissionRoutes()
        verifyReentrantCancellation()
        verifyHiddenNativeWindow()
        await verifyDelayedWindowAndConflictingActions()
        await verifyTimeoutAndRetry()
        await verifyCancellationAndStaleWaits()
        await verifyPermissionChangesWhileWaiting()
        await verifyPermissionIntentDoesNotBecomeCapture()
        await verifyInterruptedOpening()
        await verifySpaceChangeWhileOpening()
        await verifyLifetime()
        await verifyDelayedNativeWindowAttachment()
    }

    private static func verifyVisibleWindow() {
        let fixture = MenuActionFixture()
        var opened = false
        fixture.keyboard.onStart = { require(opened, "Expected the main window request before capture") }
        fixture.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { opened = true }
        require(fixture.controller.activeMode == .keyboardOnly && !fixture.controller.isOpeningMainWindow,
            "Expected a ready main window to start keyboard cleaning immediately")
        require(fixture.keyboard.startCapturingCallCount == 1, "Expected exactly one keyboard capture")
        fixture.controller.stopCleaning(trigger: .button)
    }

    private static func verifyScreenModes() {
        let fixture = MenuActionFixture()
        fixture.window.isReadyForKeyboardCleaning = false
        var opens = 0
        fixture.controller.performPrimaryActionFromMenu(for: .screenOnly) { opens += 1 }
        require(opens == 0 && fixture.controller.activeMode == .screenOnly, "Expected screen-only cleaning to start without taking foreground focus")
        fixture.controller.stopCleaning(trigger: .button)
    }

    private static func verifyWholeMacForegroundReadiness() async {
        for permission in [KeyboardPermissionState.denied, .granted] {
            let fixture = MenuActionFixture(permission: permission)
            fixture.window.isReadyForKeyboardCleaning = false
            var opens = 0
            fixture.controller.performPrimaryActionFromMenu(for: .wholeMac) { opens += 1 }
            await pause(60)
            require(opens == 1 && fixture.controller.isOpeningMainWindow && fixture.shield.startCallHistory.isEmpty,
                "Expected Whole Mac from a menu to wait for its foreground window before showing shields")
            require(fixture.keyboard.startCapturingCallCount == 0 && fixture.keyboard.requestPermissionCallCount == 0,
                "Expected pending Whole Mac cleaning not to capture input or ask for permission")
            fixture.window.isReadyForKeyboardCleaning = true
            await waitForWindowOpeningToFinish(fixture.controller)
            require(fixture.controller.activeMode == .wholeMac && !fixture.controller.isOpeningMainWindow,
                "Expected the remembered Whole Mac intent to start Whole Mac after the window becomes ready")
            require(fixture.controller.activeKeyboardProtection == (permission == .granted ? .global : .local),
                "Expected Whole Mac to use the available protection without turning into a permission action")
            fixture.controller.stopCleaning(trigger: .applicationTerminating)
        }
    }

    private static func verifyPermissionRoutes() {
        for permission in [KeyboardPermissionState.notDetermined, .denied] {
            let fixture = MenuActionFixture(permission: permission)
            var opened = false
            fixture.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { opened = true }
            require(opened && !fixture.controller.isCleaning, "Expected permission actions to restore their explanation window")
            require(fixture.keyboard.requestPermissionCallCount == (permission == .notDetermined ? 1 : 0),
                "Expected a first request to use the normal permission flow")
            require(fixture.settingsOpener.openCallCount == (permission == .denied ? 1 : 0),
                "Expected denied access to open System Settings")
        }
    }

    private static func verifyReentrantCancellation() {
        let fixture = MenuActionFixture()
        fixture.controller.performPrimaryActionFromMenu(for: .keyboardOnly) {
            fixture.controller.cancelOpeningMainWindow()
        }
        require(!fixture.controller.isCleaning && !fixture.controller.isOpeningMainWindow,
            "Expected cancellation during the open callback not to start capture")
    }

    private static func verifyHiddenNativeWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = AppMainWindowController(window: window)
        require(!controller.isReadyForKeyboardCleaning, "Expected an attached but hidden native window not to authorize capture")
        window.close()
        require(!controller.isReadyForKeyboardCleaning, "Expected a closed native window not to authorize capture")
    }

    private static func verifyDelayedWindowAndConflictingActions() async {
        let fixture = MenuActionFixture()
        fixture.window.isReadyForKeyboardCleaning = false
        var opens = 0
        fixture.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { opens += 1 }
        require(fixture.controller.isOpeningMainWindow && !fixture.controller.isCleaning,
            "Expected opening to be a visible pending state")
        require(!fixture.controller.canStartWholeMac && !fixture.controller.canStartKeyboardOnly,
            "Expected conflicting start buttons disabled while opening")
        for mode in CleaningMode.allCases {
            require(!fixture.controller.canPerformPrimaryAction(for: mode), "Expected pending menu actions to disable all starts")
            fixture.controller.performPrimaryActionFromMenu(for: mode) { opens += 1 }
            fixture.controller.startCleaning(mode: mode)
        }
        fixture.controller.requestKeyboardPermission()
        fixture.controller.openKeyboardPermissionSettings()
        fixture.controller.relaunchApplication()
        require(opens == 1 && fixture.keyboard.startCapturingCallCount == 0 && fixture.shield.startCallHistory.isEmpty,
            "Expected duplicate starts not to open windows or capture keyboard input")
        require(fixture.relauncher.relaunchCallCount == 0 && fixture.keyboard.requestPermissionCallCount == 0 && fixture.settingsOpener.openCallCount == 0,
            "Expected permission and relaunch actions not to interrupt pending window opening")
        await pause(70)
        require(!fixture.controller.isCleaning, "Expected elapsed time alone not to imply window readiness")
        fixture.window.isReadyForKeyboardCleaning = true
        await waitForWindowOpeningToFinish(fixture.controller)
        require(fixture.controller.activeMode == .keyboardOnly && !fixture.controller.isOpeningMainWindow,
            "Expected a window that becomes ready later to start the requested session")
        require(fixture.keyboard.startCapturingCallCount == 1, "Expected readiness polling to start only once")
        fixture.controller.stopCleaning(trigger: .button)
    }

    private static func verifyTimeoutAndRetry() async {
        let fixture = MenuActionFixture(timeout: 0.06)
        fixture.window.isReadyForKeyboardCleaning = false
        fixture.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { }
        await waitForWindowOpeningToFinish(fixture.controller)
        require(!fixture.controller.isOpeningMainWindow && !fixture.controller.isCleaning,
            "Expected opening timeout to leave the app idle")
        require(fixture.controller.notice == .mainWindowOpeningFailed && fixture.keyboard.startCapturingCallCount == 0,
            "Expected a useful failure notice and no capture after timeout")
        fixture.window.isReadyForKeyboardCleaning = true
        await pause(60)
        require(!fixture.controller.isCleaning, "Expected a late window not to revive a timed-out request")
        fixture.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { }
        require(fixture.controller.activeMode == .keyboardOnly && fixture.controller.notice == nil,
            "Expected an explicit retry to clear the failure and start")
        fixture.controller.stopCleaning(trigger: .button)
    }

    private static func verifyCancellationAndStaleWaits() async {
        let fixture = MenuActionFixture()
        fixture.window.isReadyForKeyboardCleaning = false
        fixture.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { }
        fixture.controller.cancelOpeningMainWindow()
        fixture.window.isReadyForKeyboardCleaning = true
        fixture.controller.startCleaning(mode: .screenOnly)
        await pause(90)
        require(fixture.controller.activeMode == .screenOnly && fixture.keyboard.startCapturingCallCount == 0,
            "Expected a cancelled waiter not to interrupt a newer screen-cleaning session")
        fixture.controller.stopCleaning(trigger: .button)
        fixture.window.isReadyForKeyboardCleaning = false
        fixture.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { }
        fixture.controller.stopCleaning(trigger: .applicationTerminating)
        fixture.window.isReadyForKeyboardCleaning = true
        await pause(60)
        require(!fixture.controller.isCleaning && !fixture.controller.isOpeningMainWindow,
            "Expected quitting to cancel opening even before a session starts")
    }

    private static func verifyPermissionChangesWhileWaiting() async {
        let fixture = MenuActionFixture()
        fixture.window.isReadyForKeyboardCleaning = false
        fixture.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { }
        fixture.keyboard.permissionState = .denied
        fixture.window.isReadyForKeyboardCleaning = true
        await waitForWindowOpeningToFinish(fixture.controller)
        require(!fixture.controller.isCleaning && fixture.keyboard.startCapturingCallCount == 0,
            "Expected permission to be rechecked when the window becomes ready")
        require(fixture.settingsOpener.openCallCount == 1, "Expected the updated permission state to choose the recovery action")

        let secure = MenuActionFixture()
        secure.window.isReadyForKeyboardCleaning = false
        secure.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { }
        secure.keyboard.isSecureInputEnabled = true
        secure.window.isReadyForKeyboardCleaning = true
        await waitForWindowOpeningToFinish(secure.controller)
        require(!secure.controller.isCleaning && secure.keyboard.startCapturingCallCount == 0,
            "Expected Secure Input acquired while opening to prevent capture")
        require(secure.controller.keyboardProtectionAvailability == .blockedBySecureInput,
            "Expected the refreshed window to explain the current protection limitation")
    }

    private static func verifyInterruptedOpening() async {
        let interruptions: [(Notification.Name, Bool)] = [
            (NSApplication.willHideNotification, false), (NSApplication.didChangeScreenParametersNotification, false),
            (NSWorkspace.willSleepNotification, true), (NSWorkspace.sessionDidResignActiveNotification, true)
        ]
        for (name, workspace) in interruptions {
            let fixture = MenuActionFixture()
            fixture.window.isReadyForKeyboardCleaning = false
            fixture.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { }
            if name == NSApplication.didChangeScreenParametersNotification { fixture.displays.changeGeometry() }
            (workspace ? fixture.workspaceNotifications : fixture.notifications).post(name: name, object: nil)
            require(!fixture.controller.isOpeningMainWindow, "Expected a lifecycle interruption to cancel opening")
            require(fixture.controller.notice == nil, "Expected an unstarted session not to report that cleaning ended")
            fixture.window.isReadyForKeyboardCleaning = true
            await pause(50)
            require(!fixture.controller.isCleaning && fixture.keyboard.startCapturingCallCount == 0,
                "Expected returning from an interruption not to start a deferred capture")
        }
    }

    private static func verifySpaceChangeWhileOpening() async {
        let fixture = MenuActionFixture()
        let window = SpaceTestWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        fixture.controller.registerMainWindow(window)
        fixture.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { }
        fixture.workspaceNotifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        require(fixture.controller.isOpeningMainWindow, "Expected a Space change that keeps the target window available to preserve opening")
        window.belongsToActiveSpace = false
        fixture.workspaceNotifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        require(!fixture.controller.isOpeningMainWindow && fixture.controller.notice == nil,
            "Expected leaving the target Space to cancel an unstarted request without a cleaning-ended notice")
        window.belongsToActiveSpace = true
        fixture.controller.startCleaning(mode: .screenOnly)
        await pause(90)
        require(fixture.controller.activeMode == .screenOnly && fixture.keyboard.startCapturingCallCount == 0,
            "Expected a cancelled Space request not to capture the keyboard or interrupt a newer session")
        fixture.controller.stopCleaning(trigger: .applicationTerminating)
    }

    private static func verifyPermissionIntentDoesNotBecomeCapture() async {
        let request = MenuActionFixture(permission: .notDetermined)
        request.window.isReadyForKeyboardCleaning = false
        request.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { }
        request.keyboard.permissionState = .granted
        request.keyboard.probeCaptureAvailabilityResult = true
        request.window.isReadyForKeyboardCleaning = true
        await waitForWindowOpeningToFinish(request.controller)
        require(!request.controller.isCleaning && request.keyboard.startCapturingCallCount == 0 && request.keyboard.requestPermissionCallCount == 0,
            "Expected newly granted access not to turn a permission request into capture or another prompt")

        let refresh = MenuActionFixture()
        refresh.keyboard.probeCaptureAvailabilityResult = false
        refresh.controller.refreshKeyboardProtectionAvailability()
        require(refresh.controller.keyboardPermissionPrimaryAction == .refreshNow, "Expected the original menu action to be Refresh")
        refresh.window.isReadyForKeyboardCleaning = false
        refresh.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { }
        refresh.keyboard.probeCaptureAvailabilityResult = true
        refresh.window.isReadyForKeyboardCleaning = true
        await waitForWindowOpeningToFinish(refresh.controller)
        require(refresh.controller.keyboardProtectionAvailability == .ready && !refresh.controller.isCleaning,
            "Expected Refresh to display readiness without silently starting keyboard cleaning")
        require(refresh.keyboard.startCapturingCallCount == 0, "Expected refresh intent never to capture the keyboard")
    }

    private static func verifyLifetime() async {
        weak var released: CleaningSessionController?
        var fixture: MenuActionFixture? = MenuActionFixture()
        fixture!.window.isReadyForKeyboardCleaning = false
        fixture!.controller.performPrimaryActionFromMenu(for: .keyboardOnly) { }
        released = fixture!.controller
        await pause(60)
        fixture = nil
        await pause(60)
        require(released == nil, "Expected the pending request and lifecycle observers not to retain the controller")
    }

    private static func verifyDelayedNativeWindowAttachment() async {
        let windows = (0..<2).map { _ in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        defer { windows.forEach { $0.close() } }
        let view = WindowResolvingView(frame: .zero)
        var resolved: [ObjectIdentifier] = []
        view.onResolve = { resolved.append(ObjectIdentifier($0)) }
        view.resolveWindow()
        await pause(40)
        require(resolved.isEmpty, "Expected an unattached view not to resolve a window")
        windows[0].contentView!.addSubview(view)
        await pause(40)
        require(resolved == [ObjectIdentifier(windows[0])], "Expected attachment after the first lookup to register its window")

        resolved.removeAll()
        view.resolveWindow()
        view.removeFromSuperview()
        windows[1].contentView!.addSubview(view)
        await pause(40)
        require(resolved == [ObjectIdentifier(windows[1])], "Expected a queued old-window lookup not to overwrite the new registration")
        resolved.removeAll()
        view.resolveWindow()
        view.removeFromSuperview()
        await pause(40)
        require(resolved.isEmpty, "Expected removal to invalidate a queued window callback")
        require(windows.allSatisfy { !$0.isVisible }, "Expected attachment verification to leave desktop windows hidden")
    }

    private static func waitForWindowOpeningToFinish(_ controller: CleaningSessionController) async {
        // CI may schedule the readiness task later than a fixed 90 ms pause.
        // Observe its actual completion; never force the controller to advance.
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while controller.isOpeningMainWindow && ProcessInfo.processInfo.systemUptime < deadline {
            await pause(10)
        }
        require(!controller.isOpeningMainWindow, "Expected the pending window request to complete within one second")
    }

    private static func pause(_ milliseconds: Int64) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        MacPolishVerification.require(condition(), message)
    }
}

@MainActor
private struct MenuActionFixture {
    let window = MockMainWindowController()
    let keyboard: MockKeyboardCaptureService
    let shield = MockScreenShieldService()
    let settingsOpener = MockSettingsOpener()
    let relauncher = MockApplicationRelauncher()
    let notifications = NotificationCenter()
    let workspaceNotifications = NotificationCenter()
    let displays = MockDisplayConfiguration()
    let controller: CleaningSessionController

    init(permission: KeyboardPermissionState = .granted, timeout: TimeInterval = 2) {
        keyboard = MockKeyboardCaptureService(permissionState: permission)
        controller = CleaningSessionController(appSettings: AppSettings(userDefaults: MacPolishVerification.testUserDefaults()),
            screenShieldService: shield, keyboardCaptureService: keyboard, settingsOpener: settingsOpener,
            applicationController: MockApplicationController(), applicationRelauncher: relauncher,
            mainWindowController: window, mainWindowOpeningTimeout: timeout,
            displayConfigurationProvider: { [displays] in displays.configuration },
            notificationCenter: notifications, workspaceNotificationCenter: workspaceNotifications)
    }
}
