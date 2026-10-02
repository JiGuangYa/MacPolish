import AppKit
import Combine
import MacPolishKit

@MainActor
enum ScreenShieldVerification {
    static func verifyScreenOnlyLaunchClickGuard() async {
        let window = makeWindow(capturesKeyboard: false, exitsOnMouseDown: false)
        defer { window.close() }
        let probe = InputProbeView(frame: window.contentView!.bounds)
        window.contentView = probe
        require(window.makeFirstResponder(probe), "Expected a hidden responder for launch-click verification")
        var exitCount = 0
        window.onExitTrigger = { _ in exitCount += 1 }
        window.armMouseExit()
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            window.sendEvent(mouseEvent(type, window: window, clickCount: 2))
        }
        require(exitCount == 0, "Expected the follow-up click from launching ScreenOnly not to immediately end cleaning")
        require(probe.mouseEvents == 0, "Expected ignored launch clicks not to reach the underlying exit control")

        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        window.sendEvent(escape)
        require(probe.keyboardEvents == 1, "Expected the mouse startup guard to leave ScreenOnly keyboard input available")

        let queuedLaunchClick = mouseEvent(.leftMouseDown, window: window, clickCount: 2)
        EventTrackingRunLoop.run(for: max(0.45, NSEvent.doubleClickInterval) + 0.15)
        window.sendEvent(queuedLaunchClick)
        require(exitCount == 0, "Expected a launch click queued until after the guard not to end cleaning")
        for type in [NSEvent.EventType.leftMouseUp, .rightMouseUp, .otherMouseUp] {
            window.sendEvent(mouseEvent(type, window: window))
        }
        require(exitCount == 0 && probe.mouseEvents == 0,
            "Expected releasing an ignored launch click after the guard to stay consumed")
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            window.sendEvent(mouseEvent(type, window: window))
        }
        require(exitCount == 3, "Expected a fresh click with any mouse button to finish ScreenOnly after the startup guard")

        window.armMouseExit(after: 0.12)
        window.sendEvent(mouseEvent(.leftMouseDown, window: window))
        require(exitCount == 3, "Expected rearming a shield to begin a fresh launch-click guard")
        EventTrackingRunLoop.run(for: 0.25)
        window.sendEvent(mouseEvent(.leftMouseDown, window: window))
        require(exitCount == 4, "Expected a rearmed shield to accept a fresh exit click")
        require(!window.isVisible, "Expected launch-click verification to keep its window hidden")
    }

    private static func mouseEvent(_ type: NSEvent.EventType, window: NSWindow, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clickCount, pressure: 1)!
    }

    static func verifyNativeWindowInput() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let wholeMac = makeWindow(capturesKeyboard: true, exitsOnMouseDown: false)
        let probe = InputProbeView(frame: wholeMac.contentView!.bounds)
        wholeMac.contentView = probe
        require(wholeMac.makeFirstResponder(probe), "Expected the event probe to be the shield's content responder")
        var exits: [ExitTrigger] = []
        wholeMac.onExitTrigger = { exits.append($0) }
        require(wholeMac.canBecomeKey && wholeMac.canBecomeMain, "Expected WholeMac's window to accept keyboard focus")

        for type in [NSEvent.EventType.keyDown, .keyUp, .flagsChanged] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: wholeMac.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
            wholeMac.sendEvent(event)
        }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: wholeMac.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        wholeMac.sendEvent(escape)
        require(wholeMac.performKeyEquivalent(with: escape), "Expected native keyboard shortcuts to be consumed")
        wholeMac.cancelOperation(nil)
        let media = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: wholeMac.windowNumber, context: nil, subtype: 8, data1: 0, data2: -1)!
        wholeMac.sendEvent(media)
        require(probe.keyboardEvents == 0, "Expected native shield input never to reach the content responder")
        require(exits.isEmpty, "Expected Escape and cancel not to exit keyboard-protected cleaning")
        require(!wholeMac.isVisible, "Expected native event verification to keep its window hidden")
        wholeMac.close()

        let screenOnly = makeWindow(capturesKeyboard: false, exitsOnMouseDown: true)
        require(!screenOnly.canBecomeKey && !screenOnly.canBecomeMain, "Expected ScreenOnly not to steal keyboard focus")
        screenOnly.onExitTrigger = { exits.append($0) }
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let click = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: screenOnly.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            screenOnly.sendEvent(click)
        }
        require(exits == [.button, .button, .button], "Expected any mouse button to finish ScreenOnly")
        require(!screenOnly.isVisible, "Expected ScreenOnly verification never to show a desktop window")
        screenOnly.close()

        let unprotected = makeWindow(capturesKeyboard: false, exitsOnMouseDown: false)
        let receivingProbe = InputProbeView(frame: unprotected.contentView!.bounds)
        unprotected.contentView = receivingProbe
        require(unprotected.makeFirstResponder(receivingProbe), "Expected a responder for the noncapturing comparison")
        let ordinaryKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: unprotected.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        unprotected.sendEvent(ordinaryKey)
        require(receivingProbe.keyboardEvents == 1, "Expected an unprotected window to deliver keys to its responder")
        require(!unprotected.isVisible, "Expected the input comparison to keep its window hidden")
        unprotected.close()

        // This AppKit convenience initializer previously trapped when the
        // subclass omitted the designated initializer it calls internally.
        let screenInitializer = ShieldWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false, screen: nil)
        screenInitializer.isReleasedWhenClosed = false
        require(!screenInitializer.capturesKeyboard, "Expected the AppKit initializer to construct a valid neutral window")
        screenInitializer.close()
    }

    static func verifyPresentationLifecycle() async {
        let settings = AppSettings(userDefaults: MacPolishVerification.testUserDefaults())
        settings.controlFadeDelay = 1.5
        let model = ShieldPresentationModel(appSettings: settings, reduceMotion: true,
            assistiveTechnologyEnabled: Just(false).eraseToAnyPublisher())
        model.startPresentationCycle()
        require(model.showsChrome && model.showsHint, "Expected cleaning controls and guidance at the start")
        try? await Task.sleep(nanoseconds: 400_000_000)
        model.registerInteraction()
        try? await Task.sleep(nanoseconds: 950_000_000)
        require(model.showsHint, "Expected pointer activity to cancel an earlier hint dismissal")
        try? await Task.sleep(nanoseconds: 650_000_000)
        require(!model.showsChrome && !model.showsHint, "Expected inactive controls to fade")

        model.registerInteraction()
        settings.revealControlsOnPointerMovement = false
        drainSettingsDelivery()
        try? await Task.sleep(nanoseconds: 1_650_000_000)
        require(model.showsChrome && model.showsHint, "Expected always-visible controls to cancel both dismissal timers")
        settings.revealControlsOnPointerMovement = true
        drainSettingsDelivery()
        try? await Task.sleep(nanoseconds: 1_650_000_000)
        require(!model.showsChrome, "Expected reenabling automatic fade to restart its timer")

        settings.controlFadeDelay = 5
        drainSettingsDelivery()
        settings.controlFadeDelay = 1.5
        settings.showExitHints = false
        drainSettingsDelivery()
        require(model.showsChrome && !model.showsHint, "Expected disabling hints to preserve the exit control")
        try? await Task.sleep(nanoseconds: 1_650_000_000)
        require(!model.showsChrome, "Expected changes to fade timing to apply to the active session")

        model.registerInteraction()
        model.stopPresentationCycle()
        settings.showExitHints = true
        drainSettingsDelivery()
        try? await Task.sleep(nanoseconds: 1_650_000_000)
        require(model.showsChrome && !model.showsHint, "Expected stopped presentation to ignore settings and pending timers")
        weak var weakModel: ShieldPresentationModel?
        autoreleasepool {
            let temporary = ShieldPresentationModel(appSettings: settings, reduceMotion: true,
                assistiveTechnologyEnabled: Just(false).eraseToAnyPublisher())
            temporary.startPresentationCycle()
            weakModel = temporary
        }
        require(weakModel == nil, "Expected settings subscriptions and dismissal tasks not to retain presentation state")
    }

    static func verifyShieldWindowGeometry() async {
        let settings = AppSettings(userDefaults: MacPolishVerification.testUserDefaults())
        for frame in [NSRect(x: 0, y: 0, width: 560, height: 320),
                      NSRect(x: -1_440, y: 200, width: 800, height: 450),
                      NSRect(x: 1_920, y: -800, width: 640, height: 360)] {
            let model = ShieldPresentationModel(appSettings: settings, reduceMotion: true,
                assistiveTechnologyEnabled: Just(true).eraseToAnyPublisher())
            let window = ShieldWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered,
                defer: false, capturesKeyboard: true, exitsOnMouseDown: false)
            window.isReleasedWhenClosed = false
            let content = ShieldHostingView(rootView: ShieldContentView(model: model,
                emergencyExitGesture: EmergencyExitGesture(), mode: .wholeMac, keyboardProtection: .local, onExit: { }))
            content.frame = NSRect(origin: .zero, size: frame.size)
            window.contentView = content
            window.setFrame(frame, display: false)
            model.startPresentationCycle()
            content.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(150))
            content.layoutSubtreeIfNeeded()
            require(window.frame == frame && content.frame == NSRect(origin: .zero, size: frame.size),
                "Expected shield content to preserve screen-sized window bounds, including negative display origins")
            require(content.acceptsFirstMouse(for: nil), "Expected the native shield to accept its first exit click")
            require(!window.isVisible, "Expected geometry verification not to cover the desktop")
            model.stopPresentationCycle()
            window.close()
        }
    }

    static func verifyAccessibleExitPresentation() async {
        var systemAccessibility: Bool?
        let observation = ShieldPresentationModel.systemAssistiveTechnologyEnabled.sink { systemAccessibility = $0 }
        require(systemAccessibility == (NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled),
            "Expected the native accessibility observer to publish the current state without changing system preferences")
        observation.cancel()
        let settings = AppSettings(userDefaults: MacPolishVerification.testUserDefaults())
        settings.controlFadeDelay = 1.5
        let assistiveTechnology = CurrentValueSubject<Bool, Never>(true)
        let model = ShieldPresentationModel(appSettings: settings, reduceMotion: true,
            assistiveTechnologyEnabled: assistiveTechnology.eraseToAnyPublisher())
        model.startPresentationCycle()
        drainSettingsDelivery()
        try? await Task.sleep(for: .milliseconds(1_650))
        require(model.showsChrome && model.showsHint,
            "Expected an assistive technology active at startup to preserve the exit control and enabled guidance")

        assistiveTechnology.send(false)
        drainSettingsDelivery()
        require(model.showsChrome, "Expected disabling assistive technology to begin a fresh fade delay")
        try? await Task.sleep(for: .milliseconds(1_650))
        require(!model.showsChrome && !model.showsHint, "Expected normal fade behavior after assistive technology ends")
        assistiveTechnology.send(true)
        drainSettingsDelivery()
        require(model.showsChrome && model.showsHint, "Expected enabling assistive technology to restore an already-hidden exit control")

        settings.showExitHints = false
        drainSettingsDelivery()
        model.registerInteraction()
        try? await Task.sleep(for: .milliseconds(1_650))
        require(model.showsChrome && !model.showsHint,
            "Expected persistent accessible exit controls to respect disabled hints")
        require(settings.revealControlsOnPointerMovement && settings.clampedFadeDelay == 1.5,
            "Expected accessibility behavior to preserve the user's automatic-fade preference and delay")

        assistiveTechnology.send(false)
        drainSettingsDelivery()
        try? await Task.sleep(for: .milliseconds(800))
        assistiveTechnology.send(true)
        drainSettingsDelivery()
        try? await Task.sleep(for: .milliseconds(850))
        require(model.showsChrome, "Expected enabling assistive technology to cancel the pending fade")

        model.stopPresentationCycle()
        assistiveTechnology.send(false)
        drainSettingsDelivery()
        try? await Task.sleep(for: .milliseconds(1_650))
        require(model.showsChrome, "Expected a stopped shield not to schedule new fades from accessibility changes")
        model.startPresentationCycle()
        try? await Task.sleep(for: .milliseconds(1_650))
        require(!model.showsChrome, "Expected restarting a shield to use the latest accessibility state")
        model.stopPresentationCycle()

        weak var weakModel: ShieldPresentationModel?
        autoreleasepool {
            let temporary = ShieldPresentationModel(appSettings: settings, reduceMotion: true,
                assistiveTechnologyEnabled: assistiveTechnology.eraseToAnyPublisher())
            temporary.startPresentationCycle()
            weakModel = temporary
        }
        assistiveTechnology.send(true)
        drainSettingsDelivery()
        require(weakModel == nil, "Expected accessibility subscriptions not to retain dismissed shields")
    }

    private static func makeWindow(capturesKeyboard: Bool, exitsOnMouseDown: Bool) -> ShieldWindow {
        let window = ShieldWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
            backing: .buffered, defer: false, capturesKeyboard: capturesKeyboard, exitsOnMouseDown: exitsOnMouseDown)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func drainSettingsDelivery() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        MacPolishVerification.require(condition(), message)
    }
}

@MainActor
private final class InputProbeView: NSView {
    var keyboardEvents = 0
    var mouseEvents = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keyboardEvents += 1 }
    override func keyUp(with event: NSEvent) { keyboardEvents += 1 }
    override func flagsChanged(with event: NSEvent) { keyboardEvents += 1 }
    override func mouseDown(with event: NSEvent) { mouseEvents += 1 }
    override func mouseUp(with event: NSEvent) { mouseEvents += 1 }
    override func rightMouseDown(with event: NSEvent) { mouseEvents += 1 }
    override func rightMouseUp(with event: NSEvent) { mouseEvents += 1 }
    override func otherMouseDown(with event: NSEvent) { mouseEvents += 1 }
    override func otherMouseUp(with event: NSEvent) { mouseEvents += 1 }
}
