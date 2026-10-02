import AppKit
import MacPolishKit

@MainActor
enum EmergencyExitVerification {
    private static let pressed = EmergencyExitInput.escapeChanged(isDown: true, isRepeat: false, modifiersHeld: true)

    static func run() {
        verifyContinuousHold()
        verifyCancellation()
        verifySessionRouting()
        verifyLocalWindowRouting()
        verifyLifetime()
    }

    static func verifyScheduledHold() async {
        let gesture = EmergencyExitGesture(holdDuration: 0.12)
        var exits = 0
        gesture.start { exits += 1 }
        gesture.handle(pressed)
        try? await Task.sleep(for: .milliseconds(300))
        require(exits == 1 && !gesture.isHolding, "Expected the live timer to finish a continuous hold once")

        gesture.start { exits += 1 }
        gesture.handle(pressed)
        gesture.handle(.modifiersChanged(held: false))
        try? await Task.sleep(for: .milliseconds(200))
        require(exits == 1, "Expected releasing a modifier to cancel the scheduled exit")
        gesture.stop()

        gesture.start { exits += 1 }
        gesture.handle(pressed)
        // Allow the asynchronous timer to begin before entering the nested
        // run-loop mode that AppKit uses while tracking a menu or a control.
        try? await Task.sleep(for: .milliseconds(20))
        EventTrackingRunLoop.run(for: 0.3)
        require(exits == 2 && !gesture.isHolding,
            "Expected emergency exit to complete while AppKit is tracking a menu or control")
        gesture.stop()

        for cancellation in [
            EmergencyExitInput.escapeChanged(isDown: false, isRepeat: false, modifiersHeld: true),
            .modifiersChanged(held: false), .reset
        ] {
            gesture.start { exits += 1 }
            gesture.handle(pressed)
            gesture.handle(cancellation)
            EventTrackingRunLoop.run(for: 0.2)
            require(exits == 2 && !gesture.isHolding, "Expected interrupted holds to stay cancelled during event tracking")
            gesture.stop()
        }

        gesture.start { exits += 1 }
        gesture.handle(pressed)
        gesture.stop()
        EventTrackingRunLoop.run(for: 0.2)
        require(exits == 2 && !gesture.isHolding, "Expected ending a session to cancel its tracking-mode exit timer")

        weak var released: EmergencyExitGesture?
        autoreleasepool {
            let temporary = EmergencyExitGesture(holdDuration: 0.12)
            temporary.start { exits += 1 }
            temporary.handle(pressed)
            released = temporary
        }
        require(released == nil, "Expected an active common-mode timer not to retain the gesture")
        EventTrackingRunLoop.run(for: 0.2)
        require(exits == 2, "Expected a released gesture never to exit a later session")

        gesture.start { exits += 1 }
        gesture.handle(pressed)
        EventTrackingRunLoop.run(for: 0.3)
        require(exits == 3 && !gesture.isHolding, "Expected a new hold to work after tracking-mode cancellations")
    }

    private static func verifyContinuousHold() {
        let clock = GestureClock()
        let gesture = EmergencyExitGesture(holdDuration: 3, uptime: { clock.now })
        var exits = 0
        gesture.handle(pressed)
        require(!gesture.isHolding, "Expected idle sessions to ignore the shortcut")
        gesture.start { exits += 1 }
        gesture.handle(.escapeChanged(isDown: true, isRepeat: true, modifiersHeld: true))
        require(!gesture.isHolding, "Expected a key held before startup not to arm exit through repeats")
        gesture.handle(.escapeChanged(isDown: true, isRepeat: false, modifiersHeld: false))
        require(!gesture.isHolding, "Expected ordinary Escape to stay blocked without starting exit")
        gesture.handle(.modifiersChanged(held: true))
        require(gesture.isHolding && gesture.remainingSeconds == 3, "Expected either key order to start the full countdown")
        clock.now = 1.5
        gesture.handle(.escapeChanged(isDown: true, isRepeat: true, modifiersHeld: true))
        gesture.updateProgress()
        require(gesture.progress == 0.5 && gesture.remainingSeconds == 2, "Expected repeated Escape not to restart the hold")
        clock.now = 2.999
        gesture.updateProgress()
        require(exits == 0 && gesture.remainingSeconds == 1, "Expected no exit before three complete seconds")
        clock.now = 3
        gesture.updateProgress()
        require(exits == 1 && !gesture.isHolding, "Expected three seconds to finish and clear progress")
        gesture.handle(pressed)
        clock.now = 10
        gesture.updateProgress()
        require(exits == 1, "Expected held keys not to trigger a second exit")
    }

    private static func verifyCancellation() {
        let cancellations: [EmergencyExitInput] = [
            .escapeChanged(isDown: false, isRepeat: false, modifiersHeld: true),
            .modifiersChanged(held: false), .reset
        ]
        for cancellation in cancellations {
            let clock = GestureClock()
            let gesture = EmergencyExitGesture(holdDuration: 3, uptime: { clock.now })
            var exits = 0
            gesture.start { exits += 1 }
            gesture.handle(pressed)
            clock.now = 2.9
            gesture.updateProgress()
            gesture.handle(cancellation)
            require(!gesture.isHolding, "Expected every interrupted chord to cancel its countdown")
            clock.now = 4
            gesture.updateProgress()
            require(exits == 0, "Expected cancelled time not to complete an exit")
            gesture.handle(pressed)
            clock.now = 6.9
            gesture.updateProgress()
            require(exits == 0, "Expected a new hold to require three fresh seconds")
            clock.now = 7
            gesture.updateProgress()
            require(exits == 1, "Expected a fresh continuous hold to finish")
        }
    }

    private static func verifySessionRouting() {
        for mode in [CleaningMode.wholeMac, .keyboardOnly] {
            let fixture = GestureSessionFixture()
            fixture.controller.startCleaning(mode: mode)
            fixture.keyboard.emergencyInputHandlers[0](pressed)
            fixture.clock.now = 3
            fixture.gesture.updateProgress()
            require(!fixture.controller.isCleaning && fixture.controller.lastExitTrigger == .emergencyShortcut,
                "Expected the global shortcut to finish protected cleaning")
            require(fixture.keyboard.stopCapturingCallCount == 1 && fixture.shield.stopCallCount == 1,
                "Expected shortcut exit to release keyboard and display protection")
            require(fixture.window.showAndFocusCallCount == 1 && fixture.controller.notice == nil,
                "Expected intentional shortcut exit to restore the window without an interruption notice")

            fixture.controller.startCleaning(mode: mode)
            fixture.keyboard.emergencyInputHandlers[0](pressed)
            require(!fixture.gesture.isHolding, "Expected an old capture handler not to arm a new session")
            fixture.keyboard.emergencyInputHandlers[1](pressed)
            fixture.clock.now = 4
            fixture.gesture.updateProgress()
            fixture.controller.stopCleaning(trigger: .button)
            fixture.clock.now = 10
            fixture.gesture.updateProgress()
            require(fixture.controller.lastExitTrigger == .button && !fixture.gesture.isHolding,
                "Expected a mouse exit to cancel pending keyboard exit")

            fixture.controller.startCleaning(mode: .screenOnly)
            fixture.gesture.handle(pressed)
            require(!fixture.gesture.isHolding, "Expected ScreenOnly to retain its ordinary exit behavior")
            fixture.controller.stopCleaning(trigger: .button)
        }

        let failed = GestureSessionFixture()
        failed.shield.startResult = false
        failed.controller.startCleaning(mode: .wholeMac)
        failed.keyboard.emergencyInputHandlers[0](pressed)
        require(!failed.gesture.isHolding && !failed.controller.isCleaning, "Expected startup rollback never to arm emergency exit")
    }

    private static func verifyLocalWindowRouting() {
        let fixture = GestureSessionFixture(permission: .denied)
        fixture.controller.startCleaning(mode: .wholeMac)
        require(fixture.controller.activeKeyboardProtection == .local, "Expected the local-protection route")
        let window = ShieldWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
            backing: .buffered, defer: false, capturesKeyboard: true, exitsOnMouseDown: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.onEmergencyInput = { fixture.gesture.handle($0) }
        let escape = keyEvent(.keyDown, flags: [.control, .option, .capsLock], window: window)
        window.sendEvent(escape)
        require(fixture.gesture.isHolding, "Expected local Escape with Control and Option to start exit, ignoring Caps Lock")
        window.sendEvent(keyEvent(.flagsChanged, flags: [.control, .option, .command], window: window))
        require(!fixture.gesture.isHolding, "Expected extra Command to cancel the chord")
        require(window.performKeyEquivalent(with: escape), "Expected local shortcut dispatch to remain consumed")
        require(fixture.gesture.isHolding, "Expected key-equivalent dispatch to feed the same gesture")
        window.sendEvent(keyEvent(.keyUp, flags: [.control, .option], window: window))
        require(!fixture.gesture.isHolding, "Expected local Escape release to cancel exit")
        window.sendEvent(escape)
        fixture.clock.now = 3
        fixture.gesture.updateProgress()
        require(fixture.controller.lastExitTrigger == .emergencyShortcut, "Expected local hold to finish without global permission")
        require(!window.isVisible, "Expected keyboard routing verification never to show a desktop window")
    }

    private static func verifyLifetime() {
        weak var released: EmergencyExitGesture?
        autoreleasepool {
            let gesture = EmergencyExitGesture()
            gesture.start { }
            gesture.handle(pressed)
            released = gesture
        }
        require(released == nil, "Expected the hold timer not to retain its gesture")
    }

    private static func keyEvent(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        MacPolishVerification.require(condition(), message)
    }
}

private final class GestureClock { var now: TimeInterval = 0 }

@MainActor
private struct GestureSessionFixture {
    let clock = GestureClock()
    let gesture: EmergencyExitGesture
    let keyboard: MockKeyboardCaptureService
    let shield = MockScreenShieldService()
    let window = MockMainWindowController()
    let controller: CleaningSessionController

    init(permission: KeyboardPermissionState = .granted) {
        gesture = EmergencyExitGesture(holdDuration: 3, uptime: { [clock] in clock.now })
        keyboard = MockKeyboardCaptureService(permissionState: permission)
        controller = CleaningSessionController(appSettings: AppSettings(userDefaults: MacPolishVerification.testUserDefaults()),
            emergencyExitGesture: gesture, screenShieldService: shield, keyboardCaptureService: keyboard,
            settingsOpener: MockSettingsOpener(), applicationController: MockApplicationController(), mainWindowController: window,
            notificationCenter: NotificationCenter(), workspaceNotificationCenter: NotificationCenter())
    }
}
