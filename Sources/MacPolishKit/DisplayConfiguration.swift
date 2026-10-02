import AppKit

/// The display properties that determine where screen shields must be placed.
/// Menu bar and Dock visibility changes are deliberately excluded.
public struct DisplayConfiguration: Equatable, Sendable {
    public struct Display: Equatable, Sendable {
        public let identifier: UInt32
        public let frame: CGRect
        public let scale: CGFloat

        public init(identifier: UInt32, frame: CGRect, scale: CGFloat) {
            self.identifier = identifier
            self.frame = frame
            self.scale = scale
        }
    }

    public let displays: [Display]

    public init(displays: [Display]) {
        self.displays = displays.sorted { $0.identifier < $1.identifier }
    }

    @MainActor
    public static func current() -> DisplayConfiguration {
        DisplayConfiguration(displays: NSScreen.screens.map { screen in
            Display(identifier: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                frame: screen.frame, scale: screen.backingScaleFactor)
        })
    }
}
