import AppKit
import CoreGraphics
import Foundation

@MainActor
public protocol KeyboardCapturing: AnyObject {
    var permissionState: KeyboardPermissionState { get }

    func refreshPermissionState() -> KeyboardPermissionState
    func requestPermission() -> KeyboardPermissionState
    func startCapturing() -> Bool
    func stopCapturing()
}

@MainActor
public protocol KeyboardPermissionOpening {
    func openInputMonitoringSettings()
}

@MainActor
public final class InputMonitoringSettingsOpener: KeyboardPermissionOpening {
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    public init() { }

    public func openInputMonitoringSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }
}

@MainActor
public final class SystemKeyboardCaptureService: KeyboardCapturing {
    public private(set) var permissionState: KeyboardPermissionState

    private let userDefaults: UserDefaults
    private let requestedPermissionKey = "MacPolish.didRequestKeyboardPermission"

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.permissionState = Self.computePermissionState(
            didRequestPermission: userDefaults.bool(forKey: requestedPermissionKey)
        )
    }

    public func refreshPermissionState() -> KeyboardPermissionState {
        permissionState = Self.computePermissionState(
            didRequestPermission: userDefaults.bool(forKey: requestedPermissionKey)
        )
        return permissionState
    }

    public func requestPermission() -> KeyboardPermissionState {
        userDefaults.set(true, forKey: requestedPermissionKey)

        permissionState = CGRequestListenEventAccess() ? .granted : .denied
        return permissionState
    }

    public func startCapturing() -> Bool {
        guard refreshPermissionState() == .granted else {
            return false
        }

        if eventTap != nil {
            return true
        }

        let eventMask =
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }

        eventTap = tap
        runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        return true
    }

    public func stopCapturing() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let service = Unmanaged<SystemKeyboardCaptureService>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        return service.handleEventTap(type: type, event: event)
    }

    private func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown, .keyUp, .flagsChanged:
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private static func computePermissionState(didRequestPermission: Bool) -> KeyboardPermissionState {
        if CGPreflightListenEventAccess() {
            return .granted
        }

        return didRequestPermission ? .denied : .notDetermined
    }
}
