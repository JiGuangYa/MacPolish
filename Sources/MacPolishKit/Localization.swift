import Foundation

public enum CleaningMode: String, CaseIterable, Identifiable, Sendable {
    case wholeMac
    case screenOnly
    case keyboardOnly

    public var id: String {
        rawValue
    }
}

public enum KeyboardPermissionState: Sendable {
    case granted
    case notDetermined
    case denied
}

public enum KeyboardProtectionAvailability: Equatable, Sendable {
    case needsPermission
    case waitingForSystem
    case blockedBySecureInput
    case needsRelaunch
    case ready
}

public enum KeyboardPermissionAction: Equatable, Sendable {
    case requestAccess
    case openSettings
    case refreshNow
    case relaunchNow
    case startWholeMacCleaning
    case startKeyboardCleaning
}

public enum KeyboardProtection: Equatable, Sendable {
    case none
    case local
    case global
}

public enum CleaningSessionNotice: Equatable, Sendable {
    case shieldUnavailable
    case mainWindowOpeningFailed
    case relaunchFailed
    case interrupted(ExitTrigger)
}

package enum WindowMetrics {
    package static let defaultWidth: CGFloat = 1040
    package static let defaultHeight: CGFloat = 560
    package static let minimumWidth: CGFloat = 640
    package static let minimumHeight: CGFloat = 420
    package static let cardMinimumHeight: CGFloat = 260
}

package enum LocalizationKey: String, CaseIterable {
    case appTitle = "app.title"
    case mainSubtitle = "main.subtitle"
    case mainFooterHint = "main.footerHint"
    case exitShortcutHint = "exit.shortcutHint"
    case exitShortcutCountdown = "exit.shortcutCountdown"
    case exitShortcutCancel = "exit.shortcutCancel"
    case modeWholeMacLocalDescription = "mode.wholeMac.localDescription"
    case statusLocalProtection = "status.localProtection"
    case statusCleaning = "status.cleaning"
    case protectionGlobal = "protection.global"
    case protectionLocal = "protection.local"
    case protectionNone = "protection.none"
    case sessionElapsed = "session.elapsed"
    case sessionMouseExit = "session.mouseExit"
    case sessionEnded = "session.ended"
    case noticeShieldUnavailable = "notice.shieldUnavailable"
    case noticeRelaunchFailed = "notice.relaunchFailed"
    case statusRelaunching = "status.relaunching"
    case statusOpeningMainWindow = "status.openingMainWindow"
    case statusMainWindowOpeningFailed = "status.mainWindowOpeningFailed"
    case noticeMainWindowOpeningFailed = "notice.mainWindowOpeningFailed"
    case actionCancel = "action.cancel"
    case noticeWindowUnavailable = "notice.windowUnavailable"
    case noticeWindowLeftActiveSpace = "notice.windowLeftActiveSpace"
    case noticeApplicationHidden = "notice.applicationHidden"
    case noticeSystemSleep = "notice.systemSleep"
    case noticeSessionInactive = "notice.sessionInactive"
    case noticeDisplaysChanged = "notice.displaysChanged"
    case noticeKeyboardProtectionLost = "notice.keyboardProtectionLost"
    case noticeSecureInput = "notice.secureInput"
    case noticeApplicationDeactivated = "notice.applicationDeactivated"
    case actionDismiss = "action.dismiss"
    case menuOpenMainWindow = "menu.openMainWindow"
    case menuQuit = "menu.quit"
    case settingsShowMenuBarItem = "settings.showMenuBarItem"
    case settingsShowMenuBarItemHelp = "settings.showMenuBarItemHelp"

    case modeWholeMacTitle = "mode.wholeMac.title"
    case modeWholeMacDescription = "mode.wholeMac.description"
    case modeWholeMacAction = "mode.wholeMac.action"

    case modeScreenOnlyTitle = "mode.screenOnly.title"
    case modeScreenOnlyDescription = "mode.screenOnly.description"
    case modeScreenOnlyAction = "mode.screenOnly.action"

    case modeKeyboardOnlyTitle = "mode.keyboardOnly.title"
    case modeKeyboardOnlyDescription = "mode.keyboardOnly.description"
    case modeKeyboardOnlyAction = "mode.keyboardOnly.action"

    case permissionInputMonitoringRequired = "permission.inputMonitoringRequired"
    case permissionKeyboardNotDetermined = "permission.keyboardNotDetermined"
    case permissionKeyboardDenied = "permission.keyboardDenied"
    case permissionInputPrivacy = "permission.inputPrivacy"
    case permissionWaitingToApply = "permission.waitingToApply"
    case permissionSecureInput = "permission.secureInput"
    case permissionRelaunchRequired = "permission.relaunchRequired"
    case permissionOtherModesAvailable = "permission.otherModesAvailable"

    case actionRequestKeyboardAccess = "action.requestKeyboardAccess"
    case actionOpenSystemSettings = "action.openSystemSettings"
    case actionRefreshNow = "action.refreshNow"
    case actionRelaunchNow = "action.relaunchNow"
    case actionDone = "action.done"

    case hintWholeMac = "hint.wholeMac"
    case hintWholeMacLocal = "hint.wholeMacLocal"
    case hintScreenOnly = "hint.screenOnly"
    case hintKeyboardOnly = "hint.keyboardOnly"

    case accessibilityExitCleaning = "accessibility.exitCleaning"
    case accessibilityPermissionBanner = "accessibility.permissionBanner"

    case menuCleaning = "menu.cleaning"
    case menuStartWholeMac = "menu.startWholeMac"
    case menuStartScreenOnly = "menu.startScreenOnly"
    case menuStartKeyboardOnly = "menu.startKeyboardOnly"
    case menuRequestKeyboardAccess = "menu.requestKeyboardAccess"
    case menuOpenKeyboardSettings = "menu.openKeyboardSettings"
    case menuExitCleaning = "menu.exitCleaning"

    case statusReady = "status.ready"
    case statusNeedsPermission = "status.needsPermission"
    case statusWaitingToApply = "status.waitingToApply"
    case statusSecureInput = "status.secureInput"
    case statusNeedsRelaunch = "status.needsRelaunch"
    case statusPermissionGranted = "status.permissionGranted"
    case statusPermissionNotDetermined = "status.permissionNotDetermined"
    case statusPermissionDenied = "status.permissionDenied"

    case settingsGeneralSection = "settings.generalSection"
    case settingsPermissionsSection = "settings.permissionsSection"
    case settingsCleaningSection = "settings.cleaningSection"
    case settingsRememberLastMode = "settings.rememberLastMode"
    case settingsRememberLastModeHelp = "settings.rememberLastModeHelp"
    case settingsReopenMainWindow = "settings.reopenMainWindow"
    case settingsReopenMainWindowHelp = "settings.reopenMainWindowHelp"
    case settingsCurrentPermissionState = "settings.currentPermissionState"
    case settingsPermissionImpactDescription = "settings.permissionImpactDescription"
    case settingsShowExitHints = "settings.showExitHints"
    case settingsShowExitHintsHelp = "settings.showExitHintsHelp"
    case settingsControlFadeDelay = "settings.controlFadeDelay"
    case settingsControlFadeDelayHelp = "settings.controlFadeDelayHelp"
    case settingsFadeDelayValue = "settings.fadeDelayValue"
    case settingsRevealControlsOnPointerMovement = "settings.revealControlsOnPointerMovement"
    case settingsRevealControlsOnPointerMovementHelp = "settings.revealControlsOnPointerMovementHelp"
}

package enum L10n {
    package static let bundle = Bundle.module

    package static func string(_ key: LocalizationKey) -> String {
        bundle.localizedString(forKey: key.rawValue, value: nil, table: nil)
    }
}
