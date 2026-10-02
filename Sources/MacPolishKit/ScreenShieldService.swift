import AppKit
import SwiftUI
import Combine

@MainActor
public protocol ScreenShielding: AnyObject {
    func start(mode: CleaningMode, keyboardProtection: KeyboardProtection, onExit: @escaping @MainActor (ExitTrigger) -> Void) -> Bool
    func stop()
}

@MainActor
public final class ScreenShieldService: ScreenShielding {
    private let appSettings: AppSettings
    private let emergencyExitGesture: EmergencyExitGesture
    private var controllers: [ShieldWindowController] = []

    public init(appSettings: AppSettings, emergencyExitGesture: EmergencyExitGesture) {
        self.appSettings = appSettings
        self.emergencyExitGesture = emergencyExitGesture
    }

    deinit {
        // AppKit windows and local event monitors must be torn down on the
        // main actor, including when the service loses its last owner.
        let controllers = controllers
        Task { @MainActor in controllers.forEach { $0.close() } }
    }

    public func start(mode: CleaningMode, keyboardProtection: KeyboardProtection, onExit: @escaping @MainActor (ExitTrigger) -> Void) -> Bool {
        if mode == .keyboardOnly {
            stop()
            return true
        }

        guard !NSScreen.screens.isEmpty else {
            return false
        }

        stop()

        controllers = NSScreen.screens.map { screen in
            ShieldWindowController(
                screen: screen,
                mode: mode,
                keyboardProtection: keyboardProtection,
                appSettings: appSettings,
                emergencyExitGesture: emergencyExitGesture,
                onExit: onExit
            )
        }

        controllers.forEach { $0.show() }
        return true
    }

    public func stop() {
        controllers.forEach { $0.close() }
        controllers.removeAll()
    }
}

@MainActor
package final class ShieldPresentationModel: ObservableObject {
    @Published package private(set) var showsChrome = true
    @Published package private(set) var showsHint = true

    private let appSettings: AppSettings
    private let reduceMotion: Bool
    private var keepsControlsVisibleForAccessibility = false
    private var isPresenting = false
    private var chromeDismissTask: Task<Void, Never>?
    private var hintDismissTask: Task<Void, Never>?
    private var settingsObservation: AnyCancellable?
    private var accessibilityObservation: AnyCancellable?

    package init(
        appSettings: AppSettings,
        reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        assistiveTechnologyEnabled: AnyPublisher<Bool, Never> = ShieldPresentationModel.systemAssistiveTechnologyEnabled
    ) {
        self.appSettings = appSettings
        self.reduceMotion = reduceMotion
        settingsObservation = Publishers.CombineLatest3(
            appSettings.$showExitHints,
            appSettings.$revealControlsOnPointerMovement,
            appSettings.$controlFadeDelay
        )
        .dropFirst()
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.registerInteraction()
        }
        accessibilityObservation = assistiveTechnologyEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self, self.keepsControlsVisibleForAccessibility != enabled else { return }
                self.keepsControlsVisibleForAccessibility = enabled
                self.registerInteraction()
            }
    }

    // Both properties support KVO. Observe them for the lifetime of this
    // shield so enabling an assistive tool also restores already-faded UI.
    package static var systemAssistiveTechnologyEnabled: AnyPublisher<Bool, Never> {
        Publishers.CombineLatest(
            NSWorkspace.shared.publisher(for: \.isVoiceOverEnabled),
            NSWorkspace.shared.publisher(for: \.isSwitchControlEnabled)
        )
        .map { $0 || $1 }
        .eraseToAnyPublisher()
    }

    deinit {
        chromeDismissTask?.cancel()
        hintDismissTask?.cancel()
    }

    package func startPresentationCycle() {
        isPresenting = true
        registerInteraction()
    }

    package func stopPresentationCycle() {
        isPresenting = false
        cancelDismissals()
    }

    package func registerInteraction() {
        guard isPresenting else { return }
        cancelDismissals()
        animate {
            self.showsChrome = true
            self.showsHint = self.appSettings.showExitHints
        }
        guard appSettings.revealControlsOnPointerMovement, !keepsControlsVisibleForAccessibility else { return }

        let chromeDelay = appSettings.clampedFadeDelay
        chromeDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(chromeDelay * 1_000_000_000))
            } catch { return }
            guard !Task.isCancelled, let self, self.isPresenting else { return }
            self.animate {
                self.showsChrome = false
                self.showsHint = false
            }
        }
        if appSettings.showExitHints {
            let hintDelay = max(1.2, min(2.4, chromeDelay - 0.3))
            hintDismissTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(hintDelay * 1_000_000_000))
                } catch { return }
                guard !Task.isCancelled, let self, self.isPresenting else { return }
                self.animate { self.showsHint = false }
            }
        }
    }

    private func cancelDismissals() {
        chromeDismissTask?.cancel()
        chromeDismissTask = nil
        hintDismissTask?.cancel()
        hintDismissTask = nil
    }

    private func animate(_ changes: @escaping () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.easeInOut(duration: 0.18), changes)
        }
    }
}

@MainActor
package final class ShieldWindow: NSWindow {
    package let capturesKeyboard: Bool
    package var exitsOnMouseDown: Bool {
        didSet {
            if !exitsOnMouseDown { mouseExitReadyAt = nil }
        }
    }
    private var mouseExitReadyAt: TimeInterval?
    package var onInteraction: (() -> Void)?
    package var onExitTrigger: ((ExitTrigger) -> Void)?
    package var onEmergencyInput: ((EmergencyExitInput) -> Void)?

    package init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing bufferingType: NSWindow.BackingStoreType,
        defer flag: Bool,
        capturesKeyboard: Bool,
        exitsOnMouseDown: Bool
    ) {
        self.capturesKeyboard = capturesKeyboard
        self.exitsOnMouseDown = exitsOnMouseDown
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: bufferingType,
            defer: flag
        )
    }

    // NSWindow's screen-based initializer funnels through this designated
    // initializer, so subclasses must implement it to avoid a runtime trap.
    package required override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing bufferingType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        self.capturesKeyboard = false
        self.exitsOnMouseDown = false
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: bufferingType,
            defer: flag
        )
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    package override var canBecomeKey: Bool {
        capturesKeyboard
    }

    package override var canBecomeMain: Bool {
        capturesKeyboard
    }

    package func armMouseExit(after delay: TimeInterval = max(0.45, NSEvent.doubleClickInterval)) {
        // A second click from launching Screen Only can arrive after the next
        // run-loop turn. Respect the user's double-click interval, without a
        // queued callback that could outlive this window or stall during a drag.
        mouseExitReadyAt = ProcessInfo.processInfo.systemUptime + (delay.isFinite ? max(0, delay) : 0.45)
        exitsOnMouseDown = true
    }

    package override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel,
             .keyDown, .keyUp, .flagsChanged, .systemDefined:
            onInteraction?()
        default:
            break
        }

        if exitsOnMouseDown {
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                // NSEvent timestamps share the system-uptime clock. Check
                // when the click occurred so a queued launch click stays ignored.
                if let mouseExitReadyAt, event.timestamp < mouseExitReadyAt { return }
                mouseExitReadyAt = nil
                onExitTrigger?(.button)
                return
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                // The matching down was consumed, including launch clicks.
                // Never deliver its orphaned release to the exit button.
                return
            default:
                break
            }
        }

        if capturesKeyboard {
            if let input = EmergencyExitInput.from(event) {
                onEmergencyInput?(input)
            }
            switch event.type {
            case .keyDown, .keyUp, .flagsChanged, .systemDefined:
                return
            default:
                break
            }
        }

        super.sendEvent(event)
    }

    package override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard capturesKeyboard else {
            return super.performKeyEquivalent(with: event)
        }

        onInteraction?()
        if let input = EmergencyExitInput.from(event) {
            onEmergencyInput?(input)
        }
        return true
    }

    package override func cancelOperation(_ sender: Any?) {
        guard capturesKeyboard else {
            super.cancelOperation(sender)
            return
        }

        onInteraction?()
    }
}

@MainActor
package final class ShieldHostingView: NSHostingView<ShieldContentView> {
    package required init(rootView: ShieldContentView) {
        super.init(rootView: rootView)
        // The display determines a shield's size. SwiftUI's fitting size can
        // otherwise enlarge the borderless window beyond the display frame.
        sizingOptions = []
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    package override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

package struct ShieldContentView: View {
    @ObservedObject var model: ShieldPresentationModel
    @ObservedObject var emergencyExitGesture: EmergencyExitGesture
    let mode: CleaningMode
    let keyboardProtection: KeyboardProtection
    let onExit: () -> Void

    package init(model: ShieldPresentationModel, emergencyExitGesture: EmergencyExitGesture, mode: CleaningMode,
                 keyboardProtection: KeyboardProtection, onExit: @escaping () -> Void) {
        self.model = model
        self.emergencyExitGesture = emergencyExitGesture
        self.mode = mode
        self.keyboardProtection = keyboardProtection
        self.onExit = onExit
    }

    package var body: some View {
        ZStack(alignment: .topTrailing) {
            background

            VStack(alignment: .trailing, spacing: 12) {
                if model.showsHint && !emergencyExitGesture.isHolding {
                    Text(verbatim: hintText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if mode != .screenOnly && (model.showsHint || emergencyExitGesture.isHolding) {
                    EmergencyExitView(gesture: emergencyExitGesture)
                }

                Button {
                    onExit()
                } label: {
                    Text(verbatim: L10n.string(.actionDone))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel(Text(verbatim: L10n.string(.accessibilityExitCleaning)))
            }
            .padding(16)
            .frame(maxWidth: model.showsHint || emergencyExitGesture.isHolding ? 420 : nil, alignment: .trailing)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            )
            .padding(24)
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)
            .accessibilityHidden(!showsControls)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var showsControls: Bool { model.showsChrome || emergencyExitGesture.isHolding }

    @ViewBuilder
    private var background: some View {
        switch mode {
        case .wholeMac, .screenOnly:
            Color.black
                .ignoresSafeArea()
        case .keyboardOnly:
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
        }
    }

    private var hintText: String {
        switch mode {
        case .wholeMac:
            return L10n.string(keyboardProtection == .global ? .hintWholeMac : .hintWholeMacLocal)
        case .screenOnly:
            return L10n.string(.hintScreenOnly)
        case .keyboardOnly:
            return L10n.string(.hintKeyboardOnly)
        }
    }
}

@MainActor
private final class ShieldWindowController: NSObject {
    private let screen: NSScreen
    private let mode: CleaningMode
    private let keyboardProtection: KeyboardProtection
    private let appSettings: AppSettings
    private let emergencyExitGesture: EmergencyExitGesture
    private let onExit: @MainActor (ExitTrigger) -> Void
    private lazy var presentationModel = ShieldPresentationModel(appSettings: appSettings)

    private var window: ShieldWindow?
    private var localKeyMonitor: Any?

    init(
        screen: NSScreen,
        mode: CleaningMode,
        keyboardProtection: KeyboardProtection,
        appSettings: AppSettings,
        emergencyExitGesture: EmergencyExitGesture,
        onExit: @escaping @MainActor (ExitTrigger) -> Void
    ) {
        self.screen = screen
        self.mode = mode
        self.keyboardProtection = keyboardProtection
        self.appSettings = appSettings
        self.emergencyExitGesture = emergencyExitGesture
        self.onExit = onExit
    }

    func show() {
        if window == nil {
            createWindow()
        }

        guard let window else {
            return
        }

        window.setFrame(screen.frame, display: true)
        armMouseExitIfNeeded(for: window)
        if window.capturesKeyboard {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }

        installLocalKeyMonitorIfNeeded()
        presentationModel.startPresentationCycle()
    }

    func close() {
        presentationModel.stopPresentationCycle()
        removeLocalKeyMonitor()
        window?.onEmergencyInput = nil
        window?.onInteraction = nil
        window?.onExitTrigger = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    private func createWindow() {
        let capturesKeyboard = mode != .screenOnly
        let window = ShieldWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            capturesKeyboard: capturesKeyboard,
            exitsOnMouseDown: false
        )

        window.backgroundColor = mode == .keyboardOnly ? .clear : .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = mode != .keyboardOnly
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.isMovable = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false

        window.onInteraction = { [weak self] in
            self?.presentationModel.registerInteraction()
        }
        window.onExitTrigger = { [weak self] trigger in
            self?.onExit(trigger)
        }
        window.onEmergencyInput = { [weak emergencyExitGesture] input in
            emergencyExitGesture?.handle(input)
        }

        let contentView = ShieldHostingView(
            rootView: ShieldContentView(
                model: presentationModel,
                emergencyExitGesture: emergencyExitGesture,
                mode: mode,
                keyboardProtection: keyboardProtection
            ) { [weak self] in
                self?.onExit(.button)
            }
        )
        contentView.frame = NSRect(origin: .zero, size: screen.frame.size)

        window.contentView = contentView
        self.window = window
    }

    private func armMouseExitIfNeeded(for window: ShieldWindow) {
        guard mode == .screenOnly else {
            window.exitsOnMouseDown = false
            return
        }

        window.armMouseExit()
    }

    private func installLocalKeyMonitorIfNeeded() {
        guard mode == .screenOnly, localKeyMonitor == nil else {
            return
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else {
                return event
            }

            self.onExit(.escapeKey)
            return nil
        }
    }

    private func removeLocalKeyMonitor() {
        guard let localKeyMonitor else {
            return
        }

        NSEvent.removeMonitor(localKeyMonitor)
        self.localKeyMonitor = nil
    }
}
