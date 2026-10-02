import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

@MainActor
package protocol KeyboardAccessChecking: AnyObject {
    var isTrusted: Bool { get }
    var isSecureInputEnabled: Bool { get }
    func requestAccess()
}

@MainActor
final class SystemKeyboardAccess: KeyboardAccessChecking {
    var isTrusted: Bool { AXIsProcessTrusted() }
    var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }

    func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

package typealias KeyboardEventHandler = @MainActor (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

/// Implementations must invalidate their native resources when released.
package protocol KeyboardEventTap: AnyObject {
    var isEnabled: Bool { get }
    func enable()
    func invalidate()
}

@MainActor
package protocol KeyboardEventTapCreating: AnyObject {
    func makeTap(eventsOfInterest: CGEventMask, handler: @escaping KeyboardEventHandler) -> (any KeyboardEventTap)?
}

@MainActor
final class CoreGraphicsKeyboardEventTapFactory: KeyboardEventTapCreating {
    func makeTap(eventsOfInterest: CGEventMask, handler: @escaping KeyboardEventHandler) -> (any KeyboardEventTap)? {
        let context = EventTapContext(handler: handler)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else {
            return nil
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return nil
        }

        let resource = CoreGraphicsKeyboardEventTap(tap: tap, source: source, context: context)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return resource
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        // This source is installed only on the main run loop. The context
        // outlives the native tap and its handler refers weakly to the service.
        let context = Unmanaged<EventTapContext>.fromOpaque(userInfo).takeUnretainedValue()
        return context.handler(type, event)
    }
}

@MainActor
private final class EventTapContext {
    let handler: KeyboardEventHandler

    init(handler: @escaping KeyboardEventHandler) {
        self.handler = handler
    }
}

private final class CoreGraphicsKeyboardEventTap: KeyboardEventTap {
    private let tap: CFMachPort
    private let source: CFRunLoopSource
    private let context: EventTapContext
    private var isInvalidated = false

    init(tap: CFMachPort, source: CFRunLoopSource, context: EventTapContext) {
        self.tap = tap
        self.source = source
        self.context = context
    }

    var isEnabled: Bool {
        !isInvalidated && CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }

    func enable() {
        guard !isInvalidated, CFMachPortIsValid(tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        CFMachPortInvalidate(tap)
    }

    deinit {
        invalidate()
        // If the final owner is released off-main, retain the context until
        // any callback already running on the main run loop has finished.
        let context = context
        Task { @MainActor in
            withExtendedLifetime(context) { }
        }
    }
}
