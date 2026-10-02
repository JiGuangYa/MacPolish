import CoreGraphics
import Foundation
import MacPolishKit

/// Exercises the production capture service with real, unposted CGEvent values.
/// Permission checks and the native tap allocation are the only substitutes.
@MainActor
enum KeyboardCaptureVerification {
    static func run() {
        verifyPermissionPreflight()
        verifyEventFiltering()
        verifyEmergencyInputRouting()
        verifySecureInputAndScreenOnly()
        verifyTapCreationFailures()
        verifyDisabledTapRecovery()
        verifyOldCallbacksAreHarmless()
        verifyServiceRelease()
    }

    private static func verifyPermissionPreflight() {
        let defaults = MacPolishVerification.testUserDefaults()
        let access = TestKeyboardAccess()
        let factory = TestKeyboardEventTapFactory()
        let service = SystemKeyboardCaptureService(userDefaults: defaults, access: access, tapFactory: factory)
        require(service.permissionState == .notDetermined, "Expected a fresh install to have no permission request")
        require(!service.probeCaptureAvailability(), "Expected untrusted preflight to fail")
        require(!service.startCapturing(for: .keyboardOnly), "Expected untrusted capture to fail")
        require(factory.handlers.isEmpty, "Expected no event tap without permission")

        require(service.requestPermission() == .denied, "Expected an ungranted request to remain unavailable")
        require(access.requestCount == 1, "Expected one permission prompt")
        let nextService = SystemKeyboardCaptureService(userDefaults: defaults, access: access, tapFactory: factory)
        require(nextService.permissionState == .denied, "Expected the permission request to persist across launches")
        access.isTrusted = true
        require(service.probeCaptureAvailability(), "Expected newly granted permission to be recognized")
        require(service.permissionState == .granted, "Expected preflight to update permission state")
        access.isSecureInputEnabled = true
        require(!service.probeCaptureAvailability(), "Expected Secure Input to block preflight despite permission")
        require(factory.handlers.isEmpty, "Expected permission prompts and preflight never to install a tap")
    }

    private static func verifyEventFiltering() {
        for mode in [CleaningMode.wholeMac, .keyboardOnly] {
            let fixture = CaptureFixture()
            require(fixture.service.startCapturing(for: mode), "Expected a permitted capture session to start")
            require(fixture.service.isCapturing, "Expected capture only after the tap is enabled")
            let handler = fixture.factory.handlers[0]
            let keyboardTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, CGEventType(rawValue: 14)!]
            let expectedMask = keyboardTypes.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << Int($1.rawValue) }
            require(fixture.factory.masks == [expectedMask], "Expected only key, modifier, and media events in the tap mask")

            for type in keyboardTypes {
                let event = CGEvent(source: nil)!
                event.type = type
                require(handler(type, event) == nil, "Expected \(type) to be blocked during \(mode)")
            }
            // Escape and system shortcuts are keyboard events too; neither
            // should bypass WholeMac or KeyboardOnly capture.
            for keyCode: CGKeyCode in [0, 53] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
                event.flags = [.maskCommand, .maskAlternate, .maskControl]
                require(handler(.keyDown, event) == nil, "Expected shortcuts and Escape to remain blocked")
            }
            for type in [CGEventType.leftMouseDown, .leftMouseUp, .mouseMoved, .scrollWheel] {
                let event = CGEvent(source: nil)!
                event.type = type
                require(passesOriginal(handler(type, event), event), "Expected mouse and scroll events to pass through")
            }
            require(fixture.service.startCapturing(for: mode), "Expected repeated starts to preserve capture")
            require(fixture.factory.handlers.count == 1, "Expected repeated starts not to allocate another tap")
            fixture.service.stopCapturing()
            fixture.service.stopCapturing()
            require(fixture.factory.records[0].invalidationCount == 1, "Expected tap invalidation exactly once")
            require(!fixture.service.isCapturing, "Expected stop to clear capture status")
        }
    }

    private static func verifySecureInputAndScreenOnly() {
        let fixture = CaptureFixture()
        fixture.access.isSecureInputEnabled = true
        require(!fixture.service.startCapturing(for: .keyboardOnly), "Expected Secure Input to prevent capture")
        require(fixture.factory.handlers.isEmpty, "Expected no tap while Secure Input is enabled")
        fixture.access.isSecureInputEnabled = false
        require(!fixture.service.startCapturing(for: .screenOnly), "Expected screen cleaning never to capture keyboard events")
        require(fixture.factory.handlers.isEmpty, "Expected ScreenOnly not to allocate a tap")

        require(fixture.service.startCapturing(for: .wholeMac), "Expected capture after Secure Input clears")
        fixture.access.isSecureInputEnabled = true
        require(!fixture.service.isCapturing, "Expected an enabled tap not to claim protection during Secure Input")
        fixture.access.isSecureInputEnabled = false
        require(!fixture.service.startCapturing(for: .screenOnly), "Expected switching to screen-only to stop keyboard capture")
        require(fixture.factory.records[0].invalidationCount == 1, "Expected screen-only transition to release the old tap")

        let race = CaptureFixture()
        race.factory.onMake = { [access = race.access] in access.isSecureInputEnabled = true }
        require(!race.service.startCapturing(for: .keyboardOnly), "Expected Secure Input during startup to roll back capture")
        require(race.factory.records[0].invalidationCount == 1, "Expected a failed startup to release its tap")
        race.factory.onMake = nil
    }

    private static func verifyEmergencyInputRouting() {
        let fixture = CaptureFixture()
        var inputs: [EmergencyExitInput] = []
        require(fixture.service.startCapturing(for: .keyboardOnly, onEmergencyInput: { inputs.append($0) }), "Expected capture with emergency input")
        let handler = fixture.factory.handlers[0]
        let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
        escape.flags = [.maskControl, .maskAlternate, .maskAlphaShift, .maskSecondaryFn]
        require(handler(.keyDown, escape) == nil, "Expected the exit chord to remain swallowed")
        require(inputs == [.escapeChanged(isDown: true, isRepeat: false, modifiersHeld: true)], "Expected only Control and Option as required modifiers")
        escape.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        require(handler(.keyDown, escape) == nil, "Expected repeated exit keys to remain swallowed")
        require(inputs.last == .escapeChanged(isDown: true, isRepeat: true, modifiersHeld: true), "Expected repeat information to reach the gesture")
        escape.flags.insert(.maskShift)
        _ = handler(.flagsChanged, escape)
        require(inputs.last == .modifiersChanged(held: false), "Expected an extra Shift to invalidate the chord")
        _ = handler(.keyUp, escape)
        require(inputs.last == .escapeChanged(isDown: false, isRepeat: false, modifiersHeld: false), "Expected Escape release to cancel the hold")

        let otherKey = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        for type in [CGEventType.keyDown, CGEventType(rawValue: 14)!, .tapDisabledByTimeout, .tapDisabledByUserInput] {
            _ = handler(type, otherKey)
            require(inputs.last == .reset, "Expected unrelated input and tap interruptions to cancel the hold")
        }
        fixture.service.stopCapturing()
        require(inputs.last == .reset, "Expected stop to cancel a hold before releasing capture")
        let oldCount = inputs.count
        var newInputs: [EmergencyExitInput] = []
        require(fixture.service.startCapturing(for: .wholeMac, onEmergencyInput: { newInputs.append($0) }), "Expected a new callback on restart")
        _ = handler(.keyDown, escape)
        require(inputs.count == oldCount && newInputs.isEmpty, "Expected stale taps not to deliver gesture input")
        _ = fixture.factory.handlers[1](.keyDown, escape)
        require(newInputs.count == 1, "Expected current capture to deliver to the new callback")
        fixture.service.stopCapturing()
    }

    private static func verifyTapCreationFailures() {
        let fixture = CaptureFixture()
        fixture.factory.creationSucceeds = false
        require(!fixture.service.startCapturing(for: .keyboardOnly), "Expected native allocation failure to stop startup")
        require(!fixture.service.isCapturing, "Expected no capture after allocation failure")
        let event = CGEvent(source: nil)!
        require(passesOriginal(fixture.factory.handlers[0](.keyDown, event), event), "Expected a failed tap's handler not to block input")

        fixture.factory.creationSucceeds = true
        fixture.factory.enableSucceeds = false
        require(!fixture.service.startCapturing(for: .keyboardOnly), "Expected enable failure to stop startup")
        require(fixture.factory.records[0].invalidationCount == 1, "Expected enable failure to release resources")
        fixture.factory.enableSucceeds = true
        require(fixture.service.startCapturing(for: .keyboardOnly), "Expected a later capture attempt to recover")
        fixture.service.stopCapturing()
    }

    private static func verifyDisabledTapRecovery() {
        for disabledType in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            for interruption in ["none", "permission", "secure", "enable-failure"] {
                let fixture = CaptureFixture()
                require(fixture.service.startCapturing(for: .keyboardOnly), "Expected initial capture")
                let record = fixture.factory.records[0]
                record.enabled = false
                if interruption == "permission" { fixture.access.isTrusted = false }
                if interruption == "secure" { fixture.access.isSecureInputEnabled = true }
                if interruption == "enable-failure" { record.enableSucceeds = false }
                let event = CGEvent(source: nil)!
                require(passesOriginal(fixture.factory.handlers[0](disabledType, event), event), "Expected disabled-tap notifications to pass through")
                let shouldAttemptRecovery = interruption == "none" || interruption == "enable-failure"
                require(record.enableCount == (shouldAttemptRecovery ? 2 : 1), "Expected recovery only with permission and without Secure Input")
                require(fixture.service.isCapturing == (interruption == "none"), "Expected capture status to reflect successful recovery")
                fixture.service.stopCapturing()
            }
        }
    }

    private static func verifyOldCallbacksAreHarmless() {
        let fixture = CaptureFixture()
        require(fixture.service.startCapturing(for: .keyboardOnly), "Expected first capture")
        let oldHandler = fixture.factory.handlers[0]
        let event = CGEvent(source: nil)!
        fixture.service.stopCapturing()
        require(passesOriginal(oldHandler(.keyDown, event), event), "Expected stopped handlers to pass input")
        require(fixture.service.startCapturing(for: .wholeMac), "Expected a new capture session")
        let record = fixture.factory.records[1]
        require(passesOriginal(oldHandler(.keyDown, event), event), "Expected an old handler not to block a new session's input")
        require(passesOriginal(oldHandler(.tapDisabledByTimeout, event), event), "Expected old recovery callbacks to be ignored")
        require(record.enableCount == 1, "Expected old recovery callbacks not to touch the new tap")
        require(fixture.factory.handlers[1](.keyDown, event) == nil, "Expected the current session to keep blocking keys")
        fixture.service.stopCapturing()
    }

    private static func verifyServiceRelease() {
        let access = TestKeyboardAccess()
        access.isTrusted = true
        let factory = TestKeyboardEventTapFactory()
        weak var weakService: SystemKeyboardCaptureService?
        autoreleasepool {
            let service = SystemKeyboardCaptureService(userDefaults: MacPolishVerification.testUserDefaults(), access: access, tapFactory: factory)
            require(service.startCapturing(for: .keyboardOnly), "Expected capture before releasing the service")
            weakService = service
        }
        require(weakService == nil, "Expected retained event handlers not to retain their service")
        require(factory.lastTap == nil, "Expected releasing the service to release its native resource owner")
        require(factory.records[0].invalidationCount == 1, "Expected resource destruction to invalidate capture")
        let event = CGEvent(source: nil)!
        require(passesOriginal(factory.handlers[0](.keyDown, event), event), "Expected callbacks after destruction to pass input safely")
    }

    private static func passesOriginal(_ result: Unmanaged<CGEvent>?, _ event: CGEvent) -> Bool {
        result?.toOpaque() == Unmanaged.passUnretained(event).toOpaque()
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        MacPolishVerification.require(condition(), message)
    }
}

@MainActor
private struct CaptureFixture {
    let access = TestKeyboardAccess()
    let factory = TestKeyboardEventTapFactory()
    let service: SystemKeyboardCaptureService

    init() {
        access.isTrusted = true
        service = SystemKeyboardCaptureService(userDefaults: MacPolishVerification.testUserDefaults(), access: access, tapFactory: factory)
    }
}

@MainActor
private final class TestKeyboardAccess: KeyboardAccessChecking {
    var isTrusted = false
    var isSecureInputEnabled = false
    var requestCount = 0
    func requestAccess() { requestCount += 1 }
}

@MainActor
private final class TestKeyboardEventTapFactory: KeyboardEventTapCreating {
    var creationSucceeds = true
    var enableSucceeds = true
    var onMake: (() -> Void)?
    var handlers: [KeyboardEventHandler] = []
    var masks: [CGEventMask] = []
    var records: [TapLifetimeRecord] = []
    weak var lastTap: TestKeyboardEventTap?

    func makeTap(eventsOfInterest: CGEventMask, handler: @escaping KeyboardEventHandler) -> (any KeyboardEventTap)? {
        handlers.append(handler)
        masks.append(eventsOfInterest)
        onMake?()
        guard creationSucceeds else { return nil }
        let record = TapLifetimeRecord()
        record.enableSucceeds = enableSucceeds
        records.append(record)
        let tap = TestKeyboardEventTap(record: record)
        lastTap = tap
        return tap
    }
}

private final class TapLifetimeRecord {
    var enabled = false
    var enableSucceeds = true
    var enableCount = 0
    var invalidationCount = 0
}

private final class TestKeyboardEventTap: KeyboardEventTap {
    let record: TapLifetimeRecord
    var isEnabled: Bool { record.enabled && record.invalidationCount == 0 }

    init(record: TapLifetimeRecord) { self.record = record }

    func enable() {
        guard record.invalidationCount == 0 else { return }
        record.enableCount += 1
        record.enabled = record.enableSucceeds
    }

    func invalidate() {
        guard record.invalidationCount == 0 else { return }
        record.invalidationCount += 1
        record.enabled = false
    }

    deinit { invalidate() }
}
