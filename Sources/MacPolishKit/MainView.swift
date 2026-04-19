import SwiftUI

public struct MainView: View {
    @ObservedObject private var sessionController: CleaningSessionController

    public init(sessionController: CleaningSessionController) {
        _sessionController = ObservedObject(wrappedValue: sessionController)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: L10n.string(.appTitle))
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                Text(verbatim: L10n.string(.mainSubtitle))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    cards
                }

                VStack(spacing: 16) {
                    cards
                }
            }

            Text(verbatim: L10n.string(.mainFooterHint))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(minWidth: 920, idealWidth: 920, maxWidth: 1120, minHeight: 460, idealHeight: 470, maxHeight: 620, alignment: .topLeading)
        .background(
            WindowAccessor { window in
                sessionController.registerMainWindow(window)
            }
        )
        .onAppear {
            sessionController.refreshKeyboardPermissionState()
        }
    }

    private var cards: some View {
        ForEach(CleaningMode.allCases) { mode in
            ModeCard(
                mode: mode,
                permissionState: sessionController.keyboardPermissionState,
                isBusy: sessionController.isCleaning
            ) {
                sessionController.startCleaning(mode: mode)
            } onRequestPermission: {
                _ = sessionController.requestKeyboardPermission()
            } onOpenSettings: {
                sessionController.openKeyboardPermissionSettings()
            }
        }
    }
}

private struct ModeCard: View {
    let mode: CleaningMode
    let permissionState: KeyboardPermissionState
    let isBusy: Bool
    let onStart: () -> Void
    let onRequestPermission: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbolName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(verbatim: description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if mode == .keyboardOnly, permissionState != .granted {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: L10n.string(.permissionInputMonitoringRequired))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(verbatim: permissionDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(permissionActionTitle) {
                        switch permissionState {
                        case .granted:
                            onStart()
                        case .notDetermined:
                            onRequestPermission()
                        case .denied:
                            onOpenSettings()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            } else {
                Button(actionTitle) {
                    onStart()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(borderColor)
        )
    }

    private var title: String {
        switch mode {
        case .wholeMac:
            L10n.string(.modeWholeMacTitle)
        case .screenOnly:
            L10n.string(.modeScreenOnlyTitle)
        case .keyboardOnly:
            L10n.string(.modeKeyboardOnlyTitle)
        }
    }

    private var description: String {
        switch mode {
        case .wholeMac:
            L10n.string(.modeWholeMacDescription)
        case .screenOnly:
            L10n.string(.modeScreenOnlyDescription)
        case .keyboardOnly:
            L10n.string(.modeKeyboardOnlyDescription)
        }
    }

    private var actionTitle: String {
        switch mode {
        case .wholeMac:
            L10n.string(.modeWholeMacAction)
        case .screenOnly:
            L10n.string(.modeScreenOnlyAction)
        case .keyboardOnly:
            L10n.string(.modeKeyboardOnlyAction)
        }
    }

    private var symbolName: String {
        switch mode {
        case .wholeMac:
            "laptopcomputer"
        case .screenOnly:
            "display"
        case .keyboardOnly:
            "keyboard"
        }
    }

    private var borderColor: Color {
        if mode == .keyboardOnly, permissionState != .granted {
            return Color.orange.opacity(0.35)
        }

        return Color.white.opacity(0.08)
    }

    private var permissionDescription: String {
        switch permissionState {
        case .granted:
            return ""
        case .notDetermined:
            return L10n.string(.permissionKeyboardNotDetermined)
        case .denied:
            return L10n.string(.permissionKeyboardDenied)
        }
    }

    private var permissionActionTitle: String {
        switch permissionState {
        case .granted:
            return actionTitle
        case .notDetermined:
            return L10n.string(.actionRequestKeyboardAccess)
        case .denied:
            return L10n.string(.actionOpenSystemSettings)
        }
    }
}
