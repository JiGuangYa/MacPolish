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

package enum LocalizationKey: String, CaseIterable {
    case appTitle = "app.title"
    case mainSubtitle = "main.subtitle"
    case mainFooterHint = "main.footerHint"

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

    case actionRequestKeyboardAccess = "action.requestKeyboardAccess"
    case actionOpenSystemSettings = "action.openSystemSettings"
    case actionDone = "action.done"

    case hintWholeMac = "hint.wholeMac"
    case hintScreenOnly = "hint.screenOnly"
    case hintKeyboardOnly = "hint.keyboardOnly"

    case accessibilityExitCleaning = "accessibility.exitCleaning"

    case menuCleaning = "menu.cleaning"
    case menuStartWholeMac = "menu.startWholeMac"
    case menuStartScreenOnly = "menu.startScreenOnly"
    case menuStartKeyboardOnly = "menu.startKeyboardOnly"
    case menuRequestKeyboardAccess = "menu.requestKeyboardAccess"
    case menuOpenKeyboardSettings = "menu.openKeyboardSettings"
    case menuExitCleaning = "menu.exitCleaning"
}

package enum L10n {
    package static let bundle = Bundle.module

    package static func string(_ key: LocalizationKey) -> String {
        bundle.localizedString(forKey: key.rawValue, value: nil, table: nil)
    }
}
