import SwiftUI

#if PI2_DEVELOPMENT
/// Where a development build was asked to keep its windows, for a throwaway copy that a check launches over and over,
/// so they stop coming up in the middle of the screen of the person at the Mac (docs/development.md):
///
/// - `PI2_WINDOW_ORIGIN=x,y` puts each window's top-left corner there, in points from the top-left corner of the main
///   screen: the measure `kCGWindowBounds` uses.
/// - `PI2_WINDOW_BEHIND=1` keeps the windows behind every other app's windows.
///
/// SwiftUI ignores the frame saved in the preferences for the main window and centres it at launch, and it does not
/// ask `defaultWindowPlacement` for that window either. The Settings window it does place, from its saved frame,
/// after its content is in. So this works on the `NSWindow` itself, from a view inside it: it places the window when
/// the view comes into it, and again each time SwiftUI moves it, until a second after the window is on screen. Done
/// before the window shows, it never appears in the middle first; a window SwiftUI shows before placing it (one a
/// `WindowGroup` opens) may, for that moment.
enum LaunchWindows {
    @MainActor static let origin = parseOrigin(ProcessInfo.processInfo.environment["PI2_WINDOW_ORIGIN"])
    @MainActor static let behind = ["1", "true", "yes"].contains(ProcessInfo.processInfo.environment["PI2_WINDOW_BEHIND"]?.lowercased() ?? "")

    /// "x,y" as a point, or nil for anything else.
    static func parseOrigin(_ value: String?) -> CGPoint? {
        guard let parts = value?.split(separator: ",", omittingEmptySubsequences: false), parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)), x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Just below ordinary windows, and above the desktop. A window there is still drawn and can be captured by its
    /// id, but no other app's ordinary window goes under it, whatever brings it forward later (a sheet, Settings
    /// opening, a click), which ordering it to the back once would not do.
    static let behindLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)

    /// `origin` in AppKit's measure: from the bottom-left corner of the main screen, upwards.
    @MainActor static var topLeft: NSPoint? {
        guard let origin, let main = NSScreen.screens.first else { return nil }
        return NSPoint(x: origin.x, y: main.frame.maxY - origin.y)
    }
}

/// An empty view that keeps its window where `LaunchWindows` says, from when it comes into the window until a second
/// after the window is on screen. After that it is left where it is, or where it was moved to.
private struct LaunchWindowPlacer: NSViewRepresentable {
    func makeNSView(context: Context) -> Placer { Placer() }
    func updateNSView(_ view: Placer, context: Context) {}

    static func dismantleNSView(_ view: Placer, coordinator: ()) {
        view.stopFollowing()
    }

    final class Placer: NSView {
        private var moves: NSObjectProtocol?
        private var shows: NSObjectProtocol?
        /// When the window was first seen on screen. A window a `WindowGroup` opens (a background command's output) is
        /// shown first and moved by SwiftUI just after, so a window is followed for a second after it shows.
        private var shownAt: Date?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopFollowing()
            shownAt = nil
            guard let window else { return }
            if LaunchWindows.behind { window.level = LaunchWindows.behindLevel }
            guard LaunchWindows.topLeft != nil else { return }
            place(window)
            if window.isVisible { shown() }
            moves = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    if window.isVisible { self.shown() }
                    if let shownAt = self.shownAt, Date().timeIntervalSince(shownAt) >= 1 { self.stopFollowing() } else { self.place(window) }
                }
            }
            shows = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window?.isVisible == true else { return }
                    self.shown()
                }
            }
        }

        /// The window is on screen: it is followed for one more second, then left where it is.
        private func shown() {
            guard shownAt == nil else { return }
            shownAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.place(window)
                    self.stopFollowing()
                }
            }
        }

        private func place(_ window: NSWindow) {
            guard let topLeft = LaunchWindows.topLeft, NSPoint(x: window.frame.minX, y: window.frame.maxY) != topLeft else { return }
            window.setFrameTopLeftPoint(topLeft)
        }

        func stopFollowing() {
            if let moves { NotificationCenter.default.removeObserver(moves) }
            if let shows { NotificationCenter.default.removeObserver(shows) }
            moves = nil
            shows = nil
        }
    }
}
#endif

extension View {
    /// For the content of a window: in a development build, keeps the window where `PI2_WINDOW_ORIGIN` and
    /// `PI2_WINDOW_BEHIND` asked.
    func launchWindow() -> some View {
        #if PI2_DEVELOPMENT
        background(LaunchWindowPlacer())
        #else
        self
        #endif
    }
}
