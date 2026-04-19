import Foundation
import MacPolishKit

@main
struct MacPolishVerification {
    static func main() async {
        await MainActor.run {
            verifyWholeMacStart()
            verifyScreenOnlyStart()
            verifyKeyboardOnlyRequiresPermission()
            verifyKeyboardOnlyStartWithPermission()
            verifyStopCleaningRestoresMainWindow()
            verifyRequestPermissionUpdatesState()
            verifyOpenSettingsRoute()
            verifySupportedLocalizations()
            verifyLocalizationKeysMatchEnglishBase()
            verifyLocalizationResolution()
        }

        print("MacPolishVerification passed")
    }

    @MainActor
    private static func verifyWholeMacStart() {
        let screenShieldService = MockScreenShieldService()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .notDetermined)
        let applicationController = MockApplicationController()
        let mainWindowController = MockMainWindowController()
        let controller = CleaningSessionController(
            screenShieldService: screenShieldService,
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: applicationController,
            mainWindowController: mainWindowController
        )

        controller.startCleaning(mode: .wholeMac)

        require(controller.isCleaning, "Expected whole mac mode to start")
        require(controller.activeMode == .wholeMac, "Expected active mode to be wholeMac")
        require(screenShieldService.startCallHistory == [.wholeMac], "Expected shield service to start in wholeMac mode")
        require(mainWindowController.hideCallCount == 1, "Expected main window to hide")
        require(applicationController.activationCount == 1, "Expected wholeMac mode to activate the app")
        require(keyboardCaptureService.startCapturingCallCount == 0, "Expected wholeMac mode not to use global keyboard capture")
    }

    @MainActor
    private static func verifyScreenOnlyStart() {
        let screenShieldService = MockScreenShieldService()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .granted)
        let applicationController = MockApplicationController()
        let mainWindowController = MockMainWindowController()
        let controller = CleaningSessionController(
            screenShieldService: screenShieldService,
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: applicationController,
            mainWindowController: mainWindowController
        )

        controller.startCleaning(mode: .screenOnly)

        require(controller.isCleaning, "Expected screenOnly mode to start")
        require(controller.activeMode == .screenOnly, "Expected active mode to be screenOnly")
        require(screenShieldService.startCallHistory == [.screenOnly], "Expected shield service to start in screenOnly mode")
        require(applicationController.activationCount == 0, "Expected screenOnly mode not to activate the app")
        require(keyboardCaptureService.startCapturingCallCount == 0, "Expected screenOnly mode not to start keyboard capture")
    }

    @MainActor
    private static func verifyKeyboardOnlyRequiresPermission() {
        let screenShieldService = MockScreenShieldService()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .notDetermined)
        let controller = CleaningSessionController(
            screenShieldService: screenShieldService,
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            mainWindowController: MockMainWindowController()
        )

        controller.startCleaning(mode: .keyboardOnly)

        require(controller.isCleaning == false, "Expected keyboardOnly mode to stay idle without permission")
        require(controller.activeMode == nil, "Expected no active mode without permission")
        require(screenShieldService.startCallHistory.isEmpty, "Expected shield service not to start without permission")
        require(keyboardCaptureService.startCapturingCallCount == 0, "Expected keyboard capture not to start without permission")
        require(controller.keyboardPermissionState == .notDetermined, "Expected permission state to remain notDetermined")
    }

    @MainActor
    private static func verifyKeyboardOnlyStartWithPermission() {
        let screenShieldService = MockScreenShieldService()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .granted)
        let controller = CleaningSessionController(
            screenShieldService: screenShieldService,
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            mainWindowController: MockMainWindowController()
        )

        controller.startCleaning(mode: .keyboardOnly)

        require(controller.isCleaning, "Expected keyboardOnly mode to start with permission")
        require(controller.activeMode == .keyboardOnly, "Expected active mode to be keyboardOnly")
        require(screenShieldService.startCallHistory == [.keyboardOnly], "Expected shield service to start in keyboardOnly mode")
        require(keyboardCaptureService.startCapturingCallCount == 1, "Expected keyboard capture to start once")
    }

    @MainActor
    private static func verifyStopCleaningRestoresMainWindow() {
        let screenShieldService = MockScreenShieldService()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .granted)
        let applicationController = MockApplicationController()
        let mainWindowController = MockMainWindowController()
        let controller = CleaningSessionController(
            screenShieldService: screenShieldService,
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: applicationController,
            mainWindowController: mainWindowController
        )

        controller.startCleaning(mode: .keyboardOnly)
        controller.stopCleaning(trigger: .button)

        require(controller.isCleaning == false, "Expected stopCleaning to reset isCleaning")
        require(controller.activeMode == nil, "Expected stopCleaning to clear activeMode")
        require(controller.lastExitTrigger == .button, "Expected exit trigger to be preserved")
        require(screenShieldService.stopCallCount == 1, "Expected shield service to stop")
        require(keyboardCaptureService.stopCapturingCallCount == 1, "Expected keyboard capture to stop")
        require(mainWindowController.showAndFocusCallCount == 1, "Expected main window to restore")
        require(applicationController.activationCount == 1, "Expected stopCleaning to activate the app")
    }

    @MainActor
    private static func verifyRequestPermissionUpdatesState() {
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .notDetermined)
        keyboardCaptureService.requestPermissionResult = .granted

        let controller = CleaningSessionController(
            screenShieldService: MockScreenShieldService(),
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            mainWindowController: MockMainWindowController()
        )

        let updatedState = controller.requestKeyboardPermission()

        require(updatedState == .granted, "Expected requestKeyboardPermission to return granted")
        require(controller.keyboardPermissionState == .granted, "Expected controller permission state to update after request")
    }

    @MainActor
    private static func verifyOpenSettingsRoute() {
        let settingsOpener = MockSettingsOpener()
        let controller = CleaningSessionController(
            screenShieldService: MockScreenShieldService(),
            keyboardCaptureService: MockKeyboardCaptureService(permissionState: .denied),
            settingsOpener: settingsOpener,
            applicationController: MockApplicationController(),
            mainWindowController: MockMainWindowController()
        )

        controller.openKeyboardPermissionSettings()

        require(settingsOpener.openCallCount == 1, "Expected settings opener to be invoked")
    }

    @MainActor
    private static func verifySupportedLocalizations() {
        let supportedLocalizations = loadSupportedLocalizations()
        require(supportedLocalizations.count == 10, "Expected 10 supported localizations")

        let localizationDirectory = repositoryRootURL()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MacPolishKit")
            .appendingPathComponent("Resources")

        for localization in supportedLocalizations {
            let stringsURL = localizationDirectory
                .appendingPathComponent("\(localization).lproj")
                .appendingPathComponent("Localizable.strings")
            require(FileManager.default.fileExists(atPath: stringsURL.path), "Missing strings file for \(localization)")
        }
    }

    @MainActor
    private static func verifyLocalizationKeysMatchEnglishBase() {
        let supportedLocalizations = loadSupportedLocalizations()
        let baseDictionary = loadStringsDictionary(localization: "en")
        let expectedKeys = Set(LocalizationKey.allCases.map(\.rawValue))

        require(Set(baseDictionary.keys) == expectedKeys, "English localization keys do not match LocalizationKey definitions")

        for localization in supportedLocalizations where localization != "en" {
            let dictionary = loadStringsDictionary(localization: localization)
            require(Set(dictionary.keys) == expectedKeys, "Localization keys for \(localization) do not match English")
        }
    }

    @MainActor
    private static func verifyLocalizationResolution() {
        let availableLocalizations = L10n.bundle.localizations
        let normalizedSupportedLocalizations = Set(loadSupportedLocalizations().map { $0.lowercased() })

        require(
            Set(availableLocalizations) == normalizedSupportedLocalizations,
            "Expected resource bundle localizations to match supported_localizations.txt"
        )

        require(
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["zh-Hans-CN"]).first == "zh-hans",
            "Expected Simplified Chinese preference to resolve to zh-Hans"
        )
        require(
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["zh-Hant-HK"]).first == "zh-hant",
            "Expected Traditional Chinese preference to resolve to zh-Hant"
        )
        require(
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["ja-JP"]).first == "ja",
            "Expected Japanese preference to resolve to ja"
        )
        require(
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["ko-KR"]).first == "ko",
            "Expected Korean preference to resolve to ko"
        )
        require(
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["fr-FR"]).first == "fr",
            "Expected French preference to resolve to fr"
        )
        require(
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["de-DE"]).first == "de",
            "Expected German preference to resolve to de"
        )
        require(
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["es-ES"]).first == "es",
            "Expected Spanish preference to resolve to es"
        )
        require(
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["it-IT"]).first == "it",
            "Expected Italian preference to resolve to it"
        )
        require(
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["pt-BR"]).first == "pt-br",
            "Expected Brazilian Portuguese preference to resolve to pt-BR"
        )
        require(
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["nl-NL", "fr-FR"]).first == "fr",
            "Expected unsupported Dutch with French fallback to resolve to fr"
        )
        require(
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["nl-NL", "sv-SE"]).first == "en",
            "Expected unsupported preferences to fall back to en"
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Verification failed: \(message)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func repositoryRootURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private static func loadSupportedLocalizations() -> [String] {
        let supportedLocalizationsURL = repositoryRootURL()
            .appendingPathComponent("Localization")
            .appendingPathComponent("supported_localizations.txt")

        guard let contents = try? String(contentsOf: supportedLocalizationsURL, encoding: .utf8) else {
            fputs("Verification failed: Missing supported_localizations.txt\n", stderr)
            exit(EXIT_FAILURE)
        }

        return contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func loadStringsDictionary(localization: String) -> [String: String] {
        let stringsURL = repositoryRootURL()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MacPolishKit")
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(localization).lproj")
            .appendingPathComponent("Localizable.strings")

        guard let dictionary = NSDictionary(contentsOf: stringsURL) as? [String: String] else {
            fputs("Verification failed: Unable to parse \(stringsURL.path)\n", stderr)
            exit(EXIT_FAILURE)
        }

        return dictionary
    }
}

@MainActor
private final class MockScreenShieldService: ScreenShielding {
    var startCallHistory: [CleaningMode] = []
    var stopCallCount = 0

    func start(mode: CleaningMode, onExit: @escaping @MainActor (ExitTrigger) -> Void) -> Bool {
        startCallHistory.append(mode)
        return true
    }

    func stop() {
        stopCallCount += 1
    }
}

@MainActor
private final class MockKeyboardCaptureService: KeyboardCapturing {
    var permissionState: KeyboardPermissionState
    var requestPermissionResult: KeyboardPermissionState

    var refreshPermissionStateCallCount = 0
    var requestPermissionCallCount = 0
    var startCapturingCallCount = 0
    var stopCapturingCallCount = 0

    init(permissionState: KeyboardPermissionState) {
        self.permissionState = permissionState
        self.requestPermissionResult = permissionState
    }

    func refreshPermissionState() -> KeyboardPermissionState {
        refreshPermissionStateCallCount += 1
        return permissionState
    }

    func requestPermission() -> KeyboardPermissionState {
        requestPermissionCallCount += 1
        permissionState = requestPermissionResult
        return permissionState
    }

    func startCapturing() -> Bool {
        startCapturingCallCount += 1
        return permissionState == .granted
    }

    func stopCapturing() {
        stopCapturingCallCount += 1
    }
}

@MainActor
private final class MockSettingsOpener: KeyboardPermissionOpening {
    var openCallCount = 0

    func openInputMonitoringSettings() {
        openCallCount += 1
    }
}

@MainActor
private final class MockApplicationController: ApplicationControlling {
    var activationCount = 0

    func activate(ignoringOtherApps: Bool) {
        activationCount += 1
    }
}

@MainActor
private final class MockMainWindowController: MainWindowControlling {
    var hideCallCount = 0
    var showAndFocusCallCount = 0

    func hide() {
        hideCallCount += 1
    }

    func showAndFocus() {
        showAndFocusCallCount += 1
    }
}
