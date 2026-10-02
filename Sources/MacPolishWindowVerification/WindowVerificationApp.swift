import AppKit
import Combine
import MacPolishKit
import SwiftUI

@main
struct WindowVerificationApp: App {
    @NSApplicationDelegateAdaptor(WindowVerificationDelegate.self) private var delegate
    @StateObject private var probe = WindowFlowProbe.shared

    var body: some Scene {
        MacPolishScenes(sessionController: probe.controller, appSettings: probe.settings, windowTitle: WindowFlowProbe.windowTitle)
    }
}

@MainActor
private final class WindowVerificationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let probe = WindowFlowProbe.shared
        probe.recordStage("applicationDidFinishLaunching")
        if let index = CommandLine.arguments.firstIndex(of: "--previous-app"), CommandLine.arguments.indices.contains(index + 1),
           let pid = Int32(CommandLine.arguments[index + 1]), pid > 0 {
            probe.previousApplication = NSRunningApplication(processIdentifier: pid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            probe.finish(error: "Native window verification exceeded its 30-second deadline.")
        }
        Task { await probe.run() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Opt-in desktop integration test. Only the keyboard, shield, permission
/// opener, and relauncher are substituted; the app scenes and menus are real.
@MainActor
private final class WindowFlowProbe: ObservableObject {
    static let shared = WindowFlowProbe()
    static let windowTitle = "MacPolish Window Verification — keyboard remains available"

    let settings: AppSettings
    let controller: CleaningSessionController
    let keyboard = ProbeKeyboard()
    let settingsOpener = ProbeSettingsOpener()
    let resultURL: URL
    let defaultsSuite: String
    var previousApplication: NSRunningApplication?
    private var checks: [String] = []
    private var didFinish = false
    private var trackedMenu: NSMenu?

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "MacPolishWindowVerification") as? Bool == true,
              let index = CommandLine.arguments.firstIndex(of: "--result"), CommandLine.arguments.indices.contains(index + 1),
              CommandLine.arguments[index + 1].hasPrefix("/") else {
            fputs("Run this opt-in desktop probe with scripts/verify_window_flow.py.\n", stderr)
            exit(EXIT_FAILURE)
        }
        resultURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        defaultsSuite = "MacPolish.WindowVerification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        settings = AppSettings(userDefaults: defaults)
        settings.showMenuBarItem = false
        controller = CleaningSessionController(appSettings: settings, screenShieldService: ProbeShield(),
            keyboardCaptureService: keyboard, settingsOpener: settingsOpener,
            applicationController: NSApplication.shared, applicationRelauncher: ProbeRelauncher())
        try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8)
            .write(to: resultURL.appendingPathExtension("pid"), options: .atomic)
        recordStage("initialized")
    }

    func run() async {
        do {
            try await waitUntil("initial window construction") {
                NSApp.windows.contains { $0.title == Self.windowTitle && $0.isVisible }
            }
            NSApp.windows.first { $0.title == Self.windowTitle && $0.isVisible }?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await waitUntil("initial main window") { self.readyWindow != nil }
            if CommandLine.arguments.contains("--settings-only") {
                try await verifyNativeSettingsAccessibility()
                finish(error: nil)
                return
            }
            if CommandLine.arguments.contains("--shield-only") {
                try await verifyAccessibleShieldExit()
                finish(error: nil)
                return
            }
            try await startKeyboardFromMenu()
            try await exitFromMenu()
            checks.append("A real Cleaning menu action starts and ends keyboard cleaning with a focused main window.")

            guard let firstWindow = readyWindow else { throw ProbeFailure("Missing initial window") }
            firstWindow.performClose(nil)
            try await waitUntil("main window closure") { !firstWindow.isVisible }
            try await startKeyboardFromMenu()
            guard let reopened = readyWindow else { throw ProbeFailure("Missing reopened window") }
            checks.append("The production SwiftUI openWindow action restores a closed main window before capture starts.")
            reopened.performClose(nil)
            try await waitUntil("cleanup after closing a cleaning window") { !self.controller.isCleaning && !self.keyboard.isCapturing }
            try require(controller.lastExitTrigger == .mainWindowUnavailable, "Closing the active native window must end keyboard cleaning")
            checks.append("A real window-close notification releases capture and preserves the exit reason.")

            try await startKeyboardFromMenu()
            try await exitFromMenu()
            guard let window = readyWindow else { throw ProbeFailure("Missing window before minimization") }
            window.miniaturize(nil)
            try await waitUntil("idle window minimization") { window.isMiniaturized }
            try await startKeyboardFromMenu()
            guard let restored = readyWindow else { throw ProbeFailure("Missing restored window") }
            try require(!restored.isMiniaturized, "The menu must restore a minimized window before capture")
            checks.append("Starting through the native menu restores a minimized main window.")
            restored.miniaturize(nil)
            try await waitUntil("cleanup after minimizing a cleaning window") { !self.controller.isCleaning && !self.keyboard.isCapturing }
            try require(controller.lastExitTrigger == .mainWindowUnavailable, "Minimizing the active native window must end cleaning")
            checks.append("A real minimize notification releases capture.")

            restored.deminiaturize(nil)
            restored.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await waitUntil("window restoration before screen cleaning") { self.readyWindow != nil }
            try await invokeMenuItem(.menuStartScreenOnly)
            try await waitUntil("screen cleaning") { self.controller.activeMode == .screenOnly }
            try prepareNativeMenu()
            try await waitUntil("Screen Only Escape binding") { self.menuItem(.menuExitCleaning)?.keyEquivalent == "\u{1b}" }
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: restored.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            try require(NSApp.mainMenu?.performKeyEquivalent(with: escape) == true, "The native menu must handle Escape in Screen Only")
            try await waitUntil("Screen Only Escape exit") { !self.controller.isCleaning }
            checks.append("The installed native menu binds Escape in Screen Only and omits it while keys are protected.")

            let captureCount = keyboard.starts.count
            keyboard.permissionState = .denied
            controller.refreshKeyboardProtectionAvailability()
            readyWindow?.performClose(nil)
            try await invokeMenuItem(.actionOpenSystemSettings)
            try await waitUntil("permission action after restoring the main window") { self.settingsOpener.openCount == 1 }
            try require(readyWindow != nil && keyboard.starts.count == captureCount && !controller.isCleaning,
                "Permission recovery must restore its explanation window without capturing input")
            checks.append("The permission menu restores the main window and invokes recovery without starting capture.")
            readyWindow?.performClose(nil)
            try await invokeMenuItem(.menuStartWholeMac)
            try await waitUntil("local Whole Mac cleaning from the native menu") { self.controller.activeMode == .wholeMac }
            try require(readyWindow != nil && controller.activeKeyboardProtection == .local && keyboard.starts.count == captureCount,
                "Local Whole Mac cleaning must restore foreground focus before showing its shields")
            try await exitFromMenu()
            checks.append("The native Whole Mac menu restores a closed window before starting local protection.")
            try require(keyboard.starts.allSatisfy { $0.windowWasReady }, "Every capture start must have a visible focused window on the active Space")
            try require(!settings.showMenuBarItem, "Temporary cleaning controls must preserve the user's menu bar preference")
            checks.append("Temporary menu bar insertion preserves the disabled preference without an update loop.")
            try await verifyNativeSettingsAccessibility()
            try await verifyAccessibleShieldExit()
            finish(error: nil)
        } catch {
            finish(error: String(describing: error))
        }
    }

    private func startKeyboardFromMenu() async throws {
        let previousCount = keyboard.starts.count
        try await invokeMenuItem(.modeKeyboardOnlyAction)
        try await waitUntil("keyboard cleaning after menu action") { self.controller.activeMode == .keyboardOnly }
        try require(keyboard.starts.count == previousCount + 1, "A menu action must start exactly one capture")
        try require(keyboard.starts.last?.windowWasReady == true, "Capture started before the native window became ready")
        try await waitUntil("protected exit menu binding") { self.menuItem(.menuExitCleaning)?.keyEquivalent == "" }
    }

    private func exitFromMenu() async throws {
        try await invokeMenuItem(.menuExitCleaning)
        try await waitUntil("cleaning exit") { !self.controller.isCleaning && !self.keyboard.isCapturing }
    }

    private var readyWindow: NSWindow? {
        NSApp.windows.first {
            $0.title == Self.windowTitle && $0.isVisible && $0.isKeyWindow && !$0.isMiniaturized && $0.isOnActiveSpace && NSApp.isActive
        }
    }

    private var cleaningMenu: NSMenu? {
        NSApp.mainMenu?.items.first { $0.title == L10n.string(.menuCleaning) }?.submenu
    }

    private func menuItem(_ key: LocalizationKey) -> NSMenuItem? {
        cleaningMenu?.update()
        return cleaningMenu?.item(withTitle: L10n.string(key))
    }

    private func invokeMenuItem(_ key: LocalizationKey) async throws {
        try prepareNativeMenu()
        try await waitUntil("enabled menu item: \(key.rawValue)") { self.menuItem(key)?.isEnabled == true }
        guard let menu = cleaningMenu, let item = menu.item(withTitle: L10n.string(key)) else {
            throw ProbeFailure("Menu disappeared before action: \(key.rawValue)")
        }
        menu.performActionForItem(at: menu.index(of: item))
    }

    private func prepareNativeMenu() throws {
        guard let menu = cleaningMenu else { throw ProbeFailure("Missing native Cleaning menu") }
        prepareNativeMenu(menu)
    }

    private func prepareNativeMenu(_ menu: NSMenu) {
        // SwiftUI populates command menus lazily when AppKit opens them.
        // NSMenu.update() only performs item validation, not that population.
        trackedMenu = menu
        let close = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackedMenu?.cancelTrackingWithoutAnimation() }
        }
        RunLoop.main.add(close, forMode: .common)
        defer {
            close.invalidate()
            trackedMenu = nil
        }
        let frame = NSApp.keyWindow?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 300, height: 300)
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX + 40, y: frame.maxY - 80), in: nil)
    }

    private func verifyNativeSettingsAccessibility() async throws {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { throw ProbeFailure("Missing app menu") }
        prepareNativeMenu(appMenu)
        guard let item = appMenu.items.first(where: { $0.keyEquivalent == "," }) else {
            throw ProbeFailure("Missing native Settings menu item")
        }
        let previousWindows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        appMenu.performActionForItem(at: appMenu.index(of: item))
        try await waitUntil("native Settings window") {
            NSApp.windows.contains { $0.isVisible && !previousWindows.contains(ObjectIdentifier($0)) }
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && !previousWindows.contains(ObjectIdentifier($0)) }) else {
            throw ProbeFailure("Missing opened Settings window")
        }
        defer { window.performClose(nil) }
        try await waitUntil("resizable Settings window") { window.styleMask.contains(.resizable) }
        window.setContentSize(NSSize(width: 560, height: 780))
        try await waitUntil("expanded Settings content") { abs((window.contentView?.bounds.height ?? 0) - 780) < 1 }
        if let root = window.contentView {
            var views = [root]
            while let view = views.popLast() {
                if let scroll = view as? NSScrollView, let document = scroll.documentView {
                    let y = document.isFlipped ? document.bounds.maxY - 1 : document.bounds.minY
                    document.scrollToVisible(NSRect(x: document.bounds.minX, y: y, width: 1, height: 1))
                }
                views.append(contentsOf: view.subviews)
            }
        }
        let label = L10n.string(.settingsControlFadeDelay)
        let expected = String(format: L10n.string(.settingsFadeDelayValue), locale: Locale.current, settings.clampedFadeDelay)
        let before = settings.clampedFadeDelay
        let slider = try await NativeAccessibilityProbe.slider(in: window)
        try require(slider.isAccessibilityEnabled(), "The fade slider must be accessible while automatic fade is enabled")
        let value = slider.accessibilityValueDescription() ?? slider.accessibilityValue() as? String
        try require(slider.accessibilityLabel() == label && value == expected,
            "The native fade slider must expose its localized name and value in seconds")
        try NativeAccessibilityProbe.adjust(slider, increase: true)
        try await waitUntil("slider accessibility adjustment") { self.settings.clampedFadeDelay > before }
        try require(abs(settings.clampedFadeDelay - before - 0.1) < 0.001,
            "Accessibility adjustment must move in 0.1-second steps: \(before) → \(settings.clampedFadeDelay); element=\(type(of: slider))")
        let updated = String(format: L10n.string(.settingsFadeDelayValue), locale: Locale.current, settings.clampedFadeDelay)
        let updatedSlider = try await NativeAccessibilityProbe.slider(in: window)
        try require((updatedSlider.accessibilityValueDescription() ?? updatedSlider.accessibilityValue() as? String) == updated,
            "The accessibility value must follow slider adjustments")
        try NativeAccessibilityProbe.adjust(updatedSlider, increase: false)
        try await waitUntil("slider accessibility restoration") { abs(self.settings.clampedFadeDelay - before) < 0.001 }
        checks.append("The native Settings slider has a localized label and seconds value, and supports accessibility adjustment.")
        settings.revealControlsOnPointerMovement = false
        defer { settings.revealControlsOnPointerMovement = true }
        let disabledSlider = try await NativeAccessibilityProbe.slider(in: window)
        try await waitUntil("disabled fade slider") { !disabledSlider.isAccessibilityEnabled() }
        try require(abs(settings.clampedFadeDelay - before) < 0.001, "Disabling fade must preserve the chosen delay")
        checks.append("Settings can resize vertically, and disabling control fade disables its accessibility slider without losing the delay.")
    }

    private func verifyAccessibleShieldExit() async throws {
        let previousDelay = settings.controlFadeDelay
        let previousReveal = settings.revealControlsOnPointerMovement
        settings.controlFadeDelay = 1.5
        settings.revealControlsOnPointerMovement = true
        defer {
            settings.controlFadeDelay = previousDelay
            settings.revealControlsOnPointerMovement = previousReveal
        }
        let assistiveTechnology = CurrentValueSubject<Bool, Never>(true)
        let model = ShieldPresentationModel(appSettings: settings, reduceMotion: true,
            assistiveTechnologyEnabled: assistiveTechnology.eraseToAnyPublisher())
        var exits = 0
        // Render the production shield view in an ordinary small window. No
        // screen-covering window, input filter, or system preference is used.
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 560, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Exit control verification — keyboard remains available"
        window.isReleasedWhenClosed = false
        let content = ShieldHostingView(rootView: ShieldContentView(model: model,
            emergencyExitGesture: EmergencyExitGesture(), mode: .wholeMac, keyboardProtection: .local,
            onExit: { exits += 1 }))
        window.contentView = content
        content.frame = NSRect(origin: .zero, size: NSSize(width: 560, height: 320))
        content.layoutSubtreeIfNeeded()
        defer {
            model.stopPresentationCycle()
            window.close()
        }
        model.startPresentationCycle()
        window.makeKeyAndOrderFront(nil)
        let exitLabel = L10n.string(.accessibilityExitCleaning)
        _ = try await NativeAccessibilityProbe.element(withRole: .button, label: exitLabel, in: window)
        try require(window.contentRect(forFrameRect: window.frame).size == NSSize(width: 560, height: 320),
            "Shield content must preserve the native window's assigned size")
        assistiveTechnology.send(false)
        try await waitUntil("ordinary shield-control fade") {
            !model.showsChrome && NativeAccessibilityProbe.findElement(withRole: .button, label: exitLabel, in: window) == nil
        }

        assistiveTechnology.send(true)
        _ = try await NativeAccessibilityProbe.element(withRole: .button, label: exitLabel, in: window)
        try await Task.sleep(for: .milliseconds(1_700))
        try require(model.showsChrome && NativeAccessibilityProbe.findElement(withRole: .button, label: exitLabel, in: window) != nil,
            "The native exit control must remain accessible beyond its normal fade delay while assistive technology is active")
        assistiveTechnology.send(false)
        try await waitUntil("restored shield fade preference") {
            !model.showsChrome && NativeAccessibilityProbe.findElement(withRole: .button, label: exitLabel, in: window) == nil
        }
        try require(settings.revealControlsOnPointerMovement && settings.clampedFadeDelay == 1.5,
            "Accessibility must not overwrite the saved fade preference")
        checks.append("The production shield keeps its native exit button accessible while simulated assistive technology is active, then resumes the saved fade behavior.")

        assistiveTechnology.send(true)
        let exitButton = try await NativeAccessibilityProbe.element(withRole: .button, label: exitLabel, in: window)
        try require(exitButton.isAccessibilityEnabled(), "The accessible exit button must remain enabled")
        try NativeAccessibilityProbe.perform(.press, on: exitButton)
        try await waitUntil("accessible shield exit action") { exits == 1 }
        checks.append("The shield's native accessibility press action invokes its exit callback exactly once.")
    }

    private func waitUntil(_ stage: String, condition: () -> Bool) async throws {
        recordStage(stage)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProbeFailure("Timed out waiting for \(stage)") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ProbeFailure(message) }
    }

    func recordStage(_ stage: String) {
        try? Data(stage.utf8).write(to: resultURL.appendingPathExtension("stage"), options: .atomic)
    }

    func finish(error: String?) {
        guard !didFinish else { return }
        didFinish = true
        let diagnostics = NSApp.windows.map {
            "\($0.title): visible=\($0.isVisible), key=\($0.isKeyWindow), minimized=\($0.isMiniaturized), activeSpace=\($0.isOnActiveSpace)"
        }
        let menuTitles = cleaningMenu?.items.map { "\($0.title) [enabled=\($0.isEnabled), key=\($0.keyEquivalent)]" } ?? []
        let report = ProbeReport(status: error == nil ? "passed" : "failed", checks: checks, error: error,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            processIdentifier: ProcessInfo.processInfo.processIdentifier, captureStarts: keyboard.starts,
            applicationIsActive: NSApp.isActive,
            sessionDiagnostics: "cleaning=\(controller.isCleaning), mode=\(String(describing: controller.activeMode)), exit=\(String(describing: controller.lastExitTrigger)), notice=\(String(describing: controller.notice))",
            installedGlobalEventTap: false, postedSystemInput: false, windowDiagnostics: diagnostics, menuDiagnostics: menuTitles)
        controller.stopCleaning(trigger: .applicationTerminating)
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: resultURL, options: .atomic)
        } catch { fputs("Could not write window verification report: \(error)\n", stderr) }
        if NSApp.isActive, let previousApplication,
           previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier, !previousApplication.isTerminated {
            if #available(macOS 14, *) { NSApp.yieldActivation(to: previousApplication) }
            previousApplication.activate(options: [])
        }
        NSApp.terminate(nil)
    }
}

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct CaptureStart: Codable {
    let windowWasReady: Bool
    let windowTitle: String?
}

private struct ProbeReport: Codable {
    let status: String
    let checks: [String]
    let error: String?
    let systemVersion: String
    let processIdentifier: Int32
    let captureStarts: [CaptureStart]
    let applicationIsActive: Bool
    let sessionDiagnostics: String
    let installedGlobalEventTap: Bool
    let postedSystemInput: Bool
    let windowDiagnostics: [String]
    let menuDiagnostics: [String]
}

@MainActor
private final class ProbeKeyboard: KeyboardCapturing {
    var permissionState: KeyboardPermissionState = .granted
    var isCapturing = false
    var isSecureInputEnabled: Bool { false }
    var starts: [CaptureStart] = []
    func refreshPermissionState() -> KeyboardPermissionState { permissionState }
    func requestPermission() -> KeyboardPermissionState { permissionState }
    func probeCaptureAvailability() -> Bool { permissionState == .granted }
    func startCapturing(for mode: CleaningMode, onEmergencyInput: @escaping @MainActor (EmergencyExitInput) -> Void) -> Bool {
        let window = NSApp.keyWindow
        let ready = NSApp.isActive && window?.title == WindowFlowProbe.windowTitle && window?.isVisible == true
            && window?.isMiniaturized == false && window?.isOnActiveSpace == true
        starts.append(CaptureStart(windowWasReady: ready, windowTitle: window?.title))
        isCapturing = permissionState == .granted
        return isCapturing
    }
    func stopCapturing() { isCapturing = false }
}

@MainActor
private final class ProbeShield: ScreenShielding {
    func start(mode: CleaningMode, keyboardProtection: KeyboardProtection, onExit: @escaping @MainActor (ExitTrigger) -> Void) -> Bool { true }
    func stop() { }
}

@MainActor
private final class ProbeSettingsOpener: KeyboardPermissionOpening {
    var openCount = 0
    func openInputMonitoringSettings() { openCount += 1 }
}

@MainActor
private final class ProbeRelauncher: ApplicationRelaunching {
    func relaunch(completion: @escaping @MainActor (Bool) -> Void) { completion(false) }
}
