import Foundation
import MacPolishKit

@main
struct MacPolishVerification {
    @MainActor private static var defaultsSuites: [String] = []

    static func main() async {
        if Bundle.main.object(forInfoDictionaryKey: "MacPolishRelaunchProbe") as? Bool == true {
            await MainActor.run { RelaunchProbe.run() }
            return
        }
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--verify-relaunch-launcher"),
           CommandLine.arguments.indices.contains(flagIndex + 1) {
            do {
                try await NativeRelaunchVerification.run(probeURL: URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1]))
            } catch {
                fputs("Native relaunch verification failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-previews"),
           CommandLine.arguments.indices.contains(flagIndex + 1) {
            let path = CommandLine.arguments[flagIndex + 1]
            do {
                await MainActor.run {
                    if let languageIndex = CommandLine.arguments.firstIndex(of: "--expect-language"),
                       CommandLine.arguments.indices.contains(languageIndex + 1) {
                        let expected = CommandLine.arguments[languageIndex + 1].lowercased()
                        require(L10n.bundle.preferredLocalizations.first?.lowercased() == expected,
                                "Preview language did not resolve to \(expected); use scripts/render_previews.sh")
                    }
                }
                try await PreviewRenderer.render(to: URL(fileURLWithPath: path, isDirectory: true))
            } catch {
                fputs("Preview rendering failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }

        await MainActor.run {
            defer { cleanupTestDefaults() }
            verifyWholeMacStartsWithoutGlobalPermission()
            verifyWholeMacStartWithPermission()
            verifyScreenOnlyStart()
            verifyKeyboardOnlyRequiresPermission()
            verifyProtectedPrimaryActionsRequestPermission()
            verifyKeyboardOnlyStartWithPermission()
            verifyKeyboardOnlyIgnoresImmediateExitToggle()
            verifyKeyboardOnlyPrimaryActionTogglesOff()
            verifyKeyboardProtectionAvailabilityStates()
            verifyGlobalCaptureFailureDoesNotStartProtectedModes()
            verifyStopCleaningRestoresMainWindow()
            SessionLifecycleVerification.run()
            KeyboardCaptureVerification.run()
            ScreenShieldVerification.verifyNativeWindowInput()
            EmergencyExitVerification.run()
            verifyRequestPermissionUpdatesState()
            verifyOpenSettingsRoute()
            verifyRelaunchRoute()
            verifyAppSettingsDefaultsAndPersistence()
            verifySupportedLocalizations()
            verifyLocalizationKeysMatchEnglishBase()
            verifyLocalizationResolution()
        }

        await ScreenShieldVerification.verifyScreenOnlyLaunchClickGuard()
        await SessionLifecycleVerification.verifyScheduledProtectionMonitoring()
        await ScreenShieldVerification.verifyShieldWindowGeometry()
        await ScreenShieldVerification.verifyPresentationLifecycle()
        await ScreenShieldVerification.verifyAccessibleExitPresentation()
        await EmergencyExitVerification.verifyScheduledHold()
        await MenuActionVerification.run()
        do {
            try await RelaunchVerification.run()
        } catch {
            fputs("Relaunch verification failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
        await MainActor.run { cleanupTestDefaults() }

        print("MacPolishVerification passed")
    }

    @MainActor
    private static func verifyWholeMacStartsWithoutGlobalPermission() {
        let screenShieldService = MockScreenShieldService()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .notDetermined)
        let applicationController = MockApplicationController()
        let mainWindowController = MockMainWindowController()
        let controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
            screenShieldService: screenShieldService,
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: applicationController,
            mainWindowController: mainWindowController
        )

        controller.startCleaning(mode: .wholeMac)

        require(controller.isCleaning, "Expected whole mac mode to black out even without global permission")
        require(controller.activeMode == .wholeMac, "Expected wholeMac mode to become active without global permission")
        require(screenShieldService.startCallHistory == [.wholeMac], "Expected shield service to start wholeMac mode without permission")
        require(keyboardCaptureService.startCapturingCallCount == 0, "Expected wholeMac not to start keyboard capture without permission")
    }

    @MainActor
    private static func verifyWholeMacStartWithPermission() {
        let screenShieldService = MockScreenShieldService()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .granted)
        let applicationController = MockApplicationController()
        let mainWindowController = MockMainWindowController()
        let controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
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
        require(mainWindowController.hideCallCount == 0, "Expected wholeMac mode to keep the main window managed by SwiftUI alive")
        require(applicationController.activationCount == 1, "Expected wholeMac mode to activate the app")
        require(keyboardCaptureService.startCapturingCallCount == 1, "Expected wholeMac mode to use global keyboard capture")
    }

    @MainActor
    private static func verifyScreenOnlyStart() {
        let screenShieldService = MockScreenShieldService()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .granted)
        let applicationController = MockApplicationController()
        let mainWindowController = MockMainWindowController()
        let controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
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
            appSettings: AppSettings(userDefaults: testUserDefaults()),
            screenShieldService: screenShieldService,
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            mainWindowController: MockMainWindowController()
        )

        controller.startCleaning(mode: .keyboardOnly)

        require(controller.isCleaning == false, "Expected keyboardOnly mode to stay idle without global permission")
        require(controller.activeMode == nil, "Expected no active keyboardOnly mode without permission")
        require(screenShieldService.startCallHistory.isEmpty, "Expected shield service not to start without permission")
        require(keyboardCaptureService.startCapturingCallCount == 0, "Expected keyboard capture not to start without permission")
        require(controller.keyboardPermissionState == .notDetermined, "Expected permission state to remain notDetermined")
    }

    @MainActor
    private static func verifyProtectedPrimaryActionsRequestPermission() {
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .notDetermined)
        let controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
            screenShieldService: MockScreenShieldService(),
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            mainWindowController: MockMainWindowController()
        )

        controller.performPrimaryAction(for: .keyboardOnly)

        require(keyboardCaptureService.requestPermissionCallCount == 1, "Expected keyboard primary action to request permission when access is missing")
        require(controller.isCleaning == false, "Expected keyboard primary action not to enter cleaning before global capture is ready")
    }

    @MainActor
    private static func verifyKeyboardOnlyStartWithPermission() {
        let screenShieldService = MockScreenShieldService()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .granted)
        let controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
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
    private static func verifyKeyboardOnlyIgnoresImmediateExitToggle() {
        var currentDate = Date(timeIntervalSinceReferenceDate: 100)
        var uptime: TimeInterval = 500
        let screenShieldService = MockScreenShieldService()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .granted)
        let controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
            screenShieldService: screenShieldService,
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            mainWindowController: MockMainWindowController(),
            dateProvider: { currentDate },
            uptimeProvider: { uptime },
            keyboardOnlyButtonExitDelay: 0.45
        )

        controller.performPrimaryAction(for: .keyboardOnly)
        controller.performPrimaryAction(for: .keyboardOnly)

        require(controller.isCleaning, "Expected immediate keyboardOnly toggle to be ignored")
        require(controller.activeMode == .keyboardOnly, "Expected keyboardOnly mode to remain active during the startup click guard")
        require(screenShieldService.stopCallCount == 0, "Expected immediate keyboardOnly toggle not to stop the shield service")
        require(keyboardCaptureService.stopCapturingCallCount == 0, "Expected immediate keyboardOnly toggle not to stop keyboard capture")

        currentDate = currentDate.addingTimeInterval(3_600)
        controller.performPrimaryAction(for: .keyboardOnly)
        require(controller.isCleaning, "Expected a wall-clock jump not to bypass the startup click guard")

        currentDate = currentDate.addingTimeInterval(-7_200)
        uptime += 0.46
        controller.performPrimaryAction(for: .keyboardOnly)

        require(controller.isCleaning == false, "Expected keyboardOnly toggle to stop after the startup guard expires")
        require(controller.lastExitTrigger == .button, "Expected delayed keyboardOnly toggle to register as a button exit")
    }

    @MainActor
    private static func verifyKeyboardOnlyPrimaryActionTogglesOff() {
        let screenShieldService = MockScreenShieldService()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .granted)
        let controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
            screenShieldService: screenShieldService,
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            mainWindowController: MockMainWindowController(),
            keyboardOnlyButtonExitDelay: 0
        )

        controller.performPrimaryAction(for: .keyboardOnly)

        require(controller.isCleaning, "Expected keyboardOnly primary action to start cleaning")
        require(controller.canPerformPrimaryAction(for: .keyboardOnly), "Expected active keyboardOnly button to stay tappable for exit")

        controller.performPrimaryAction(for: .keyboardOnly)

        require(controller.isCleaning == false, "Expected tapping keyboardOnly again to stop cleaning")
        require(controller.lastExitTrigger == .button, "Expected keyboardOnly toggle exit to register as a button exit")
        require(screenShieldService.stopCallCount == 1, "Expected toggling keyboardOnly off to stop the shield service")
        require(keyboardCaptureService.stopCapturingCallCount == 1, "Expected toggling keyboardOnly off to stop keyboard capture")
    }

    @MainActor
    private static func verifyKeyboardProtectionAvailabilityStates() {
        let unknownPermissionController = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
            screenShieldService: MockScreenShieldService(),
            keyboardCaptureService: MockKeyboardCaptureService(permissionState: .notDetermined),
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            mainWindowController: MockMainWindowController()
        )

        require(unknownPermissionController.showsKeyboardPermissionBanner == false, "Expected main permission banner to stay hidden")
        require(unknownPermissionController.keyboardProtectionAvailability == .needsPermission, "Expected unknown permission to map to needsPermission availability")
        require(unknownPermissionController.canStartWholeMac, "Expected whole mac mode to remain available without global keyboard permission")
        require(unknownPermissionController.canStartKeyboardOnly == false, "Expected keyboard mode to require keyboard capture permission")
        require(unknownPermissionController.globalKeyboardPermissionPrimaryAction == .requestAccess, "Expected unknown permission to map to requestAccess")
        require(unknownPermissionController.wholeMacPermissionPrimaryAction == .requestAccess, "Expected wholeMac action to map to requestAccess")
        require(unknownPermissionController.keyboardPermissionPrimaryAction == .requestAccess, "Expected keyboard action to map to requestAccess")

        let deniedPermissionController = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
            screenShieldService: MockScreenShieldService(),
            keyboardCaptureService: MockKeyboardCaptureService(permissionState: .denied),
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            mainWindowController: MockMainWindowController()
        )

        require(deniedPermissionController.showsKeyboardPermissionBanner == false, "Expected main permission banner to stay hidden when permission is denied")
        require(deniedPermissionController.keyboardProtectionAvailability == .needsPermission, "Expected denied permission to map to needsPermission availability")
        require(deniedPermissionController.canStartWholeMac, "Expected whole mac mode to remain available while permission is denied")
        require(deniedPermissionController.canStartKeyboardOnly == false, "Expected keyboard mode to require denied permission to be fixed")
        require(deniedPermissionController.globalKeyboardPermissionPrimaryAction == .openSettings, "Expected denied permission to map to openSettings")
        require(deniedPermissionController.wholeMacPermissionPrimaryAction == .openSettings, "Expected wholeMac action to map to openSettings")
        require(deniedPermissionController.keyboardPermissionPrimaryAction == .openSettings, "Expected keyboard action to map to openSettings")

        let waitingKeyboardCaptureService = MockKeyboardCaptureService(permissionState: .granted)
        waitingKeyboardCaptureService.probeCaptureAvailabilityResult = false
        let waitingPermissionController = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
            screenShieldService: MockScreenShieldService(),
            keyboardCaptureService: waitingKeyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            mainWindowController: MockMainWindowController()
        )

        waitingPermissionController.refreshKeyboardProtectionAvailability(startPollingIfNeeded: false)

        require(waitingPermissionController.showsKeyboardPermissionBanner == false, "Expected main permission banner to stay hidden while waiting")
        require(waitingPermissionController.keyboardProtectionAvailability == .waitingForSystem, "Expected granted-but-unavailable permission to map to waitingForSystem")
        require(waitingPermissionController.canStartWholeMac, "Expected whole mac mode to remain available while global capture waits")
        require(waitingPermissionController.canStartKeyboardOnly == false, "Expected keyboard mode to wait for usable capture")
        require(waitingPermissionController.globalKeyboardPermissionPrimaryAction == .refreshNow, "Expected waiting permission to map to refreshNow")
        require(waitingPermissionController.wholeMacPermissionPrimaryAction == .refreshNow, "Expected wholeMac action to map to refreshNow")
        require(waitingPermissionController.keyboardPermissionPrimaryAction == .refreshNow, "Expected keyboard action to map to refreshNow")

        let grantedPermissionController = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
            screenShieldService: MockScreenShieldService(),
            keyboardCaptureService: MockKeyboardCaptureService(permissionState: .granted),
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            mainWindowController: MockMainWindowController()
        )

        require(grantedPermissionController.showsKeyboardPermissionBanner == false, "Expected main permission banner to stay hidden when permission is granted")
        require(grantedPermissionController.keyboardProtectionAvailability == .ready, "Expected granted permission to map to ready availability")
        require(grantedPermissionController.canStartWholeMac, "Expected whole mac mode to become available when permission is granted")
        require(grantedPermissionController.canStartKeyboardOnly, "Expected keyboard mode to become available when permission is granted")
        require(grantedPermissionController.globalKeyboardPermissionPrimaryAction == .startWholeMacCleaning, "Expected global permission action to map to startWholeMacCleaning")
        require(grantedPermissionController.wholeMacPermissionPrimaryAction == .startWholeMacCleaning, "Expected wholeMac action to map to startWholeMacCleaning")
        require(grantedPermissionController.keyboardPermissionPrimaryAction == .startKeyboardCleaning, "Expected keyboard action to map to startKeyboardCleaning")
    }

    @MainActor
    private static func verifyGlobalCaptureFailureDoesNotStartProtectedModes() {
        let screenShieldService = MockScreenShieldService()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .granted)
        keyboardCaptureService.startCapturingResult = false
        let controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
            screenShieldService: screenShieldService,
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            applicationRelauncher: MockApplicationRelauncher(),
            mainWindowController: MockMainWindowController()
        )

        controller.startCleaning(mode: .wholeMac)

        require(controller.isCleaning, "Expected wholeMac mode to keep black-screen protection when global capture cannot start")
        require(controller.activeMode == .wholeMac, "Expected wholeMac mode to become active when global capture fails")
        require(screenShieldService.startCallHistory == [.wholeMac], "Expected shields to start even when global capture fails")
        require(keyboardCaptureService.startCapturingCallCount == 1, "Expected wholeMac mode to attempt global capture")
        require(keyboardCaptureService.stopCapturingCallCount == 1, "Expected failed capture to be cleaned up")
        require(controller.keyboardProtectionAvailability == .needsRelaunch, "Expected failed capture to surface relaunch-needed availability")

        let keyboardOnlyScreenShieldService = MockScreenShieldService()
        let keyboardOnlyCaptureService = MockKeyboardCaptureService(permissionState: .granted)
        keyboardOnlyCaptureService.startCapturingResult = false
        let keyboardOnlyController = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
            screenShieldService: keyboardOnlyScreenShieldService,
            keyboardCaptureService: keyboardOnlyCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            applicationRelauncher: MockApplicationRelauncher(),
            mainWindowController: MockMainWindowController()
        )

        keyboardOnlyController.startCleaning(mode: .keyboardOnly)

        require(keyboardOnlyController.isCleaning == false, "Expected keyboardOnly mode not to start if global capture cannot start")
        require(keyboardOnlyController.activeMode == nil, "Expected no active keyboardOnly mode when global capture fails")
        require(keyboardOnlyScreenShieldService.startCallHistory.isEmpty, "Expected keyboardOnly shield not to start when global capture fails")
        require(keyboardOnlyCaptureService.startCapturingCallCount == 1, "Expected keyboardOnly mode to attempt global capture")
        require(keyboardOnlyCaptureService.stopCapturingCallCount == 1, "Expected failed keyboardOnly capture to be cleaned up")
        require(keyboardOnlyController.keyboardProtectionAvailability == .needsRelaunch, "Expected failed keyboardOnly capture to surface relaunch-needed availability")
    }

    @MainActor
    private static func verifyStopCleaningRestoresMainWindow() {
        let screenShieldService = MockScreenShieldService()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .granted)
        let applicationController = MockApplicationController()
        let mainWindowController = MockMainWindowController()
        let controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
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
        require(applicationController.activationCount == 2, "Expected keyboardOnly start and stop to activate the app")
    }

    @MainActor
    private static func verifyRequestPermissionUpdatesState() {
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .notDetermined)
        keyboardCaptureService.requestPermissionResult = .granted
        keyboardCaptureService.probeCaptureAvailabilityResult = true

        let controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
            screenShieldService: MockScreenShieldService(),
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            mainWindowController: MockMainWindowController()
        )

        let updatedState = controller.requestKeyboardPermission()

        require(updatedState == .granted, "Expected requestKeyboardPermission to return granted")
        require(controller.keyboardPermissionState == .granted, "Expected controller permission state to update after request")
        require(controller.keyboardProtectionAvailability == .ready, "Expected requestKeyboardPermission to update availability to ready when probing succeeds")
        require(keyboardCaptureService.requestPermissionCallCount == 1, "Expected requestKeyboardPermission to ask the keyboard service once")
        require(keyboardCaptureService.refreshPermissionStateCallCount == 1, "Expected requestKeyboardPermission to refresh permission state after the request")
        require(keyboardCaptureService.probeCaptureAvailabilityCallCount == 1, "Expected requestKeyboardPermission to probe capture availability after permission changes")
    }

    @MainActor
    private static func verifyOpenSettingsRoute() {
        let settingsOpener = MockSettingsOpener()
        let controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
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
    private static func verifyRelaunchRoute() {
        let relauncher = MockApplicationRelauncher()
        let keyboardCaptureService = MockKeyboardCaptureService(permissionState: .granted)
        keyboardCaptureService.startCapturingResult = false
        let controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: testUserDefaults()),
            screenShieldService: MockScreenShieldService(),
            keyboardCaptureService: keyboardCaptureService,
            settingsOpener: MockSettingsOpener(),
            applicationController: MockApplicationController(),
            applicationRelauncher: relauncher,
            mainWindowController: MockMainWindowController()
        )

        controller.startCleaning(mode: .keyboardOnly)
        controller.relaunchApplication()

        require(relauncher.relaunchCallCount == 1, "Expected relauncher to be invoked")
    }

    @MainActor
    private static func verifyAppSettingsDefaultsAndPersistence() {
        let userDefaults = testUserDefaults()
        let settings = AppSettings(userDefaults: userDefaults)

        require(settings.rememberLastMode, "Expected rememberLastMode default to be true")
        require(settings.showMenuBarItem, "Expected menu bar access to be available by default")
        require(settings.reopenMainWindowAfterCleaning, "Expected reopenMainWindowAfterCleaning default to be true")
        require(settings.showExitHints, "Expected showExitHints default to be true")
        require(settings.revealControlsOnPointerMovement, "Expected revealControlsOnPointerMovement default to be true")
        require(abs(settings.clampedFadeDelay - 2.8) < 0.001, "Expected default fade delay to be 2.8")

        settings.markModeUsed(.keyboardOnly)
        require(settings.lastSelectedMode == .keyboardOnly, "Expected markModeUsed to persist the latest mode")

        settings.rememberLastMode = false
        settings.showMenuBarItem = false
        settings.reopenMainWindowAfterCleaning = false
        settings.showExitHints = false
        settings.controlFadeDelay = 4.2
        settings.revealControlsOnPointerMovement = false

        let reloaded = AppSettings(userDefaults: userDefaults)
        require(reloaded.rememberLastMode == false, "Expected rememberLastMode to persist")
        require(reloaded.showMenuBarItem == false, "Expected the menu bar preference to persist")
        require(reloaded.lastSelectedMode == nil, "Expected disabling rememberLastMode to clear the saved mode")
        require(reloaded.reopenMainWindowAfterCleaning == false, "Expected reopenMainWindowAfterCleaning to persist")
        require(reloaded.showExitHints == false, "Expected showExitHints to persist")
        require(abs(reloaded.clampedFadeDelay - 4.2) < 0.001, "Expected fade delay to persist")
        require(reloaded.revealControlsOnPointerMovement == false, "Expected revealControlsOnPointerMovement to persist")

        for (input, expected) in [(-10.0, 1.5), (100.0, 5.0), (Double.nan, 2.8), (Double.infinity, 2.8)] {
            settings.controlFadeDelay = input
            require(settings.controlFadeDelay == expected, "Expected fade settings to normalize out-of-range or nonfinite values")
            require(AppSettings(userDefaults: userDefaults).clampedFadeDelay == expected, "Expected only usable timer values to persist")
        }
        userDefaults.set(Double.nan, forKey: "MacPolish.settings.controlFadeDelay")
        require(AppSettings(userDefaults: userDefaults).controlFadeDelay == 2.8, "Expected corrupted timer defaults to recover safely")
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
            Set(availableLocalizations.map { $0.lowercased() }) == normalizedSupportedLocalizations,
            "Expected resource bundle localizations to match supported_localizations.txt; found \(availableLocalizations)"
        )

        require(
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["zh-Hans-CN"]).first?.lowercased() == "zh-hans",
            "Expected Simplified Chinese preference to resolve to zh-Hans"
        )
        require(
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["zh-Hant-HK"]).first?.lowercased() == "zh-hant",
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
            Bundle.preferredLocalizations(from: availableLocalizations, forPreferences: ["pt-BR"]).first?.lowercased() == "pt-br",
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

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
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

    @MainActor
    static func testUserDefaults() -> UserDefaults {
        let suiteName = "MacPolishVerification.\(UUID().uuidString)"
        defaultsSuites.append(suiteName)
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }

    @MainActor
    static func cleanupTestDefaults() {
        for suite in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        defaultsSuites.removeAll()
    }
}

@MainActor
final class MockScreenShieldService: ScreenShielding {
    var startCallHistory: [CleaningMode] = []
    var stopCallCount = 0
    var startResult = true
    var exitHandlers: [@MainActor (ExitTrigger) -> Void] = []
    var onStop: (() -> Void)?
    var protectionHistory: [KeyboardProtection] = []

    func start(mode: CleaningMode, keyboardProtection: KeyboardProtection, onExit: @escaping @MainActor (ExitTrigger) -> Void) -> Bool {
        startCallHistory.append(mode)
        protectionHistory.append(keyboardProtection)
        exitHandlers.append(onExit)
        return startResult
    }

    func stop() {
        stopCallCount += 1
        onStop?()
    }
}

@MainActor
final class MockKeyboardCaptureService: KeyboardCapturing {
    var isCapturing = false
    var isSecureInputEnabled = false
    var permissionState: KeyboardPermissionState
    var requestPermissionResult: KeyboardPermissionState
    var probeCaptureAvailabilityResult: Bool

    var refreshPermissionStateCallCount = 0
    var requestPermissionCallCount = 0
    var probeCaptureAvailabilityCallCount = 0
    var startCapturingCallCount = 0
    var stopCapturingCallCount = 0
    var startCapturingResult: Bool
    var onStart: (() -> Void)?
    var emergencyInputHandlers: [@MainActor (EmergencyExitInput) -> Void] = []

    init(permissionState: KeyboardPermissionState) {
        self.permissionState = permissionState
        self.requestPermissionResult = permissionState
        self.probeCaptureAvailabilityResult = permissionState == .granted
        self.startCapturingResult = permissionState == .granted
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

    func probeCaptureAvailability() -> Bool {
        probeCaptureAvailabilityCallCount += 1
        return probeCaptureAvailabilityResult && !isSecureInputEnabled
    }

    func startCapturing(for mode: CleaningMode, onEmergencyInput: @escaping @MainActor (EmergencyExitInput) -> Void) -> Bool {
        startCapturingCallCount += 1
        emergencyInputHandlers.append(onEmergencyInput)
        onStart?()
        isCapturing = permissionState == .granted && !isSecureInputEnabled && startCapturingResult
        return isCapturing
    }

    func stopCapturing() {
        isCapturing = false
        stopCapturingCallCount += 1
    }
}

@MainActor
final class MockSettingsOpener: KeyboardPermissionOpening {
    var openCallCount = 0

    func openInputMonitoringSettings() {
        openCallCount += 1
    }
}

@MainActor
final class MockApplicationController: ApplicationControlling {
    var activationCount = 0
    var isActive = true

    func activate(ignoringOtherApps: Bool) {
        activationCount += 1
    }
}

@MainActor
final class MockApplicationRelauncher: ApplicationRelaunching {
    var relaunchCallCount = 0
    var completesImmediately = true
    var result = false
    var completions: [@MainActor (Bool) -> Void] = []

    func relaunch(completion: @escaping @MainActor (Bool) -> Void) {
        relaunchCallCount += 1
        completions.append(completion)
        if completesImmediately { completion(result) }
    }
}

@MainActor
final class MockMainWindowController: MainWindowControlling {
    var isReadyForKeyboardCleaning = true
    var hideCallCount = 0
    var showAndFocusCallCount = 0

    func hide() {
        hideCallCount += 1
    }

    func showAndFocus() {
        showAndFocusCallCount += 1
    }
}
