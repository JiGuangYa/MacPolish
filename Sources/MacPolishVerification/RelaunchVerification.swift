import AppKit
import MacPolishKit

@MainActor
enum RelaunchVerification {
    static func run() async throws {
        let bundle = try RelaunchTestBundle()
        defer { bundle.remove() }
        verifyInvalidBundleIsNotLaunched(bundle)
        verifyInvalidResponsesDoNotQuit(bundle)
        verifyFailureRetryAndStaleCallbacks(bundle)
        verifyDuplicateRequests(bundle)
        verifyControllerHandoff()
        verifyReleaseWhileWaiting(bundle)
        await verifyReadinessAndEarlyExit(bundle)
        await verifyTimeoutAndLateResponse(bundle)
    }

    private static func verifyInvalidBundleIsNotLaunched(_ bundle: RelaunchTestBundle) {
        for url in [bundle.directory, bundle.directory.appendingPathComponent("Missing.app")] {
            let fixture = RelaunchFixture(url: url)
            fixture.relaunch()
            require(fixture.state.results == [false], "Expected unpackaged or missing apps to fail without quitting")
            require(fixture.launcher.urls.isEmpty, "Expected invalid bundles not to reach Launch Services")
            require(fixture.state.terminationCount == 0, "Expected invalid bundles to preserve the current app")
        }
    }

    private static func verifyInvalidResponsesDoNotQuit(_ bundle: RelaunchTestBundle) {
        for scenario in ["same-process", "no-process", "wrong-bundle", "no-bundle", "terminated"] {
            let fixture = RelaunchFixture(url: bundle.url)
            let app = TestRelaunchedApplication(bundleURL: bundle.url)
            switch scenario {
            case "same-process": app.processIdentifier = fixture.currentPID
            case "no-process": app.processIdentifier = 0
            case "wrong-bundle": app.bundleURL = bundle.directory.appendingPathComponent("Other.app")
            case "no-bundle": app.bundleURL = nil
            default: app.isTerminated = true
            }
            fixture.relaunch()
            fixture.launcher.completions[0](app)
            require(fixture.state.results == [false], "Expected \(scenario) never to be accepted as a successful restart")
            require(fixture.state.terminationCount == 0, "Expected \(scenario) to preserve the current process")
        }
    }

    private static func verifyFailureRetryAndStaleCallbacks(_ bundle: RelaunchTestBundle) {
        let fixture = RelaunchFixture(url: bundle.url)
        fixture.relaunch()
        fixture.launcher.completions[0](nil)
        require(fixture.state.results == [false], "Expected launch errors to report failure")
        fixture.relaunch()
        let app = TestRelaunchedApplication(bundleURL: bundle.url)
        fixture.launcher.completions[0](app)
        require(fixture.state.terminationCount == 0, "Expected a stale response not to terminate the current app")
        require(fixture.state.results == [false], "Expected a stale response not to complete a newer request")
        fixture.launcher.completions[1](app)
        require(fixture.state.results == [false, true], "Expected a retry to report success when a new instance is ready")
        require(fixture.state.terminationCount == 1, "Expected exactly one termination after successful handoff")
        fixture.launcher.completions[1](app)
        require(fixture.state.terminationCount == 1, "Expected repeated native callbacks to be harmless")
    }

    private static func verifyDuplicateRequests(_ bundle: RelaunchTestBundle) {
        let fixture = RelaunchFixture(url: bundle.url)
        fixture.relaunch()
        fixture.relaunch()
        require(fixture.launcher.urls == [bundle.url], "Expected only one app instance to be launched for overlapping requests")
        require(fixture.state.results == [false], "Expected a duplicate caller to be rejected while the first keeps waiting")
        fixture.launcher.completions[0](TestRelaunchedApplication(bundleURL: bundle.url))
        fixture.relaunch()
        require(fixture.launcher.urls.count == 1, "Expected completed handoff not to start more app instances")
        require(fixture.state.terminationCount == 1, "Expected duplicate requests not to duplicate termination")
    }

    private static func verifyControllerHandoff() {
        let relauncher = MockApplicationRelauncher()
        relauncher.completesImmediately = false
        let keyboard = MockKeyboardCaptureService(permissionState: .granted)
        let shield = MockScreenShieldService()
        let settings = MockSettingsOpener()
        let controller = CleaningSessionController(
            appSettings: AppSettings(userDefaults: MacPolishVerification.testUserDefaults()),
            screenShieldService: shield, keyboardCaptureService: keyboard, settingsOpener: settings,
            applicationController: MockApplicationController(), applicationRelauncher: relauncher,
            notificationCenter: NotificationCenter(), workspaceNotificationCenter: NotificationCenter()
        )
        controller.relaunchApplication()
        require(controller.isRelaunching, "Expected reopening to be visible while awaiting the system result")
        for mode in CleaningMode.allCases {
            require(!controller.canPerformPrimaryAction(for: mode), "Expected cleaning actions to be disabled during handoff")
            controller.startCleaning(mode: mode)
            controller.performPrimaryAction(for: mode)
        }
        controller.requestKeyboardPermission()
        controller.openKeyboardPermissionSettings()
        controller.relaunchApplication()
        require(shield.startCallHistory.isEmpty, "Expected no new cleaning sessions during handoff")
        require(keyboard.requestPermissionCallCount == 0 && settings.openCallCount == 0, "Expected no competing permission UI during handoff")
        require(relauncher.relaunchCallCount == 1, "Expected duplicate reopen actions not to reach the launcher")
        require(!controller.canStartWholeMac && !controller.canStartKeyboardOnly, "Expected all entry points to honor handoff state")

        relauncher.completions[0](false)
        require(!controller.isRelaunching, "Expected failure to restore app controls")
        require(controller.notice == .relaunchFailed, "Expected failure to explain that the current app remains running")
        controller.relaunchApplication()
        require(controller.notice == nil, "Expected a retry to clear the old failure")
        relauncher.completions[0](false)
        require(controller.isRelaunching, "Expected an old completion not to cancel a newer handoff")
        relauncher.completions[1](false)
        controller.startCleaning(mode: .screenOnly)
        require(controller.isCleaning && controller.notice == nil, "Expected cleaning to remain usable after failed reopening")
        controller.relaunchApplication()
        require(relauncher.relaunchCallCount == 2, "Expected cleaning to prevent app relaunch")
        controller.stopCleaning(trigger: .button)
        controller.relaunchApplication()
        relauncher.completions[2](true)
        require(controller.isRelaunching, "Expected controls to stay disabled until a successful handoff terminates this instance")
        relauncher.completions[2](false)
        require(controller.notice == nil && controller.isRelaunching, "Expected duplicate completion after handoff to be ignored")
    }

    private static func verifyReleaseWhileWaiting(_ bundle: RelaunchTestBundle) {
        let launcher = TestApplicationLauncher()
        let state = RelaunchTestState()
        weak var weakRelauncher: AppRelauncher?
        autoreleasepool {
            let relauncher = AppRelauncher(applicationURL: bundle.url, currentProcessIdentifier: 1, launcher: launcher,
                terminateCurrentApplication: { state.terminationCount += 1 })
            relauncher.relaunch { state.results.append($0) }
            weakRelauncher = relauncher
        }
        require(weakRelauncher == nil, "Expected pending launch callbacks and timers not to retain the relauncher")
        launcher.completions[0](TestRelaunchedApplication(bundleURL: bundle.url))
        require(state.terminationCount == 0, "Expected callbacks after owner release never to terminate the app")
    }

    private static func verifyReadinessAndEarlyExit(_ bundle: RelaunchTestBundle) async {
        for terminatesEarly in [false, true] {
            let fixture = RelaunchFixture(url: bundle.url)
            let app = TestRelaunchedApplication(bundleURL: bundle.url)
            app.isFinishedLaunching = false
            fixture.relaunch()
            fixture.launcher.completions[0](app)
            require(fixture.state.results.isEmpty && fixture.state.terminationCount == 0, "Expected process creation alone not to end the current app")
            if terminatesEarly { app.isTerminated = true } else { app.isFinishedLaunching = true }
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(25))
                if !fixture.state.results.isEmpty { break }
            }
            require(fixture.state.results == [!terminatesEarly], "Expected handoff only after successful app initialization")
            require(fixture.state.terminationCount == (terminatesEarly ? 0 : 1), "Expected early launch failure not to quit the current app")
        }
    }

    private static func verifyTimeoutAndLateResponse(_ bundle: RelaunchTestBundle) async {
        for returnsBeforeTimeout in [false, true] {
            let fixture = RelaunchFixture(url: bundle.url, timeout: .milliseconds(75))
            let app = TestRelaunchedApplication(bundleURL: bundle.url)
            app.isFinishedLaunching = false
            fixture.relaunch()
            if returnsBeforeTimeout { fixture.launcher.completions[0](app) }
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(25))
                if !fixture.state.results.isEmpty { break }
            }
            require(fixture.state.results == [false], "Expected missing or incomplete launches to time out")
            require(fixture.state.terminationCount == 0, "Expected timeout to preserve the current app")
            fixture.relaunch()
            app.isFinishedLaunching = true
            fixture.launcher.completions[0](app)
            require(fixture.state.terminationCount == 0, "Expected late success after timeout to be ignored")
            fixture.launcher.completions[1](app)
            require(fixture.state.results == [false, true], "Expected timeout not to prevent a successful retry")
            try? await Task.sleep(for: .milliseconds(150))
            require(fixture.state.results == [false, true] && fixture.state.terminationCount == 1, "Expected cancelled timeout tasks not to change a successful handoff")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        MacPolishVerification.require(condition(), message)
    }
}

@MainActor
private final class RelaunchFixture {
    let currentPID: pid_t = 123
    let launcher = TestApplicationLauncher()
    let state = RelaunchTestState()
    let relauncher: AppRelauncher

    init(url: URL, timeout: Duration = .seconds(2)) {
        let state = state
        relauncher = AppRelauncher(applicationURL: url, currentProcessIdentifier: currentPID, launcher: launcher,
            timeout: timeout, terminateCurrentApplication: { state.terminationCount += 1 })
    }

    func relaunch() {
        relauncher.relaunch { [state] in state.results.append($0) }
    }
}

@MainActor
private final class RelaunchTestState {
    var results: [Bool] = []
    var terminationCount = 0
}

@MainActor
private final class TestApplicationLauncher: ApplicationInstanceLaunching {
    var urls: [URL] = []
    var completions: [@MainActor ((any RelaunchedApplication)?) -> Void] = []
    func launch(at url: URL, completion: @escaping @MainActor ((any RelaunchedApplication)?) -> Void) {
        urls.append(url)
        completions.append(completion)
    }
}

@MainActor
private final class TestRelaunchedApplication: RelaunchedApplication {
    var processIdentifier: pid_t = 456
    var bundleURL: URL?
    var isFinishedLaunching = true
    var isTerminated = false
    init(bundleURL: URL) { self.bundleURL = bundleURL }
}

private struct RelaunchTestBundle {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacPolishRelaunch-\(UUID().uuidString)")
        url = directory.appendingPathComponent("MacPolish.app")
        let executable = url.appendingPathComponent("Contents/MacOS/Probe")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info: [String: Any] = ["CFBundleIdentifier": "com.jiguang.MacPolish.Verification.\(UUID().uuidString)",
                                  "CFBundleExecutable": "Probe", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
