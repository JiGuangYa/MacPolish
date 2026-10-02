import AppKit
import ApplicationServices

/// SwiftUI's virtual containers can implement public accessibility selectors
/// without declaring the full NSAccessibility protocol. Preserve those containers
/// when walking between AppKit controls and SwiftUI accessibility nodes.
@MainActor
struct NativeAccessibilityElement {
    let object: NSObject
    private var modern: (any NSAccessibilityProtocol)? { object as? any NSAccessibilityProtocol }

    private func attribute(_ attribute: NSAccessibility.Attribute, selector: Selector) -> Any? {
        if object.responds(to: selector) {
            return object.perform(selector)?.takeUnretainedValue()
        }
        return object.accessibilityAttributeValue(attribute)
    }

    // These public NSAccessibility selectors return Objective-C BOOL. Use the
    // correct return signature instead of NSObject.perform's object result.
    func booleanResult(for selector: Selector) -> Bool? {
        guard object.responds(to: selector), let implementation = object.method(for: selector) else { return nil }
        typealias BooleanMethod = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: BooleanMethod.self)(object, selector)
    }

    func accessibilityRole() -> NSAccessibility.Role? {
        modern?.accessibilityRole() ?? (attribute(.role, selector: #selector(NSAccessibilityProtocol.accessibilityRole)) as? String).map(NSAccessibility.Role.init(rawValue:))
    }

    func accessibilityLabel() -> String? {
        modern?.accessibilityLabel() ?? attribute(.description, selector: #selector(NSAccessibilityProtocol.accessibilityLabel)) as? String
    }

    func accessibilityTitle() -> String? {
        modern?.accessibilityTitle() ?? attribute(.title, selector: #selector(NSAccessibilityProtocol.accessibilityTitle)) as? String
    }

    func accessibilityValueDescription() -> String? {
        modern?.accessibilityValueDescription() ?? attribute(.valueDescription, selector: #selector(NSAccessibilityProtocol.accessibilityValueDescription)) as? String
    }

    func accessibilityValue() -> Any? {
        modern?.accessibilityValue() ?? attribute(.value, selector: #selector(NSAccessibilityProtocol.accessibilityValue))
    }

    func isAccessibilityEnabled() -> Bool {
        modern?.isAccessibilityEnabled() ?? booleanResult(for: #selector(NSAccessibilityProtocol.isAccessibilityEnabled)) ??
            (object.accessibilityAttributeValue(.enabled) as? Bool ?? false)
    }

    var children: [Any] {
        modern?.accessibilityChildren() ?? attribute(.children, selector: #selector(NSAccessibilityProtocol.accessibilityChildren)) as? [Any] ?? []
    }
}

@MainActor
enum NativeAccessibilityProbe {
    static func adjust(_ slider: NativeAccessibilityElement, increase: Bool) throws {
        try perform(increase ? .increment : .decrement, on: slider)
    }

    static func perform(_ action: NSAccessibility.Action, on element: NativeAccessibilityElement) throws {
        let actions = element.object.accessibilityActionNames()
        if actions.contains(action) {
            element.object.accessibilityPerformAction(action)
            return
        }
        let selector: Selector?
        switch action {
        case .press: selector = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
        case .increment: selector = #selector(NSAccessibilityProtocol.accessibilityPerformIncrement)
        case .decrement: selector = #selector(NSAccessibilityProtocol.accessibilityPerformDecrement)
        default: selector = nil
        }
        // Dispatch once. A false return can still schedule an action in
        // SwiftUI. Never retry it through a second API; observe its effect.
        if let selector, element.booleanResult(for: selector) != nil { return }
        throw ProbeFailure("Element \(type(of: element.object)) does not support \(action.rawValue); enabled=\(element.isAccessibilityEnabled()), actions=\(actions)")
    }

    static func slider(in window: NSWindow) async throws -> NativeAccessibilityElement {
        try await element(withRole: .slider, in: window)
    }

    static func element(withRole role: NSAccessibility.Role, label: String? = nil,
                        in window: NSWindow) async throws -> NativeAccessibilityElement {
        // A self-query asks SwiftUI to publish its lazy accessibility tree.
        // Keep the client request off the main thread so AppKit can reply.
        // Inspect the resulting nodes in-process; recursive client requests
        // back into this same application can deadlock SwiftUI's AX bridge.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let queryResult = await Task.detached {
            let application = AXUIElementCreateApplication(ownPID)
            AXUIElementSetMessagingTimeout(application, 2)
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows).rawValue
        }.value
        guard queryResult == AXError.success.rawValue else {
            throw ProbeFailure("The probe's accessibility self-query failed with AX error \(queryResult)")
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let element = findElement(withRole: role, label: label, in: window) { return element }
            try await Task.sleep(for: .milliseconds(30))
        }
        let nodes = elements(in: window).prefix(30).map {
            "\(type(of: $0.object)) \($0.accessibilityRole()?.rawValue ?? "nil"): label=\($0.accessibilityLabel() ?? "nil"), title=\($0.accessibilityTitle() ?? "nil")"
        }
        throw ProbeFailure("\(window.title) did not expose \(role.rawValue) \(label ?? "") within four seconds; nodes=\(nodes)")
    }

    static func findElement(withRole role: NSAccessibility.Role, label: String? = nil,
                            in window: NSWindow) -> NativeAccessibilityElement? {
        elements(in: window).first {
            $0.accessibilityRole() == role &&
                (label == nil || $0.accessibilityLabel() == label || $0.accessibilityTitle() == label)
        }
    }

    private static func elements(in window: NSWindow) -> [NativeAccessibilityElement] {
        // Stay within this app's content; window chrome can contain remote
        // system widgets with a separate accessibility implementation.
        guard let content = window.contentView else { return [] }
        var pending: [Any] = [content]
        var visited: Set<ObjectIdentifier> = []
        var elements: [NativeAccessibilityElement] = []
        while let raw = pending.popLast(), visited.count < 500 {
            guard let object = raw as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { continue }
            let element = NativeAccessibilityElement(object: object)
            elements.append(element)
            pending.append(contentsOf: element.children)
        }
        return elements
    }
}
