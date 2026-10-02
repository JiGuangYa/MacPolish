import Foundation
import Combine

public final class AppSettings: ObservableObject {
    private enum Key {
        static let rememberLastMode = "MacPolish.settings.rememberLastMode"
        static let lastSelectedMode = "MacPolish.settings.lastSelectedMode"
        static let reopenMainWindowAfterCleaning = "MacPolish.settings.reopenMainWindowAfterCleaning"
        static let showExitHints = "MacPolish.settings.showExitHints"
        static let controlFadeDelay = "MacPolish.settings.controlFadeDelay"
        static let revealControlsOnPointerMovement = "MacPolish.settings.revealControlsOnPointerMovement"
        static let showMenuBarItem = "MacPolish.settings.showMenuBarItem"
    }

    private let userDefaults: UserDefaults

    @Published public var showMenuBarItem: Bool {
        didSet { userDefaults.set(showMenuBarItem, forKey: Key.showMenuBarItem) }
    }

    @Published public var rememberLastMode: Bool {
        didSet {
            userDefaults.set(rememberLastMode, forKey: Key.rememberLastMode)
            if rememberLastMode == false {
                lastSelectedMode = nil
            }
        }
    }

    @Published public var lastSelectedMode: CleaningMode? {
        didSet {
            userDefaults.set(lastSelectedMode?.rawValue, forKey: Key.lastSelectedMode)
        }
    }

    @Published public var reopenMainWindowAfterCleaning: Bool {
        didSet {
            userDefaults.set(reopenMainWindowAfterCleaning, forKey: Key.reopenMainWindowAfterCleaning)
        }
    }

    @Published public var showExitHints: Bool {
        didSet {
            userDefaults.set(showExitHints, forKey: Key.showExitHints)
        }
    }

    @Published public var controlFadeDelay: Double {
        didSet {
            let normalized = Self.normalizedFadeDelay(controlFadeDelay)
            if controlFadeDelay != normalized {
                controlFadeDelay = normalized
            }
            userDefaults.set(clampedFadeDelay, forKey: Key.controlFadeDelay)
        }
    }

    @Published public var revealControlsOnPointerMovement: Bool {
        didSet {
            userDefaults.set(revealControlsOnPointerMovement, forKey: Key.revealControlsOnPointerMovement)
        }
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.showMenuBarItem = userDefaults.object(forKey: Key.showMenuBarItem) as? Bool ?? true

        let rememberedMode = userDefaults.object(forKey: Key.rememberLastMode) as? Bool ?? true
        let reopenWindow = userDefaults.object(forKey: Key.reopenMainWindowAfterCleaning) as? Bool ?? true
        let showHints = userDefaults.object(forKey: Key.showExitHints) as? Bool ?? true
        let fadeDelay = userDefaults.object(forKey: Key.controlFadeDelay) as? Double ?? 2.8
        let revealControls = userDefaults.object(forKey: Key.revealControlsOnPointerMovement) as? Bool ?? true

        self.rememberLastMode = rememberedMode
        self.reopenMainWindowAfterCleaning = reopenWindow
        self.showExitHints = showHints
        self.controlFadeDelay = Self.normalizedFadeDelay(fadeDelay)
        self.revealControlsOnPointerMovement = revealControls

        if rememberedMode,
           let rawValue = userDefaults.string(forKey: Key.lastSelectedMode),
           let mode = CleaningMode(rawValue: rawValue) {
            self.lastSelectedMode = mode
        } else {
            self.lastSelectedMode = nil
        }
    }

    public var clampedFadeDelay: Double {
        Self.normalizedFadeDelay(controlFadeDelay)
    }

    private static func normalizedFadeDelay(_ delay: Double) -> Double {
        delay.isFinite ? min(max(delay, 1.5), 5.0) : 2.8
    }

    public func markModeUsed(_ mode: CleaningMode) {
        guard rememberLastMode else {
            lastSelectedMode = nil
            return
        }

        lastSelectedMode = mode
    }
}
