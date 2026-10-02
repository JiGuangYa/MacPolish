import SwiftUI

struct PermissionPrivacyNote: View {
    var body: some View {
        Label {
            Text(verbatim: L10n.string(.permissionInputPrivacy))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "hand.raised")
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
