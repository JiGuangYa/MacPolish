import AppKit
import MacPolishKit

@MainActor
enum SessionLifecycleVerification {
    static func verifyScheduledProtectionMonitoring() async {
        let fixture = SessionFixture()
        let secureFixture = SessionFixture()
        fixture.controller.startCleaning(mode: .keyboardOnly)
        fixture.keyboard.isCapturing = false
        secureFixture.controller.startCleaning(mode: .wholeMac)
        secureFixture.keyboard.isSecureInputEnabled = true

        // Let the real scheduled health check run, without synthesizing a
        // permission refresh or delivering any real keyboard events.
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !fixture.controller.isCleaning && !secureFixture.controller.isCleaning { break }
        }
        require(!fixture.controller.isCleaning, "Expected the scheduled check to detect lost keyboard capture")
        require(fixture.controller.lastExitTrigger == .keyboardProtectionLost, "Expected scheduled capture loss to preserve the cause")
        require(!secureFixture.controller.isCleaning, "Expected the scheduled check to detect Secure Input")
        require(secureFixture.controller.lastExitTrigger == .secureInputEnabled, "Expected scheduled Secure Input detection to preserve the cause")

        secureFixture.controller.refreshKeyboardProtectionNow()
        secureFixture.keyboard.isSecureInputEnabled = false
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if secureFixture.controller.keyboardProtectionAvailability == .ready { break }
        }
        require(secureFixture.controller.keyboardProtectionAvailability == .ready, "Expected refresh polling to recognize cleared Secure Input")

        let trackingFixture = SessionFixture()
        let trackingSecureFixture = SessionFixture()
        let trackingPermissionFixture = SessionFixture()
        let healthyFixture = SessionFixture()
        trackingFixture.controller.startCleaning(mode: .keyboardOnly)
        trackingSecureFixture.controller.startCleaning(mode: .wholeMac)
        trackingPermissionFixture.controller.startCleaning(mode: .keyboardOnly)
        healthyFixture.controller.startCleaning(mode: .keyboardOnly)
        try? await Task.sleep(for: .milliseconds(20))
        trackingFixture.keyboard.isCapturing = false
        trackingSecureFixture.keyboard.isSecureInputEnabled = true
        trackingPermissionFixture.keyboard.permissionState = .denied
        EventTrackingRunLoop.run(for: 1.3)
        require(!trackingFixture.controller.isCleaning && trackingFixture.controller.lastExitTrigger == .keyboardProtectionLost,
            "Expected capture loss to stop cleaning while AppKit is tracking a menu or control")
        require(!trackingSecureFixture.controller.isCleaning && trackingSecureFixture.controller.lastExitTrigger == .secureInputEnabled,
            "Expected Secure Input to stop cleaning while AppKit is tracking a menu or control")
        require(!trackingPermissionFixture.controller.isCleaning && trackingPermissionFixture.controller.lastExitTrigger == .keyboardProtectionLost,
            "Expected revoked permission to stop cleaning during event tracking")
        require(healthyFixture.controller.isCleaning && healthyFixture.keyboard.isCapturing,
            "Expected a healthy session to remain protected during event tracking")
        healthyFixture.controller.stopCleaning(trigger: .button)

        verifyProtectionMonitoringCleanup()
    }

    private static func verifyProtectionMonitoringCleanup() {
        let stopped = SessionFixture()
        let restarted = SessionFixture()
        for fixture in [stopped, restarted] {
            fixture.controller.startCleaning(mode: .keyboardOnly)
            fixture.controller.stopCleaning(trigger: .button)
        }
        restarted.controller.startCleaning(mode: .screenOnly)
        let stoppedReads = stopped.keyboard.refreshPermissionStateCallCount
        let restartedReads = restarted.keyboard.refreshPermissionStateCallCount

        weak var released: CleaningSessionController?
        let retainedKeyboard = autoreleasepool {
            let temporary = SessionFixture()
            temporary.controller.startCleaning(mode: .keyboardOnly)
            released = temporary.controller
            return temporary.keyboard
        }
        require(released == nil, "Expected an active protection timer not to retain its controller")
        let releasedReads = retainedKeyboard.refreshPermissionStateCallCount
        EventTrackingRunLoop.run(for: 1.3)
        require(stopped.keyboard.refreshPermissionStateCallCount == stoppedReads,
            "Expected ended sessions not to continue scheduled permission checks")
        require(restarted.keyboard.refreshPermissionStateCallCount == restartedReads && restarted.controller.activeMode == .screenOnly,
            "Expected a previous keyboard monitor not to inspect or end a later screen-only session")
        require(retainedKeyboard.refreshPermissionStateCallCount == releasedReads,
            "Expected released controllers not to continue scheduled permission checks")
        require(stopped.controller.lastExitTrigger == .button && stopped.keyboard.stopCapturingCallCount == 1,
            "Expected cancelled protection timers not to repeat teardown or replace the user's exit cause")
        restarted.controller.stopCleaning(trigger: .button)
    }

    static func run() {
        verifySystemInterruptions()
        verifyMainWindowInterruptions()
        verifyFailedShieldStartReleasesCapture()
        verifyRepeatedAndReentrantStop()
        verifyOldShieldCannotStopNewSession()
        verifyRestorePreference()
        verifyObserversDoNotRetainController()
        verifyProtectionStateMatchesCapture()
        verifyProtectionLossEndsCleaning()
        verifySecureInputRecovery()
        verifyFocusLossRespectsProtectionScope()
        verifyPermissionActionsStayIdleDuringCleaning()
        verifySessionNoticeLifecycle()
        verifyDisplayNotificationFiltering()
        verifySpaceChanges()
        verifyLocalProtectionRequiresForeground()
        verifyMonotonicSessionDuration()
    }

    private static func verifySystemInterruptions() {
        let applicationEvents: [(Notification.Name, ExitTrigger)] = [
            (NSApplication.willHideNotification, .applicationHidden),
            (NSApplication.willTerminateNotification, .applicationTerminating),
            (NSApplication.didChangeScreenParametersNotification, .displayConfigurationChanged)
        ]
        let workspaceEvents: [(Notification.Name, ExitTrigger)] = [
            (NSWorkspace.willSleepNotification, .systemSleep),
            (NSWorkspace.screensDidSleepNotification, .systemSleep),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive)
        ]

        for mode in CleaningMode.allCases {
            for (events, isWorkspaceEvent) in [(applicationEvents, false), (workspaceEvents, true)] {
                for (notification, trigger) in events {
                    let fixture = SessionFixture()
                    fixture.controller.startCleaning(mode: mode)
                    let activationCount = fixture.application.activationCount
                    let center = isWorkspaceEvent ? fixture.workspaceNotifications : fixture.notifications
                    if trigger == .displayConfigurationChanged { fixture.displays.changeGeometry() }
                    center.post(name: notification, object: nil)

                    require(!fixture.controller.isCleaning, "Expected \(mode) to stop for \(notification)")
                    require(fixture.controller.activeMode == nil, "Expected interrupted mode to clear")
                    require(fixture.controller.lastExitTrigger == trigger, "Expected interruption reason to be preserved")
                    require(fixture.keyboard.stopCapturingCallCount == 1, "Expected interruption to release keyboard capture")
                    require(fixture.shield.stopCallCount == 1, "Expected interruption to remove shields")
                    require(fixture.mainWindow.showAndFocusCallCount == 0, "Expected interruption not to reopen the main window")
                    require(fixture.application.activationCount == activationCount, "Expected interruption not to activate the app")

                    center.post(name: notification, object: nil)
                    require(fixture.shield.stopCallCount == 1, "Expected repeated interruption to be harmless")

                    fixture.controller.startCleaning(mode: mode)
                    require(fixture.controller.isCleaning, "Expected a new session to start after interruption")
                    if trigger == .displayConfigurationChanged { fixture.displays.changeGeometry() }
                    center.post(name: notification, object: nil)
                    require(!fixture.controller.isCleaning, "Expected interruption monitoring to resume for new sessions")
                    require(fixture.keyboard.stopCapturingCallCount == 2, "Expected each session to release capture once")
                }
            }
        }
    }

    private static func verifyMainWindowInterruptions() {
        _ = NSApplication.shared
        let oldWindow = NSWindow()
        let mainWindow = NSWindow()
        // These windows are never shown; no real keyboard event tap is used.
        for mode in CleaningMode.allCases {
            for notification in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
                let fixture = SessionFixture()
                fixture.controller.registerMainWindow(oldWindow)
                fixture.controller.startCleaning(mode: mode)
                fixture.controller.registerMainWindow(mainWindow)
                fixture.controller.registerMainWindow(mainWindow)
                let activationCount = fixture.application.activationCount

                fixture.notifications.post(name: notification, object: oldWindow)
                require(fixture.controller.isCleaning, "Expected unrelated window events not to stop cleaning")

                fixture.notifications.post(name: notification, object: mainWindow)
                if mode == .keyboardOnly {
                    require(!fixture.controller.isCleaning, "Expected losing the keyboard exit button to stop capture")
                    require(fixture.controller.lastExitTrigger == .mainWindowUnavailable, "Expected window interruption reason")
                    require(fixture.keyboard.stopCapturingCallCount == 1, "Expected one capture release despite repeated window registration")
                    require(!mainWindow.isVisible, "Expected closing or minimizing not to reopen the main window")
                    require(fixture.application.activationCount == activationCount, "Expected window interruption not to reactivate the app")
                } else {
                    require(fixture.controller.isCleaning, "Expected shield modes to retain their own exit controls")
                    fixture.controller.stopCleaning(trigger: .applicationTerminating)
                }
            }
        }
    }

    private static func verifyFailedShieldStartReleasesCapture() {
        for mode in CleaningMode.allCases {
            let fixture = SessionFixture()
            fixture.shield.startResult = false
            fixture.controller.startCleaning(mode: mode)

            require(!fixture.controller.isCleaning, "Expected failed shield start to remain idle")
            require(fixture.controller.activeMode == nil, "Expected failed start not to set an active mode")
            require(fixture.controller.appSettings.lastSelectedMode == nil, "Expected failed start not to remember an unused mode")
            require(fixture.shield.stopCallCount == 1, "Expected any partially created shields to be cleaned up")
            require(fixture.keyboard.stopCapturingCallCount == (mode == .screenOnly ? 0 : 1), "Expected failed start to release only attempted capture")
            require(fixture.application.activationCount == 0, "Expected failed start not to activate the app")

            fixture.shield.startResult = true
            fixture.controller.startCleaning(mode: mode)
            require(fixture.controller.isCleaning, "Expected retry after failed shield start to succeed")
            fixture.controller.stopCleaning(trigger: .applicationTerminating)
        }
    }

    private static func verifyRepeatedAndReentrantStop() {
        let fixture = SessionFixture()
        fixture.shield.onStop = { [weak controller = fixture.controller] in
            controller?.stopCleaning(trigger: .escapeKey)
        }
        fixture.controller.startCleaning(mode: .keyboardOnly)
        fixture.controller.stopCleaning(trigger: .button)
        fixture.controller.stopCleaning(trigger: .menuCommand)

        require(fixture.controller.lastExitTrigger == .button, "Expected nested and repeated stops to preserve the original exit")
        require(fixture.shield.stopCallCount == 1, "Expected reentrant shield teardown only once")
        require(fixture.keyboard.stopCapturingCallCount == 1, "Expected reentrant capture teardown only once")
        require(fixture.mainWindow.showAndFocusCallCount == 1, "Expected explicit exit to restore the window only once")
    }

    private static func verifyOldShieldCannotStopNewSession() {
        let fixture = SessionFixture()
        fixture.controller.startCleaning(mode: .wholeMac)
        let oldExit = fixture.shield.exitHandlers[0]
        fixture.controller.stopCleaning(trigger: .button)
        fixture.controller.startCleaning(mode: .screenOnly)

        oldExit(.button)
        require(fixture.controller.activeMode == .screenOnly, "Expected a stale shield callback not to end a new session")
        fixture.shield.exitHandlers[1](.escapeKey)
        require(!fixture.controller.isCleaning, "Expected the current shield callback to end its session")
        require(fixture.controller.lastExitTrigger == .escapeKey, "Expected current shield exit reason")
    }

    private static func verifyRestorePreference() {
        let fixture = SessionFixture()
        fixture.controller.appSettings.reopenMainWindowAfterCleaning = false
        fixture.controller.startCleaning(mode: .keyboardOnly)
        let activationCount = fixture.application.activationCount
        fixture.controller.stopCleaning(trigger: .button)

        require(fixture.mainWindow.showAndFocusCallCount == 0, "Expected explicit exit to respect the restore preference")
        require(fixture.application.activationCount == activationCount, "Expected exit with restore disabled not to reactivate the app")
    }

    private static func verifyObserversDoNotRetainController() {
        let notifications = NotificationCenter()
        let workspaceNotifications = NotificationCenter()
        weak var weakController: CleaningSessionController?
        autoreleasepool {
            let fixture = SessionFixture(notifications: notifications, workspaceNotifications: workspaceNotifications)
            fixture.controller.startCleaning(mode: .screenOnly)
            weakController = fixture.controller
        }
        require(weakController == nil, "Expected lifecycle observers not to retain the controller")
        notifications.post(name: NSApplication.willHideNotification, object: nil)
        workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)
    }

    private static func verifyProtectionStateMatchesCapture() {
        for mode in CleaningMode.allCases {
            for permission in [KeyboardPermissionState.granted, .notDetermined] {
                let fixture = SessionFixture()
                fixture.keyboard.permissionState = permission
                fixture.controller.startCleaning(mode: mode)
                if mode == .keyboardOnly && permission != .granted {
                    require(fixture.controller.activeKeyboardProtection == .none, "Expected no protection to be claimed after an unpermitted start")
                    require(fixture.controller.sessionStartedAt == nil, "Expected no timer for an unstarted session")
                    continue
                }

                let expected: KeyboardProtection = mode == .screenOnly ? .none : (permission == .granted ? .global : .local)
                require(fixture.controller.activeKeyboardProtection == expected, "Expected the UI to describe actual capture scope")
                require(fixture.shield.protectionHistory == [expected], "Expected the shield to display the same protection scope")
                require(fixture.controller.sessionStartedAt != nil, "Expected an active session to have a start time")
                fixture.controller.stopCleaning(trigger: .button)
                require(fixture.controller.activeKeyboardProtection == .none, "Expected protection status to clear after exit")
                require(fixture.controller.sessionStartedAt == nil, "Expected the session timer to clear after exit")
            }
        }
    }

    private static func verifyProtectionLossEndsCleaning() {
        for mode in [CleaningMode.wholeMac, .keyboardOnly] {
            for permissionIsRevoked in [false, true] {
                let fixture = SessionFixture()
                fixture.controller.startCleaning(mode: mode)
                if permissionIsRevoked {
                    fixture.keyboard.permissionState = .denied
                } else {
                    fixture.keyboard.isCapturing = false
                }
                fixture.controller.refreshKeyboardProtectionAvailability()

                require(!fixture.controller.isCleaning, "Expected lost global protection to end cleaning")
                require(fixture.controller.lastExitTrigger == .keyboardProtectionLost, "Expected capture loss to be identified")
                require(fixture.controller.notice == .interrupted(.keyboardProtectionLost), "Expected an explanation after capture loss")
                require(fixture.controller.activeKeyboardProtection == .none, "Expected the UI not to claim protection after capture loss")
                require(fixture.keyboard.stopCapturingCallCount == 1, "Expected capture loss to release all capture resources")
                require(fixture.shield.stopCallCount == 1, "Expected capture loss to remove the screen cover")
                require(fixture.controller.keyboardProtectionAvailability == (permissionIsRevoked ? .needsPermission : .needsRelaunch), "Expected a recovery action matching the failure")
            }
        }

        let fixture = SessionFixture()
        fixture.keyboard.permissionState = .denied
        fixture.controller.startCleaning(mode: .wholeMac)
        fixture.controller.refreshKeyboardProtectionAvailability()
        require(fixture.controller.isCleaning, "Expected local protection not to require a global event tap")
        fixture.controller.stopCleaning(trigger: .applicationTerminating)
    }

    private static func verifyPermissionActionsStayIdleDuringCleaning() {
        let fixture = SessionFixture()
        fixture.keyboard.permissionState = .notDetermined
        fixture.controller.refreshKeyboardProtectionAvailability()
        fixture.controller.startCleaning(mode: .screenOnly)
        fixture.controller.performPrimaryAction(for: .keyboardOnly)
        require(fixture.keyboard.requestPermissionCallCount == 0, "Expected disabled mode actions not to open permission prompts during cleaning")
        require(fixture.controller.activeMode == .screenOnly, "Expected permission actions not to replace the active mode")
        fixture.controller.stopCleaning(trigger: .applicationTerminating)
    }

    private static func verifyFocusLossRespectsProtectionScope() {
        for mode in CleaningMode.allCases {
            for localOnly in [false, true] {
                let fixture = SessionFixture()
                if localOnly { fixture.keyboard.permissionState = .denied }
                if localOnly && mode == .keyboardOnly { continue }
                fixture.controller.startCleaning(mode: mode)
                let activations = fixture.application.activationCount
                fixture.notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
                if localOnly && mode == .wholeMac {
                    require(!fixture.controller.isCleaning, "Expected local protection to end when MacPolish loses focus")
                    require(fixture.controller.notice == .interrupted(.applicationDeactivated), "Expected focus loss to explain the protection limit")
                    require(fixture.mainWindow.showAndFocusCallCount == 0, "Expected focus loss not to reopen the main window")
                    require(fixture.application.activationCount == activations, "Expected focus loss not to steal focus back")
                } else {
                    require(fixture.controller.isCleaning, "Expected screen-only and global protection not to depend on app focus")
                    fixture.controller.stopCleaning(trigger: .button)
                }
            }
        }
    }

    private static func verifySecureInputRecovery() {
        let blocked = SessionFixture(secureInputEnabled: true)
        require(blocked.controller.keyboardProtectionAvailability == .blockedBySecureInput, "Expected Secure Input to be identified on launch")
        require(blocked.controller.keyboardPermissionPrimaryAction == .refreshNow, "Expected a temporary block to offer refresh")
        require(blocked.controller.globalKeyboardPermissionPrimaryAction == .refreshNow, "Expected settings to offer the same recovery")
        require(!blocked.controller.canStartKeyboardOnly, "Expected keyboard cleaning unavailable during Secure Input")
        blocked.controller.startCleaning(mode: .keyboardOnly)
        require(!blocked.controller.isCleaning, "Expected Secure Input to block keyboard cleaning")
        require(blocked.keyboard.startCapturingCallCount == 0, "Expected no capture attempt during Secure Input")
        blocked.controller.startCleaning(mode: .wholeMac)
        require(blocked.controller.activeKeyboardProtection == .local, "Expected WholeMac to expose its local fallback")
        blocked.controller.stopCleaning(trigger: .button)
        blocked.controller.startCleaning(mode: .screenOnly)
        require(blocked.controller.activeMode == .screenOnly, "Expected screen cleaning to remain available")
        blocked.controller.stopCleaning(trigger: .button)

        for mode in [CleaningMode.wholeMac, .keyboardOnly] {
            let fixture = SessionFixture()
            fixture.controller.startCleaning(mode: mode)
            let activations = fixture.application.activationCount
            fixture.keyboard.isSecureInputEnabled = true
            fixture.controller.refreshKeyboardProtectionAvailability()
            require(!fixture.controller.isCleaning, "Expected Secure Input to end global protection")
            require(fixture.controller.lastExitTrigger == .secureInputEnabled, "Expected Secure Input to have its own interruption reason")
            require(fixture.controller.notice == .interrupted(.secureInputEnabled), "Expected an actionable Secure Input explanation")
            require(fixture.mainWindow.showAndFocusCallCount == 0, "Expected no focus stealing during password entry")
            require(fixture.application.activationCount == activations, "Expected Secure Input not to reactivate MacPolish")
            require(fixture.controller.keyboardProtectionAvailability == .blockedBySecureInput, "Expected a temporary block rather than a relaunch request")
            fixture.keyboard.isSecureInputEnabled = false
            fixture.controller.refreshKeyboardProtectionAvailability()
            require(fixture.controller.keyboardProtectionAvailability == .ready, "Expected recovery without relaunch after Secure Input clears")
            fixture.controller.startCleaning(mode: mode)
            require(fixture.controller.activeKeyboardProtection == .global, "Expected the next session to regain global capture")
            fixture.controller.stopCleaning(trigger: .button)
        }

        let race = SessionFixture()
        race.keyboard.onStart = { [keyboard = race.keyboard] in keyboard.isSecureInputEnabled = true }
        race.controller.startCleaning(mode: .keyboardOnly)
        require(!race.controller.isCleaning, "Expected Secure Input enabled during startup to prevent a session")
        require(race.controller.keyboardProtectionAvailability == .blockedBySecureInput, "Expected a startup race to identify the temporary block")
        race.keyboard.onStart = nil
        race.keyboard.isSecureInputEnabled = false
        race.controller.refreshKeyboardProtectionAvailability()
        require(race.controller.keyboardProtectionAvailability == .ready, "Expected a startup race not to leave a false relaunch requirement")
    }

    private static func verifySessionNoticeLifecycle() {
        let fixture = SessionFixture()
        fixture.shield.startResult = false
        fixture.controller.startCleaning(mode: .screenOnly)
        require(fixture.controller.notice == .shieldUnavailable, "Expected a visible recovery message for a failed start")
        fixture.controller.dismissNotice()
        require(fixture.controller.notice == nil, "Expected notices to be dismissible")

        fixture.shield.startResult = true
        fixture.controller.startCleaning(mode: .screenOnly)
        fixture.workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        require(fixture.controller.notice == .interrupted(.systemSleep), "Expected the reason for an automatic exit to be visible")
        fixture.controller.startCleaning(mode: .screenOnly)
        require(fixture.controller.notice == nil, "Expected a successful new session to clear old notices")
        fixture.controller.stopCleaning(trigger: .button)
        require(fixture.controller.notice == nil, "Expected an explicit exit not to show an interruption message")
    }

    private static func verifyDisplayNotificationFiltering() {
        for mode in CleaningMode.allCases {
            let fixture = SessionFixture()
            fixture.controller.startCleaning(mode: mode)
            fixture.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            require(fixture.controller.isCleaning, "Expected status-item notifications without display changes to preserve cleaning")
            fixture.displays.changeGeometry()
            fixture.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            require(!fixture.controller.isCleaning, "Expected actual geometry changes to stop cleaning")
        }
        let a = DisplayConfiguration.Display(identifier: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
        let b = DisplayConfiguration.Display(identifier: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), scale: 1)
        require(DisplayConfiguration(displays: [a, b]) == DisplayConfiguration(displays: [b, a]),
            "Expected display enumeration order not to count as a physical configuration change")
        for replacement in [DisplayConfiguration.Display(identifier: 3, frame: a.frame, scale: a.scale),
                            DisplayConfiguration.Display(identifier: a.identifier, frame: a.frame, scale: 1)] {
            let fixture = SessionFixture()
            fixture.displays.configuration = DisplayConfiguration(displays: [a])
            fixture.controller.startCleaning(mode: .wholeMac)
            fixture.displays.configuration = DisplayConfiguration(displays: [replacement])
            fixture.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            require(fixture.controller.lastExitTrigger == .displayConfigurationChanged, "Expected display identity and scale changes to interrupt")
        }
    }

    private static func verifySpaceChanges() {
        for mode in CleaningMode.allCases {
            let window = SpaceTestWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let fixture = SessionFixture()
            fixture.controller.registerMainWindow(window)
            fixture.controller.startCleaning(mode: mode)
            let activations = fixture.application.activationCount

            // Spaces can change on a different display while the exit window
            // remains on an active Space. That must not interrupt cleaning.
            fixture.workspaceNotifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            require(fixture.controller.isCleaning, "Expected an exit window still on the active Space to preserve cleaning")

            window.belongsToActiveSpace = false
            fixture.workspaceNotifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            if mode == .keyboardOnly {
                require(!fixture.controller.isCleaning && !fixture.keyboard.isCapturing,
                    "Expected leaving the keyboard exit window on another Space to release capture")
                require(fixture.controller.lastExitTrigger == .mainWindowLeftActiveSpace &&
                    fixture.controller.notice == .interrupted(.mainWindowLeftActiveSpace),
                    "Expected a Space interruption to explain why the keyboard became available")
                require(fixture.application.activationCount == activations && !window.isVisible,
                    "Expected a Space interruption not to take focus or reopen the window")
                window.belongsToActiveSpace = true
                fixture.workspaceNotifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
                require(!fixture.controller.isCleaning && fixture.keyboard.startCapturingCallCount == 1,
                    "Expected returning to the old Space not to restart keyboard capture")
            } else {
                require(fixture.controller.isCleaning, "Expected shields that join all Spaces to keep their own exit controls")
                fixture.controller.stopCleaning(trigger: .applicationTerminating)
            }
        }
    }

    private static func verifyLocalProtectionRequiresForeground() {
        for captureFailure in [false, true] {
            let fixture = SessionFixture()
            fixture.application.isActive = false
            if captureFailure {
                fixture.keyboard.startCapturingResult = false
            } else {
                fixture.keyboard.permissionState = .denied
            }
            fixture.controller.startCleaning(mode: .wholeMac)
            require(!fixture.controller.isCleaning && fixture.shield.startCallHistory.isEmpty,
                "Expected unavailable foreground focus to prevent a shield from claiming local keyboard protection")
            require(!fixture.keyboard.isCapturing && fixture.controller.activeKeyboardProtection == .none,
                "Expected a rejected local start not to leave keyboard capture running")
            fixture.application.isActive = true
            fixture.controller.startCleaning(mode: .wholeMac)
            require(fixture.controller.isCleaning && fixture.controller.activeKeyboardProtection == .local,
                "Expected local Whole Mac cleaning to work after returning to the foreground")
            fixture.controller.stopCleaning(trigger: .applicationTerminating)
        }
    }

    private static func verifyMonotonicSessionDuration() {
        for mode in CleaningMode.allCases {
            var wallTime = Date(timeIntervalSinceReferenceDate: 50_000)
            var uptime: TimeInterval = 100
            let controller = CleaningSessionController(
                appSettings: AppSettings(userDefaults: MacPolishVerification.testUserDefaults()),
                screenShieldService: MockScreenShieldService(),
                keyboardCaptureService: MockKeyboardCaptureService(permissionState: .granted),
                applicationController: MockApplicationController(), mainWindowController: MockMainWindowController(),
                dateProvider: { wallTime }, uptimeProvider: { uptime },
                notificationCenter: NotificationCenter(), workspaceNotificationCenter: NotificationCenter())
            require(controller.elapsedCleaningTime == 0, "Expected an idle session to have no elapsed duration")
            controller.startCleaning(mode: mode)
            let originalStart = controller.sessionStartedAt
            wallTime = wallTime.addingTimeInterval(86_400)
            require(controller.elapsedCleaningTime == 0, "Expected a forward wall-clock change not to advance cleaning duration")
            uptime += 90
            wallTime = wallTime.addingTimeInterval(-172_800)
            require(controller.elapsedCleaningTime == 90 && controller.sessionStartedAt == originalStart,
                "Expected backward wall-clock changes to preserve monotonic duration and the original start date")
            controller.stopCleaning(trigger: .applicationTerminating)
            require(controller.elapsedCleaningTime == 0, "Expected stopping to clear the session clock")
            controller.startCleaning(mode: mode)
            require(controller.elapsedCleaningTime == 0, "Expected a new session to start a fresh clock")
            controller.stopCleaning(trigger: .applicationTerminating)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        MacPolishVerification.require(condition(), message)
    }
}

@MainActor
private struct SessionFixture {
    let notifications: NotificationCenter
    let workspaceNotifications: NotificationCenter
    let shield = MockScreenShieldService()
    let keyboard = MockKeyboardCaptureService(permissionState: .granted)
    let application = MockApplicationController()
    let mainWindow = MockMainWindowController()
    let displays = MockDisplayConfiguration()
    let controller: CleaningSessionController

    init(
        notifications: NotificationCenter = NotificationCenter(),
        workspaceNotifications: NotificationCenter = NotificationCenter(),
        secureInputEnabled: Bool = false
    ) {
        self.notifications = notifications
        self.workspaceNotifications = workspaceNotifications
        keyboard.isSecureInputEnabled = secureInputEnabled
        controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: MacPolishVerification.testUserDefaults()),
            screenShieldService: shield,
            keyboardCaptureService: keyboard,
            settingsOpener: MockSettingsOpener(),
            applicationController: application,
            mainWindowController: mainWindow,
            displayConfigurationProvider: { [displays] in displays.configuration },
            notificationCenter: notifications,
            workspaceNotificationCenter: workspaceNotifications
        )
    }
}
