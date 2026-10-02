import AppKit

/// Simulates Space membership without moving the user's windows or desktops.
@MainActor
final class SpaceTestWindow: NSWindow {
    var belongsToActiveSpace = true
    override var isOnActiveSpace: Bool { belongsToActiveSpace }
}
