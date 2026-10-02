import AppKit
import Combine
import MacPolishKit
import SwiftUI

/// Renders the actual product views with fake services. It never installs a
/// keyboard event tap, requests permission, or shows a window on the desktop.
@MainActor
enum PreviewRenderer {
    static func render(to directory: URL) async throws {
        defer { MacPolishVerification.cleanupTestDefaults() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scenarios = ["ready", "permission", "keyboard", "local", "interrupted", "secure-input", "compact", "settings", "settings-secure-input",
                         "relaunching", "relaunch-failed", "settings-relaunching", "settings-relaunch-failed",
                         "keyboard-hold", "shield", "shield-hold", "shield-hold-no-hints", "shield-screen",
                         "opening-window", "opening-window-failed", "space-interrupted", "settings-full", "settings-always-visible",
                         "shield-accessible", "shield-accessible-no-hints",
                         "keyboard-compact", "keyboard-hold-compact", "settings-compact",
                         "keyboard-high-contrast-compact", "keyboard-hold-high-contrast-compact", "settings-high-contrast-compact",
                         "permission-first-use", "permission-first-use-compact", "settings-permission-first-use", "settings-permission-denied"]
        for dark in [false, true] {
            for scenario in scenarios {
                let settings = AppSettings(userDefaults: MacPolishVerification.testUserDefaults())
                if scenario == "settings-always-visible" { settings.revealControlsOnPointerMovement = false }
                var uptime: TimeInterval = 0
                var sessionUptime: TimeInterval = 0
                let gesture = EmergencyExitGesture(holdDuration: 3, uptime: { uptime })
                let permission: KeyboardPermissionState = if scenario.contains("permission-first-use") {
                    .notDetermined
                } else if scenario == "permission" || scenario == "settings-permission-denied" || scenario == "local" {
                    .denied
                } else {
                    .granted
                }
                let keyboard = MockKeyboardCaptureService(permissionState: permission)
                keyboard.isSecureInputEnabled = scenario == "secure-input" || scenario == "settings-secure-input"
                let relauncher = MockApplicationRelauncher()
                relauncher.completesImmediately = !scenario.hasSuffix("relaunching")
                let mainWindow = MockMainWindowController()
                mainWindow.isReadyForKeyboardCleaning = !scenario.hasPrefix("opening-window")
                let controller = CleaningSessionController(
                    appSettings: settings,
                    emergencyExitGesture: gesture,
                    screenShieldService: MockScreenShieldService(),
                    keyboardCaptureService: keyboard,
                    settingsOpener: MockSettingsOpener(),
                    applicationController: MockApplicationController(),
                    applicationRelauncher: relauncher,
                    mainWindowController: mainWindow,
                    dateProvider: { Date().addingTimeInterval(-90) },
                    uptimeProvider: { sessionUptime },
                    mainWindowOpeningTimeout: scenario == "opening-window-failed" ? 0.06 : 5,
                    notificationCenter: NotificationCenter(),
                    workspaceNotificationCenter: NotificationCenter()
                )
                if scenario.hasPrefix("keyboard") || scenario == "interrupted" || scenario == "space-interrupted" {
                    controller.startCleaning(mode: .keyboardOnly)
                } else if scenario == "shield-screen" {
                    controller.startCleaning(mode: .screenOnly)
                } else if scenario == "local" || scenario.hasPrefix("shield") {
                    controller.startCleaning(mode: .wholeMac)
                }
                if scenario.contains("hold") {
                    gesture.handle(.escapeChanged(isDown: true, isRepeat: false, modifiersHeld: true))
                    uptime = 1.4
                    gesture.updateProgress()
                }
                sessionUptime = 90
                if scenario == "interrupted" {
                    keyboard.isCapturing = false
                    controller.refreshKeyboardProtectionAvailability()
                }
                if scenario == "space-interrupted" {
                    controller.stopCleaning(trigger: .mainWindowLeftActiveSpace)
                }
                if scenario.contains("relaunch") {
                    keyboard.startCapturingResult = false
                    controller.startCleaning(mode: .keyboardOnly)
                    controller.relaunchApplication()
                }
                if scenario.hasPrefix("opening-window") {
                    controller.performPrimaryActionFromMenu(for: .keyboardOnly) { }
                    if scenario == "opening-window-failed" {
                        try await Task.sleep(for: .milliseconds(150))
                        MacPolishVerification.require(controller.notice == .mainWindowOpeningFailed,
                            "Expected the preview to use an actual window-opening timeout")
                    }
                }

                let content: AnyView
                let size: NSSize
                if scenario.hasPrefix("shield") {
                    settings.showExitHints = !scenario.hasSuffix("no-hints")
                    let accessibilityActive = scenario.hasPrefix("shield-accessible")
                    if accessibilityActive { settings.controlFadeDelay = 1.5 }
                    let model = ShieldPresentationModel(appSettings: settings, reduceMotion: true,
                        assistiveTechnologyEnabled: Just(accessibilityActive).eraseToAnyPublisher())
                    model.startPresentationCycle()
                    if accessibilityActive {
                        try await Task.sleep(for: .milliseconds(1_650))
                        MacPolishVerification.require(model.showsChrome && model.showsHint == settings.showExitHints,
                            "Expected accessible shield previews to retain the exit control beyond its fade delay")
                    }
                    content = AnyView(ShieldContentView(model: model, emergencyExitGesture: gesture,
                        mode: controller.activeMode!, keyboardProtection: controller.activeKeyboardProtection, onExit: { }))
                    size = NSSize(width: 1040, height: 600)
                } else if scenario.hasPrefix("settings") {
                    content = AnyView(SettingsView(sessionController: controller, appSettings: settings))
                    size = NSSize(width: 560, height: scenario.hasSuffix("-compact") ? 420
                        : (scenario == "settings-full" || scenario == "settings-always-visible" ? 1_000 : 520))
                } else {
                    content = AnyView(MainView(sessionController: controller, appSettings: settings))
                    let compactSession = scenario.hasSuffix("-compact")
                    size = NSSize(width: scenario == "compact" || compactSession ? 640 : 1040,
                        height: compactSession ? 420 : (scenario == "compact" ? 900 : (scenario == "permission-first-use" ? 560 : 600)))
                }

                let highContrast = scenario.contains("high-contrast")
                var observedAccessibility: PreviewAccessibilityState?
                let view = NSHostingView(rootView: PreviewAppearanceProbe(content: content) { observedAccessibility = $0 }
                    .environment(\.colorScheme, dark ? .dark : .light)
                    // SwiftUI exposes only read access for these public values.
                    // Use its underscored overrides solely in this preview tool,
                    // never in the shipping target or the user's system settings.
                    .environment(\._colorSchemeContrast, highContrast ? .increased : .standard)
                    .environment(\._accessibilityReduceTransparency, highContrast)
                    .environment(\._accessibilityReduceMotion, highContrast)
                    .environment(\.controlActiveState, .key))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: highContrast
                    ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                    : (dark ? .darkAqua : .aqua))
                window.contentView = view
                view.frame = NSRect(origin: .zero, size: size)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                view.layoutSubtreeIfNeeded()
                if scenario == "permission-first-use-compact" {
                    try await revealBottomOfScrollView(in: view)
                }
                MacPolishVerification.require(observedAccessibility == PreviewAccessibilityState(
                    contrast: highContrast ? .increased : .standard,
                    reducesTransparency: highContrast, reducesMotion: highContrast),
                    "Expected the requested accessibility state to reach the rendered SwiftUI environment")

                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try png.write(to: directory.appendingPathComponent("\(scenario)-\(dark ? "dark" : "light").png"), options: .atomic)
                controller.stopCleaning(trigger: .applicationTerminating)
                window.close()
            }
        }
        print("Rendered \(scenarios.count * 2) previews to \(directory.path); language: \(L10n.string(.statusCleaning))")
    }

    /// At the minimum window size the keyboard card is below the first row.
    /// Capture the actual scrolled viewport so its authorization copy is checked.
    private static func revealBottomOfScrollView(in view: NSView) async throws {
        guard let scrollView = firstScrollView(in: view), let document = scrollView.documentView else {
            throw CocoaError(.coderValueNotFound)
        }
        let clipView = scrollView.contentView
        func bottomOffset() -> CGFloat {
            document.isFlipped
                ? max(document.bounds.minY, document.bounds.maxY - clipView.bounds.height)
                : document.bounds.minY
        }
        // The lazy grid may refine its document height after the second row
        // becomes visible. Wait for the final geometry, not its first estimate.
        for _ in 0..<5 {
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: bottomOffset()))
            scrollView.reflectScrolledClipView(clipView)
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            if abs(clipView.bounds.minY - bottomOffset()) < 1 { return }
        }
        MacPolishVerification.require(false,
            "Expected the compact permission preview to reach the bottom; offset: \(clipView.bounds.minY), expected: \(bottomOffset())")
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) { return scrollView }
        }
        return nil
    }
}

private struct PreviewAppearanceProbe: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    let content: AnyView
    let onRead: (PreviewAccessibilityState) -> Void

    private var state: PreviewAccessibilityState {
        PreviewAccessibilityState(contrast: contrast, reducesTransparency: reducesTransparency, reducesMotion: reducesMotion)
    }

    var body: some View {
        content
            .onAppear { onRead(state) }
            .onChange(of: state, perform: onRead)
    }
}

private struct PreviewAccessibilityState: Equatable {
    let contrast: ColorSchemeContrast
    let reducesTransparency: Bool
    let reducesMotion: Bool
}
