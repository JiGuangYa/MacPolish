import AppKit
import Combine

/// Exercises the nested mode used by AppKit menus and dragging without
/// opening UI, dispatching native events, or waiting on the main actor queue.
@MainActor
enum EventTrackingRunLoop {
    static func run(for duration: TimeInterval) {
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
        var heartbeatCount = 0
        let heartbeat = Timer.publish(every: 0.01, on: .main, in: .common)
            .autoconnect()
            .sink { _ in heartbeatCount += 1 }
        defer { heartbeat.cancel() }

        let deadline = ProcessInfo.processInfo.systemUptime + duration
        while ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
        }
        MacPolishVerification.require(heartbeatCount > 0, "Expected the nested tracking loop to deliver common-mode timers")
    }
}
