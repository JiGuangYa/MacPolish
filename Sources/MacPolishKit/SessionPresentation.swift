import Foundation

package enum AppWindowID {
    package static let main = "main"
}

extension CleaningMode {
    package var titleKey: LocalizationKey {
        switch self {
        case .wholeMac: .modeWholeMacTitle
        case .screenOnly: .modeScreenOnlyTitle
        case .keyboardOnly: .modeKeyboardOnlyTitle
        }
    }

    package var actionKey: LocalizationKey {
        switch self {
        case .wholeMac: .modeWholeMacAction
        case .screenOnly: .modeScreenOnlyAction
        case .keyboardOnly: .modeKeyboardOnlyAction
        }
    }

    package var symbolName: String {
        switch self {
        case .wholeMac: "laptopcomputer"
        case .screenOnly: "display"
        case .keyboardOnly: "keyboard"
        }
    }
}

extension KeyboardPermissionAction {
    package var titleKey: LocalizationKey {
        switch self {
        case .requestAccess: .actionRequestKeyboardAccess
        case .openSettings: .actionOpenSystemSettings
        case .refreshNow: .actionRefreshNow
        case .relaunchNow: .actionRelaunchNow
        case .startWholeMacCleaning: .modeWholeMacAction
        case .startKeyboardCleaning: .modeKeyboardOnlyAction
        }
    }
}

extension KeyboardProtection {
    package var descriptionKey: LocalizationKey {
        switch self {
        case .none: .protectionNone
        case .local: .protectionLocal
        case .global: .protectionGlobal
        }
    }
}

extension CleaningSessionNotice {
    package var messageKey: LocalizationKey {
        switch self {
        case .shieldUnavailable: .noticeShieldUnavailable
        case .relaunchFailed: .noticeRelaunchFailed
        case .mainWindowOpeningFailed: .noticeMainWindowOpeningFailed
        case .interrupted(.mainWindowUnavailable): .noticeWindowUnavailable
        case .interrupted(.mainWindowLeftActiveSpace): .noticeWindowLeftActiveSpace
        case .interrupted(.applicationHidden): .noticeApplicationHidden
        case .interrupted(.systemSleep): .noticeSystemSleep
        case .interrupted(.sessionResignedActive): .noticeSessionInactive
        case .interrupted(.displayConfigurationChanged): .noticeDisplaysChanged
        case .interrupted(.keyboardProtectionLost): .noticeKeyboardProtectionLost
        case .interrupted(.secureInputEnabled): .noticeSecureInput
        case .interrupted(.applicationDeactivated): .noticeApplicationDeactivated
        case .interrupted: .sessionEnded
        }
    }
}
