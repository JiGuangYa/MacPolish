import AppKit
import SwiftUI

@MainActor
public protocol ScreenShielding: AnyObject {
    func start(mode: CleaningMode, onExit: @escaping @MainActor (ExitTrigger) -> Void) -> Bool
    func stop()
}

@MainActor
public final class ScreenShieldService: ScreenShielding {
    private var controllers: [ShieldWindowController] = []

    public init() { }

    public func start(mode: CleaningMode, onExit: @escaping @MainActor (ExitTrigger) -> Void) -> Bool {
        guard !NSScreen.screens.isEmpty else {
            return false
        }

        stop()

        controllers = NSScreen.screens.map { screen in
            ShieldWindowController(screen: screen, mode: mode, onExit: onExit)
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
private final class ShieldPresentationModel: ObservableObject {
    @Published var showsChrome = true
    @Published var showsHint = true

    private let reduceMotion: Bool
    private var chromeDismissWorkItem: DispatchWorkItem?
    private var hintDismissWorkItem: DispatchWorkItem?

    init(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.reduceMotion = reduceMotion
    }

    func startPresentationCycle() {
        revealChrome(includeHint: true, hideAfter: 3.0)
        scheduleHintDismiss(after: 2.3)
    }

    func registerInteraction() {
        revealChrome(includeHint: false, hideAfter: 1.8)
    }

    private func revealChrome(includeHint: Bool, hideAfter delay: TimeInterval) {
        chromeDismissWorkItem?.cancel()

        animate {
            self.showsChrome = true
            if includeHint {
                self.showsHint = true
            }
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.animate {
                self.showsChrome = false
            }
        }

        chromeDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleHintDismiss(after delay: TimeInterval) {
        hintDismissWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.animate {
                self.showsHint = false
            }
        }

        hintDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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
private final class ShieldWindow: NSWindow {
    var capturesKeyboardLocally = false
    var allowsEscapeExit = false
    var shouldBecomeKeyWindow = false

    var onEscape: (() -> Void)?
    var onInteraction: (() -> Void)?

    override var canBecomeKey: Bool {
        shouldBecomeKeyWindow
    }

    override var canBecomeMain: Bool {
        false
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if capturesKeyboardLocally {
                if allowsEscapeExit && event.keyCode == 53 {
                    onEscape?()
                }
                return
            }

        case .keyUp, .flagsChanged:
            if capturesKeyboardLocally {
                return
            }

        case .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel:
            onInteraction?()

        default:
            break
        }

        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        if allowsEscapeExit {
            onEscape?()
        }
    }
}

@MainActor
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private struct ShieldContentView: View {
    @ObservedObject var model: ShieldPresentationModel
    let mode: CleaningMode
    let onExit: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            background

            VStack(alignment: .trailing, spacing: 12) {
                if model.showsHint {
                    Text(verbatim: hintText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            )
            .padding(24)
            .opacity(model.showsChrome ? 1 : 0)
            .allowsHitTesting(model.showsChrome)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

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
            L10n.string(.hintWholeMac)
        case .screenOnly:
            L10n.string(.hintScreenOnly)
        case .keyboardOnly:
            L10n.string(.hintKeyboardOnly)
        }
    }
}

@MainActor
private final class ShieldWindowController: NSObject {
    private let screen: NSScreen
    private let mode: CleaningMode
    private let onExit: @MainActor (ExitTrigger) -> Void
    private let presentationModel = ShieldPresentationModel()

    private var window: ShieldWindow?

    init(screen: NSScreen, mode: CleaningMode, onExit: @escaping @MainActor (ExitTrigger) -> Void) {
        self.screen = screen
        self.mode = mode
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
        if window.shouldBecomeKeyWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }

        presentationModel.startPresentationCycle()
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    private func createWindow() {
        let style = styleConfiguration(for: mode)

        let window = ShieldWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        window.shouldBecomeKeyWindow = style.shouldBecomeKeyWindow
        window.capturesKeyboardLocally = style.capturesKeyboardLocally
        window.allowsEscapeExit = style.allowsEscapeExit
        window.backgroundColor = style.backgroundColor
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = style.isOpaque
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.isMovable = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false

        window.onEscape = { [weak self] in
            self?.requestExit(.escapeKey)
        }
        window.onInteraction = { [weak self] in
            self?.presentationModel.registerInteraction()
        }

        let contentView = FirstMouseHostingView(
            rootView: ShieldContentView(
                model: presentationModel,
                mode: mode
            ) { [weak self] in
                self?.requestExit(.button)
            }
        )
        contentView.frame = screen.frame

        window.contentView = contentView
        self.window = window
    }

    private func requestExit(_ trigger: ExitTrigger) {
        onExit(trigger)
    }

    private func styleConfiguration(for mode: CleaningMode) -> (
        backgroundColor: NSColor,
        isOpaque: Bool,
        shouldBecomeKeyWindow: Bool,
        capturesKeyboardLocally: Bool,
        allowsEscapeExit: Bool
    ) {
        switch mode {
        case .wholeMac:
            (.black, true, true, true, true)
        case .screenOnly:
            (.black, true, false, false, false)
        case .keyboardOnly:
            (.clear, false, false, false, false)
        }
    }
}
