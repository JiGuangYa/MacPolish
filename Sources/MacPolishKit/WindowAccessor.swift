import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowResolvingView {
        let view = WindowResolvingView(frame: .zero)
        view.onResolve = onResolve
        view.resolveWindow()
        return view
    }

    func updateNSView(_ nsView: WindowResolvingView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveWindow()
    }
}

/// A SwiftUI view can attach after the first queued lookup has already run.
/// Observe attachment itself, and discard lookups queued for an older host.
@MainActor
package final class WindowResolvingView: NSView {
    package var onResolve: ((NSWindow) -> Void)?
    private var resolutionID = UUID()

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveWindow()
    }

    package func resolveWindow() {
        let resolutionID = UUID()
        self.resolutionID = resolutionID
        DispatchQueue.main.async { [weak self] in
            guard let self, self.resolutionID == resolutionID, let window = self.window else { return }
            self.onResolve?(window)
        }
    }
}
