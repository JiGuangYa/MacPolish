import SwiftUI

struct EmergencyExitView: View {
    @ObservedObject var gesture: EmergencyExitGesture

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(verbatim: gesture.isHolding
                    ? String(format: L10n.string(.exitShortcutCountdown), gesture.remainingSeconds)
                    : L10n.string(.exitShortcutHint))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "keyboard")
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .foregroundStyle(gesture.isHolding ? .primary : .secondary)

            if let progress = gesture.progress {
                ProgressView(value: progress)
                    .accessibilityLabel(Text(verbatim: L10n.string(.accessibilityExitCleaning)))
                Text(verbatim: L10n.string(.exitShortcutCancel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
