import AppKit
import MacPolishKit

/// A deliberately empty app used only by scripts/verify_relaunch.sh. It never
/// creates product controllers, event taps, windows, or permission prompts.
@MainActor
final class RelaunchProbe: NSObject, NSApplicationDelegate {
    static func run() {
        let application = NSApplication.shared
        let delegate = RelaunchProbe()
        application.delegate = delegate
        application.setActivationPolicy(.prohibited)
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also exits if the verification process is interrupted before cleanup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApp.terminate(nil) }
    }
}

@MainActor
enum NativeRelaunchVerification {
    static func run(probeURL: URL) async throws {
        guard Bundle(url: probeURL)?.object(forInfoDictionaryKey: "MacPolishRelaunchProbe") as? Bool == true else {
            throw ProbeError.invalidProbe
        }
        let launcher = TrackedNativeLauncher()
        defer {
            // These IDs came from our own launch requests and are checked
            // against the probe bundle before terminating them.
            for app in launcher.applications where app.bundleURL?.resolvingSymlinksInPath() == probeURL.resolvingSymlinksInPath() {
                NSRunningApplication(processIdentifier: app.processIdentifier)?.terminate()
            }
        }
        for _ in 0..<2 {
            let state = NativeHandoffState()
            let relauncher = AppRelauncher(
                applicationURL: probeURL, currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                launcher: launcher, timeout: .seconds(8),
                terminateCurrentApplication: { state.terminationCount += 1 }
            )
            relauncher.relaunch { state.result = $0 }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while state.result == nil && ContinuousClock.now < deadline {
                pumpAppKit()
                try await Task.sleep(for: .milliseconds(50))
            }
            guard state.result == true, state.terminationCount == 1,
                  let app = launcher.applications.last, app.isFinishedLaunching, !app.isTerminated else {
                throw ProbeError.handoffFailed
            }
            guard app.bundleURL?.resolvingSymlinksInPath() == probeURL.resolvingSymlinksInPath(),
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                throw ProbeError.wrongApplication
            }
        }
        guard launcher.applications.count == 2,
              launcher.applications[0].processIdentifier != launcher.applications[1].processIdentifier else {
            throw ProbeError.reusedProcess
        }
        print("Native relaunch handoff verified two distinct, fully started probe processes.")
    }

    private static func pumpAppKit() {
        // NSRunningApplication updates its cached state on the main run loop.
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

@MainActor
private final class TrackedNativeLauncher: ApplicationInstanceLaunching {
    let nativeLauncher = WorkspaceApplicationLauncher()
    var applications: [any RelaunchedApplication] = []

    func launch(at url: URL, completion: @escaping @MainActor ((any RelaunchedApplication)?) -> Void) {
        nativeLauncher.launch(at: url) { [self] app in
            if let app { applications.append(app) }
            completion(app)
        }
    }
}

@MainActor
private final class NativeHandoffState {
    var result: Bool?
    var terminationCount = 0
}

private enum ProbeError: Error {
    case invalidProbe
    case handoffFailed
    case wrongApplication
    case reusedProcess
}
