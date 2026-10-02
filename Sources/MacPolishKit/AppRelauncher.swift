import AppKit
import Foundation

@MainActor
public protocol ApplicationRelaunching: AnyObject {
    func relaunch(completion: @escaping @MainActor (Bool) -> Void)
}

@MainActor
package protocol RelaunchedApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var bundleURL: URL? { get }
    var isFinishedLaunching: Bool { get }
    var isTerminated: Bool { get }
}

extension NSRunningApplication: RelaunchedApplication { }

@MainActor
package protocol ApplicationInstanceLaunching: AnyObject {
    func launch(at url: URL, completion: @escaping @MainActor ((any RelaunchedApplication)?) -> Void)
}

@MainActor
package final class WorkspaceApplicationLauncher: ApplicationInstanceLaunching {
    package init() { }

    package func launch(at url: URL, completion: @escaping @MainActor ((any RelaunchedApplication)?) -> Void) {
        let configuration = Self.configuration()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            // AppKit delivers this callback on a concurrent queue.
            Task { @MainActor in completion(error == nil ? application : nil) }
        }
    }

    package static func configuration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        return configuration
    }
}

@MainActor
public final class AppRelauncher: ApplicationRelaunching {
    private let applicationURL: URL
    private let currentProcessIdentifier: pid_t
    private let launcher: ApplicationInstanceLaunching
    private let terminateCurrentApplication: @MainActor () -> Void
    private let timeout: Duration
    private var attempt: RelaunchAttempt?
    private var monitoringTask: Task<Void, Never>?
    private var handedOff = false

    public convenience init() {
        self.init(
            applicationURL: Bundle.main.bundleURL,
            currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            launcher: WorkspaceApplicationLauncher(),
            terminateCurrentApplication: { NSApp.terminate(nil) }
        )
    }

    package init(
        applicationURL: URL,
        currentProcessIdentifier: pid_t,
        launcher: ApplicationInstanceLaunching,
        timeout: Duration = .seconds(15),
        terminateCurrentApplication: @escaping @MainActor () -> Void
    ) {
        self.applicationURL = applicationURL
        self.currentProcessIdentifier = currentProcessIdentifier
        self.launcher = launcher
        self.timeout = timeout
        self.terminateCurrentApplication = terminateCurrentApplication
    }

    deinit { monitoringTask?.cancel() }

    public func relaunch(completion: @escaping @MainActor (Bool) -> Void) {
        guard attempt == nil, !handedOff, isPackagedApplication else {
            completion(false)
            return
        }

        let request = RelaunchAttempt(completion: completion)
        attempt = request
        let deadline = ContinuousClock.now.advanced(by: timeout)
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, self.attempt?.id == request.id else { return }
                if ContinuousClock.now >= deadline {
                    self.finish(request.id, succeeded: false)
                    return
                }
                self.checkLaunch(request.id)
            }
        }
        launcher.launch(at: applicationURL) { [weak self] application in
            guard let self, self.attempt?.id == request.id else { return }
            guard let application else {
                self.finish(request.id, succeeded: false)
                return
            }
            self.attempt?.application = application
            self.checkLaunch(request.id)
        }
    }

    private var isPackagedApplication: Bool {
        guard applicationURL.isFileURL, applicationURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: applicationURL),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let executableURL = bundle.executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    private func checkLaunch(_ requestID: UUID) {
        guard let attempt, attempt.id == requestID, let application = attempt.application else { return }
        guard application.processIdentifier > 0,
              application.processIdentifier != currentProcessIdentifier,
              application.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == applicationURL.resolvingSymlinksInPath().standardizedFileURL,
              !application.isTerminated else {
            finish(requestID, succeeded: false)
            return
        }
        guard application.isFinishedLaunching else { return }
        finish(requestID, succeeded: true)
    }

    private func finish(_ requestID: UUID, succeeded: Bool) {
        guard let request = attempt, request.id == requestID else { return }
        attempt = nil
        monitoringTask?.cancel()
        monitoringTask = nil
        handedOff = succeeded
        request.completion(succeeded)
        if succeeded { terminateCurrentApplication() }
    }
}

@MainActor
private final class RelaunchAttempt {
    let id = UUID()
    let completion: @MainActor (Bool) -> Void
    var application: (any RelaunchedApplication)?

    init(completion: @escaping @MainActor (Bool) -> Void) {
        self.completion = completion
    }
}
