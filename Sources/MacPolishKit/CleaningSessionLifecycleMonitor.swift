import AppKit
import Combine

@MainActor
final class CleaningSessionLifecycleMonitor {
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let displayConfigurationProvider: @MainActor () -> DisplayConfiguration
    private weak var mainWindow: NSWindow?
    private var observations: [AnyCancellable] = []
    private var sessionID: UUID?

    init(notificationCenter: NotificationCenter, workspaceNotificationCenter: NotificationCenter,
         displayConfigurationProvider: @escaping @MainActor () -> DisplayConfiguration) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.displayConfigurationProvider = displayConfigurationProvider
    }

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
    }

    func start(mode: CleaningMode, keyboardProtection: KeyboardProtection, onInterruption: @escaping @MainActor (ExitTrigger) -> Void) {
        stop()
        let sessionID = UUID()
        self.sessionID = sessionID

        let applicationEvents: [(Notification.Name, ExitTrigger)] = [
            (NSApplication.willHideNotification, .applicationHidden),
            (NSApplication.willTerminateNotification, .applicationTerminating)
        ]
        let workspaceEvents: [(Notification.Name, ExitTrigger)] = [
            (NSWorkspace.willSleepNotification, .systemSleep),
            (NSWorkspace.screensDidSleepNotification, .systemSleep),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive)
        ]

        for (name, trigger) in applicationEvents {
            observe(name, on: notificationCenter, sessionID: sessionID) { _ in
                onInterruption(trigger)
            }
        }
        for (name, trigger) in workspaceEvents {
            observe(name, on: workspaceNotificationCenter, sessionID: sessionID) { _ in
                onInterruption(trigger)
            }
        }

        // AppKit also posts this notification when status items change. Only
        // interrupt if the display identities, bounds, or scale actually moved.
        let initialDisplays = displayConfigurationProvider()
        observe(NSApplication.didChangeScreenParametersNotification, on: notificationCenter, sessionID: sessionID) { [weak self] _ in
            guard let self, self.displayConfigurationProvider() != initialDisplays else { return }
            onInterruption(.displayConfigurationChanged)
        }

        // Local protection applies only while MacPolish receives keyboard
        // events. Do not leave a black cover up after another app takes focus.
        if keyboardProtection == .local {
            observe(NSApplication.didResignActiveNotification, on: notificationCenter, sessionID: sessionID) { _ in
                onInterruption(.applicationDeactivated)
            }
        }

        // Keyboard Only uses the main window's button to finish. Other modes
        // have their own exit controls on the shield windows.
        if mode == .keyboardOnly {
            observe(NSWorkspace.activeSpaceDidChangeNotification, on: workspaceNotificationCenter, sessionID: sessionID) { [weak self] _ in
                // A different display may change Spaces while this window is
                // still reachable. Only stop when the exit window leaves.
                guard self?.mainWindow?.isOnActiveSpace == false else { return }
                onInterruption(.mainWindowLeftActiveSpace)
            }
            for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
                observe(name, on: notificationCenter, sessionID: sessionID) { [weak self] windowID in
                    guard let mainWindow = self?.mainWindow,
                          windowID == ObjectIdentifier(mainWindow) else {
                        return
                    }
                    onInterruption(.mainWindowUnavailable)
                }
            }
        }
    }

    func stop() {
        sessionID = nil
        observations.removeAll()
    }

    private func observe(
        _ name: Notification.Name,
        on center: NotificationCenter,
        sessionID: UUID,
        handler: @escaping @MainActor (ObjectIdentifier?) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            let windowID = (notification.object as? NSWindow).map(ObjectIdentifier.init)
            // The main operation queue delivers synchronously when these
            // AppKit notifications are posted on the main thread.
            MainActor.assumeIsolated {
                guard self?.sessionID == sessionID else { return }
                handler(windowID)
            }
        }
        observations.append(AnyCancellable { center.removeObserver(token) })
    }
}
