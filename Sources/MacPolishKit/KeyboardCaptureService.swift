import AppKit
import CoreGraphics
import Foundation

@MainActor
public protocol KeyboardCapturing: AnyObject {
    var permissionState: KeyboardPermissionState { get }
    var isCapturing: Bool { get }
    var isSecureInputEnabled: Bool { get }

    func refreshPermissionState() -> KeyboardPermissionState
    func requestPermission() -> KeyboardPermissionState
    func probeCaptureAvailability() -> Bool
    func startCapturing(for mode: CleaningMode, onEmergencyInput: @escaping @MainActor (EmergencyExitInput) -> Void) -> Bool
    func stopCapturing()
}

extension KeyboardCapturing {
    public func startCapturing(for mode: CleaningMode) -> Bool {
        startCapturing(for: mode, onEmergencyInput: { _ in })
    }
}

@MainActor
public protocol KeyboardPermissionOpening {
    func openInputMonitoringSettings()
}

@MainActor
public final class InputMonitoringSettingsOpener: KeyboardPermissionOpening {
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    public init() { }

    public func openInputMonitoringSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }
}

@MainActor
public final class SystemKeyboardCaptureService: KeyboardCapturing {
    public private(set) var permissionState: KeyboardPermissionState

    public var isSecureInputEnabled: Bool { access.isSecureInputEnabled }

    public var isCapturing: Bool {
        activeMode != nil && !isSecureInputEnabled && eventTap?.isEnabled == true
    }

    private let userDefaults: UserDefaults
    private let access: KeyboardAccessChecking
    private let tapFactory: KeyboardEventTapCreating
    private let requestedPermissionKey = "MacPolish.didRequestKeyboardPermission"
    // CGEventType has no named NSSystemDefined case; raw 14 includes media keys.
    private static let systemDefinedEventTypeRawValue: UInt32 = 14
    private static let keyboardEventMask =
        eventMask(forRawValue: CGEventType.keyDown.rawValue) |
        eventMask(forRawValue: CGEventType.keyUp.rawValue) |
        eventMask(forRawValue: CGEventType.flagsChanged.rawValue) |
        eventMask(forRawValue: systemDefinedEventTypeRawValue)

    private var eventTap: (any KeyboardEventTap)?
    private var activeMode: CleaningMode?
    private var captureID: UUID?
    private var onEmergencyInput: (@MainActor (EmergencyExitInput) -> Void)?

    public convenience init(userDefaults: UserDefaults = .standard) {
        self.init(userDefaults: userDefaults, access: SystemKeyboardAccess(), tapFactory: CoreGraphicsKeyboardEventTapFactory())
    }

    package init(userDefaults: UserDefaults, access: KeyboardAccessChecking, tapFactory: KeyboardEventTapCreating) {
        self.userDefaults = userDefaults
        self.access = access
        self.tapFactory = tapFactory
        self.permissionState = access.isTrusted ? .granted : (
            userDefaults.bool(forKey: "MacPolish.didRequestKeyboardPermission") ? .denied : .notDetermined
        )
    }

    public func refreshPermissionState() -> KeyboardPermissionState {
        permissionState = access.isTrusted ? .granted : (
            userDefaults.bool(forKey: requestedPermissionKey) ? .denied : .notDetermined
        )
        return permissionState
    }

    public func requestPermission() -> KeyboardPermissionState {
        userDefaults.set(true, forKey: requestedPermissionKey)
        access.requestAccess()
        return refreshPermissionState()
    }

    public func probeCaptureAvailability() -> Bool {
        // Preflight must not install an event tap. Creation is checked only
        // when starting a session, after the permission UI has settled.
        refreshPermissionState() == .granted && !isSecureInputEnabled
    }

    public func startCapturing(for mode: CleaningMode, onEmergencyInput: @escaping @MainActor (EmergencyExitInput) -> Void) -> Bool {
        guard mode != .screenOnly,
              refreshPermissionState() == .granted,
              !isSecureInputEnabled else {
            stopCapturing()
            return false
        }

        if isCapturing {
            self.onEmergencyInput?(.reset)
            self.onEmergencyInput = onEmergencyInput
            activeMode = mode
            return true
        }

        stopCapturing()
        self.onEmergencyInput = onEmergencyInput
        activeMode = mode
        let captureID = UUID()
        self.captureID = captureID

        guard let tap = tapFactory.makeTap(eventsOfInterest: Self.keyboardEventMask, handler: { [weak self] type, event in
            guard let self, self.captureID == captureID else { return Unmanaged.passUnretained(event) }
            return self.handleEventTap(type: type, event: event)
        }) else {
            stopCapturing()
            return false
        }
        eventTap = tap
        tap.enable()

        guard isCapturing else {
            stopCapturing()
            return false
        }
        return true
    }

    public func stopCapturing() {
        activeMode = nil
        captureID = nil
        onEmergencyInput?(.reset)
        onEmergencyInput = nil
        eventTap?.invalidate()
        eventTap = nil
    }

    private func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            onEmergencyInput?(.reset)
            if activeMode != nil && !isSecureInputEnabled && refreshPermissionState() == .granted {
                eventTap?.enable()
            }
            return Unmanaged.passUnretained(event)

        case .keyDown, .keyUp, .flagsChanged:
            if activeMode != nil, let input = EmergencyExitInput.from(type: type, event: event) {
                onEmergencyInput?(input)
            }
            return activeMode == nil ? Unmanaged.passUnretained(event) : nil

        default:
            if type.rawValue == Self.systemDefinedEventTypeRawValue, activeMode != nil {
                onEmergencyInput?(.reset)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
    }

    private static func eventMask(forRawValue rawValue: UInt32) -> CGEventMask {
        CGEventMask(1) << Int(rawValue)
    }
}
