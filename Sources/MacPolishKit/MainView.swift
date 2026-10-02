import SwiftUI

public struct MainView: View {
    @ObservedObject private var sessionController: CleaningSessionController
    @ObservedObject private var appSettings: AppSettings

    public init(sessionController: CleaningSessionController, appSettings: AppSettings) {
        _sessionController = ObservedObject(wrappedValue: sessionController)
        _appSettings = ObservedObject(wrappedValue: appSettings)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let mode = sessionController.activeMode {
                        ActiveSessionView(controller: sessionController, mode: mode)
                    } else {
                        header
                        if sessionController.isOpeningMainWindow {
                            MainWindowOpeningView(controller: sessionController)
                        }
                        if sessionController.isRelaunching {
                            RelaunchProgressView()
                        }
                        if let notice = sessionController.notice {
                            SessionNoticeView(notice: notice, onDismiss: sessionController.dismissNotice)
                        }

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 280, maximum: 480), spacing: 16, alignment: .top)],
                            alignment: .leading, spacing: 16
                        ) {
                            ForEach(CleaningMode.allCases) { mode in
                                ModeCard(
                                    mode: mode, controller: sessionController,
                                    isHighlighted: appSettings.rememberLastMode && appSettings.lastSelectedMode == mode
                                )
                            }
                        }

                        Label {
                            Text(verbatim: L10n.string(.mainFooterHint))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "computermouse")
                                .accessibilityHidden(true)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)

                        EmergencyExitView(gesture: sessionController.emergencyExitGesture)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if let mode = sessionController.activeMode {
                ActiveSessionControls(controller: sessionController, mode: mode)
            }
        }
        .frame(
            minWidth: WindowMetrics.minimumWidth, idealWidth: WindowMetrics.defaultWidth,
            maxWidth: .infinity, minHeight: WindowMetrics.minimumHeight,
            maxHeight: .infinity, alignment: .topLeading
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowAccessor { sessionController.registerMainWindow($0) })
        .onAppear { sessionController.refreshKeyboardProtectionAvailability(startPollingIfNeeded: true) }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 56, height: 56)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: L10n.string(.appTitle))
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: L10n.string(.mainSubtitle))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ModeCard: View {
    let mode: CleaningMode
    @ObservedObject var controller: CleaningSessionController
    let isHighlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: mode.symbolName)
                .font(.system(size: 28, weight: .regular))
                .frame(height: 36)
                .accessibilityHidden(true)

            Text(verbatim: L10n.string(mode.titleKey))
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            StatusBadge(title: L10n.string(statusKey), isLimited: isLimited)

            Text(verbatim: L10n.string(descriptionKey))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if mode == .keyboardOnly && controller.keyboardProtectionAvailability == .needsPermission {
                PermissionPrivacyNote()
                    .font(.caption)
            }

            Spacer(minLength: 4)

            Button {
                controller.performPrimaryAction(for: mode)
            } label: {
                Text(verbatim: L10n.string(actionKey))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!controller.canPerformPrimaryAction(for: mode))
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: WindowMetrics.cardMinimumHeight, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(isHighlighted ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1), lineWidth: isHighlighted ? 2 : 1)
        }
    }

    private var actionKey: LocalizationKey {
        controller.permissionPrimaryAction(for: mode)?.titleKey ?? mode.actionKey
    }

    private var isLimited: Bool {
        mode != .screenOnly && controller.keyboardProtectionAvailability != .ready
    }

    private var statusKey: LocalizationKey {
        guard isLimited else { return .statusReady }
        if mode == .wholeMac { return .statusLocalProtection }
        switch controller.keyboardProtectionAvailability {
        case .needsPermission: return .statusNeedsPermission
        case .waitingForSystem: return .statusWaitingToApply
        case .blockedBySecureInput: return .statusSecureInput
        case .needsRelaunch: return .statusNeedsRelaunch
        case .ready: return .statusReady
        }
    }

    private var descriptionKey: LocalizationKey {
        switch mode {
        case .wholeMac:
            return isLimited ? .modeWholeMacLocalDescription : .modeWholeMacDescription
        case .screenOnly:
            return .modeScreenOnlyDescription
        case .keyboardOnly:
            switch controller.keyboardProtectionAvailability {
            case .needsPermission:
                return controller.keyboardPermissionState == .denied ? .permissionKeyboardDenied : .permissionKeyboardNotDetermined
            case .waitingForSystem: return .permissionWaitingToApply
            case .blockedBySecureInput: return .permissionSecureInput
            case .needsRelaunch: return .permissionRelaunchRequired
            case .ready: return .modeKeyboardOnlyDescription
            }
        }
    }
}

private struct StatusBadge: View {
    let title: String
    let isLimited: Bool

    var body: some View {
        Label(title, systemImage: isLimited ? "info.circle" : "checkmark.circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background((isLimited ? Color.orange : Color.green).opacity(0.12), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ActiveSessionView: View {
    @ObservedObject var controller: CleaningSessionController
    let mode: CleaningMode

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: L10n.string(.statusCleaning))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(verbatim: L10n.string(mode.titleKey))
                        .font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 12)
                if controller.sessionStartedAt != nil {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(verbatim: L10n.string(.sessionElapsed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(verbatim: elapsed(controller.elapsedCleaningTime))
                                .font(.title2.monospacedDigit())
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Label {
                Text(verbatim: L10n.string(controller.activeKeyboardProtection.descriptionKey))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: controller.activeKeyboardProtection == .global ? "lock.fill" : "info.circle")
                    .accessibilityHidden(true)
            }
            .font(.body)

            Divider()

            Text(verbatim: L10n.string(exitHintKey))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        }
        .padding(28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22).strokeBorder(Color.accentColor.opacity(0.4))
        }
    }

    private func elapsed(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var exitHintKey: LocalizationKey {
        switch mode {
        case .screenOnly: .hintScreenOnly
        case .keyboardOnly: .sessionMouseExit
        case .wholeMac: controller.activeKeyboardProtection == .global ? .hintWholeMac : .hintWholeMacLocal
        }
    }
}

/// Keep the exit and its countdown reachable even when the session details
/// need to scroll in a short window or a language with longer guidance.
private struct ActiveSessionControls: View {
    let controller: CleaningSessionController
    let mode: CleaningMode

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                if mode != .screenOnly {
                    EmergencyExitView(gesture: controller.emergencyExitGesture)
                }

                Button {
                    if mode == .keyboardOnly {
                        controller.performPrimaryAction(for: mode)
                    } else {
                        controller.stopCleaning(trigger: .button)
                    }
                } label: {
                    Label(L10n.string(.menuExitCleaning), systemImage: "checkmark")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel(Text(verbatim: L10n.string(.accessibilityExitCleaning)))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct RelaunchProgressView: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(verbatim: L10n.string(.statusRelaunching))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
        .accessibilityElement(children: .combine)
    }
}

struct MainWindowOpeningView: View {
    let controller: CleaningSessionController

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
                .accessibilityHidden(true)
            Text(verbatim: L10n.string(.statusOpeningMainWindow))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(L10n.string(.actionCancel)) { controller.cancelOpeningMainWindow() }
        }
        .font(.body)
        .padding(16)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SessionNoticeView: View {
    let notice: CleaningSessionNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
                .font(.title3)
                .accessibilityHidden(true)
            Text(verbatim: L10n.string(notice.messageKey))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark").frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: L10n.string(.actionDismiss)))
            .help(L10n.string(.actionDismiss))
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}
