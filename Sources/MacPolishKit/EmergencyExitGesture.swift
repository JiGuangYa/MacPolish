import AppKit
import Combine
import CoreGraphics
import Foundation

public enum EmergencyExitInput: Equatable, Sendable {
    case escapeChanged(isDown: Bool, isRepeat: Bool, modifiersHeld: Bool)
    case modifiersChanged(held: Bool)
    case reset
}

/// Recognizes a continuous Control–Option–Escape hold without releasing any
/// keyboard events to other apps. Idle sessions do not run a gesture timer.
@MainActor
public final class EmergencyExitGesture: ObservableObject {
    @Published public private(set) var progress: Double?
    public var isHolding: Bool { progress != nil }
    public var remainingSeconds: Int {
        max(1, Int(ceil(holdDuration * (1 - (progress ?? 0)))))
    }

    private let holdDuration: TimeInterval
    private let uptime: () -> TimeInterval
    private var escapeHeld = false
    private var modifiersHeld = false
    private var holdStartedAt: TimeInterval?
    private var timer: AnyCancellable?
    private var onExit: (@MainActor () -> Void)?

    public convenience init() {
        self.init(holdDuration: 3)
    }

    package init(holdDuration: TimeInterval, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.holdDuration = holdDuration.isFinite && holdDuration > 0 ? holdDuration : 3
        self.uptime = uptime
    }

    package func start(onExit: @escaping @MainActor () -> Void) {
        stop()
        self.onExit = onExit
    }

    package func stop() {
        onExit = nil
        resetInput()
    }

    package func handle(_ input: EmergencyExitInput) {
        guard onExit != nil else { return }
        switch input {
        case let .escapeChanged(isDown, isRepeat, modifiersHeld):
            // A key already held before this session must be released first.
            if isDown && isRepeat && !escapeHeld { return }
            escapeHeld = isDown
            self.modifiersHeld = modifiersHeld
        case let .modifiersChanged(held):
            modifiersHeld = held
        case .reset:
            resetInput()
            return
        }
        guard escapeHeld && modifiersHeld else {
            cancelHold()
            return
        }
        guard holdStartedAt == nil else { return }
        holdStartedAt = uptime()
        progress = 0
        // Main-actor tasks can pause inside AppKit's nested menu/drag loop.
        // Common-mode timers keep the exit available throughout tracking.
        timer = Timer.publish(every: 0.04, tolerance: 0.005, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updateProgress() }
    }

    package func updateProgress() {
        guard let startedAt = holdStartedAt, let onExit else { return }
        let elapsed = max(0, uptime() - startedAt)
        if elapsed >= holdDuration {
            stop()
            onExit()
        } else {
            progress = elapsed / holdDuration
        }
    }

    private func resetInput() {
        escapeHeld = false
        modifiersHeld = false
        cancelHold()
    }

    private func cancelHold() {
        holdStartedAt = nil
        timer?.cancel()
        timer = nil
        if progress != nil { progress = nil }
    }
}

extension EmergencyExitInput {
    package static func from(_ event: NSEvent) -> EmergencyExitInput? {
        let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let held = event.modifierFlags.intersection(relevant) == [.control, .option]
        switch event.type {
        case .flagsChanged:
            return .modifiersChanged(held: held)
        case .keyDown, .keyUp:
            if event.keyCode == 53 {
                return .escapeChanged(isDown: event.type == .keyDown, isRepeat: event.type == .keyDown && event.isARepeat, modifiersHeld: held)
            }
            return event.type == .keyDown ? .reset : nil
        case .systemDefined:
            return .reset
        default:
            return nil
        }
    }

    package static func from(type: CGEventType, event: CGEvent) -> EmergencyExitInput? {
        let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        let held = event.flags.intersection(relevant) == [.maskControl, .maskAlternate]
        switch type {
        case .flagsChanged:
            return .modifiersChanged(held: held)
        case .keyDown, .keyUp:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                return .escapeChanged(isDown: type == .keyDown,
                    isRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0, modifiersHeld: held)
            }
            return type == .keyDown ? .reset : nil
        default:
            return nil
        }
    }
}
