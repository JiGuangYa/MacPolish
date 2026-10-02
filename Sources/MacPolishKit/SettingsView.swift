import AppKit
import SwiftUI

public struct SettingsView: View {
    @ObservedObject private var sessionController: CleaningSessionController
    @ObservedObject private var appSettings: AppSettings

    public init(sessionController: CleaningSessionController, appSettings: AppSettings) {
        _sessionController = ObservedObject(wrappedValue: sessionController)
        _appSettings = ObservedObject(wrappedValue: appSettings)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                generalSection
                permissionsSection
                cleaningSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 560, idealWidth: 560, maxWidth: .infinity,
               minHeight: 420, idealHeight: 520, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowAccessor { window in
            // Settings scenes do not consistently apply scene resizability on
            // every supported macOS release. Keep the native limits explicit.
            let minimum = NSSize(width: 560, height: 420)
            let maximum = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
            if window.contentMinSize != minimum { window.contentMinSize = minimum }
            if window.contentMaxSize != maximum { window.contentMaxSize = maximum }
        })
        .onAppear {
            sessionController.refreshKeyboardProtectionAvailability(startPollingIfNeeded: true)
        }
    }

    private var generalSection: some View {
        SettingsSection(title: L10n.string(.settingsGeneralSection)) {
            Toggle(isOn: $appSettings.showMenuBarItem) {
                Text(verbatim: L10n.string(.settingsShowMenuBarItem))
            }

            Text(verbatim: L10n.string(.settingsShowMenuBarItemHelp))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $appSettings.rememberLastMode) {
                Text(verbatim: L10n.string(.settingsRememberLastMode))
            }

            Text(verbatim: L10n.string(.settingsRememberLastModeHelp))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $appSettings.reopenMainWindowAfterCleaning) {
                Text(verbatim: L10n.string(.settingsReopenMainWindow))
            }

            Text(verbatim: L10n.string(.settingsReopenMainWindowHelp))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionsSection: some View {
        SettingsSection(title: L10n.string(.settingsPermissionsSection)) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: L10n.string(.settingsCurrentPermissionState))
                    .font(.body.weight(.medium))

                Text(verbatim: permissionStatusTitle)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(permissionStatusColor.opacity(0.12), in: Capsule())
            }

            if sessionController.notice == .relaunchFailed {
                SessionNoticeView(notice: .relaunchFailed, onDismiss: sessionController.dismissNotice)
            } else {
                Text(verbatim: L10n.string(sessionController.keyboardProtectionAvailability == .blockedBySecureInput
                    ? .permissionSecureInput : .settingsPermissionImpactDescription))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PermissionPrivacyNote()
                .font(.callout)

            if sessionController.isRelaunching {
                RelaunchProgressView()
            } else if showsPermissionButton {
                Button(permissionActionTitle) {
                    performPermissionAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(sessionController.isCleaning || sessionController.isRelaunching || sessionController.isOpeningMainWindow)
            }
        }
    }

    private var cleaningSection: some View {
        SettingsSection(title: L10n.string(.settingsCleaningSection)) {
            Toggle(isOn: $appSettings.showExitHints) {
                Text(verbatim: L10n.string(.settingsShowExitHints))
            }

            Text(verbatim: L10n.string(.settingsShowExitHintsHelp))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $appSettings.revealControlsOnPointerMovement) {
                Text(verbatim: L10n.string(.settingsRevealControlsOnPointerMovement))
            }

            Text(verbatim: L10n.string(.settingsRevealControlsOnPointerMovementHelp))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(verbatim: L10n.string(.settingsControlFadeDelay))
                    Spacer(minLength: 16)
                    Text(verbatim: String(format: L10n.string(.settingsFadeDelayValue), locale: Locale.current, appSettings.clampedFadeDelay))
                        .foregroundStyle(.secondary)
                }

                Slider(value: $appSettings.controlFadeDelay, in: 1.5...5.0, step: 0.1)
                    .accessibilityLabel(Text(verbatim: L10n.string(.settingsControlFadeDelay)))
                    .accessibilityValue(Text(verbatim: String(format: L10n.string(.settingsFadeDelayValue),
                        locale: Locale.current, appSettings.clampedFadeDelay)))
                    .accessibilityHint(Text(verbatim: L10n.string(.settingsControlFadeDelayHelp)))
                    .accessibilityAdjustableAction { direction in
                        guard appSettings.revealControlsOnPointerMovement else { return }
                        switch direction {
                        case .increment: appSettings.controlFadeDelay += 0.1
                        case .decrement: appSettings.controlFadeDelay -= 0.1
                        @unknown default: break
                        }
                    }
                    .disabled(!appSettings.revealControlsOnPointerMovement)
            }

            Text(verbatim: L10n.string(.settingsControlFadeDelayHelp))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionStatusTitle: String {
        switch sessionController.keyboardProtectionAvailability {
        case .ready:
            return L10n.string(.statusReady)
        case .waitingForSystem:
            return L10n.string(.statusWaitingToApply)
        case .blockedBySecureInput:
            return L10n.string(.statusSecureInput)
        case .needsRelaunch:
            return L10n.string(.statusNeedsRelaunch)
        case .needsPermission:
            return L10n.string(.statusNeedsPermission)
        }
    }

    private var permissionStatusColor: Color {
        switch sessionController.keyboardProtectionAvailability {
        case .ready:
            return .green
        case .waitingForSystem:
            return .yellow
        case .needsRelaunch, .blockedBySecureInput:
            return .orange
        case .needsPermission:
            return .orange
        }
    }

    private var showsPermissionButton: Bool {
        sessionController.globalKeyboardPermissionPrimaryAction != .startWholeMacCleaning
    }

    private var permissionActionTitle: String {
        switch sessionController.globalKeyboardPermissionPrimaryAction {
        case .requestAccess:
            return L10n.string(.actionRequestKeyboardAccess)
        case .openSettings:
            return L10n.string(.actionOpenSystemSettings)
        case .refreshNow:
            return L10n.string(.actionRefreshNow)
        case .relaunchNow:
            return L10n.string(.actionRelaunchNow)
        case .startWholeMacCleaning, .startKeyboardCleaning:
            return L10n.string(.actionRequestKeyboardAccess)
        }
    }

    private func performPermissionAction() {
        switch sessionController.globalKeyboardPermissionPrimaryAction {
        case .requestAccess:
            _ = sessionController.requestKeyboardPermission()
        case .openSettings:
            sessionController.openKeyboardPermissionSettings()
        case .refreshNow:
            sessionController.refreshKeyboardProtectionNow()
        case .relaunchNow:
            sessionController.relaunchApplication()
        case .startWholeMacCleaning, .startKeyboardCleaning:
            break
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: title)
                .font(.headline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1))
        )
    }
}
