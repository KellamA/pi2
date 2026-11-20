import AppKit
import SwiftUI

/// A SwiftUI hosting view, whatever content it hosts: `NSHostingView` is generic, so this is how code that does not know
/// the content tells one apart and reads its sizing options.
@MainActor
public protocol HostingSizing: AnyObject {
    var sizingOptions: NSHostingSizingOptions { get set }
}

extension NSHostingView: HostingSizing {}

extension View {
    /// For the whole content of a window: lays it out at least `width` by `height`, which with the title bar and toolbar
    /// is the window's smallest size, and works that size out without asking the content (#400).
    ///
    /// SwiftUI hosts a window's content in a hosting view that, for a `Window` or `WindowGroup` scene, sets the window's
    /// smallest size from its content's. It works it out in every Update Constraints pass of the window, from inside the
    /// pass, and the app crashed there in the background on 18 November 2026: working it out found the view's size
    /// changed, asked the window for another pass, and so on until AppKit gave up. What kept the size changing was not
    /// found. SwiftUI owns that view and puts its sizing options back whenever the scene updates, so they cannot be
    /// changed from here. What can be is what the view asks: here it is a clear base of the smallest size, which answers
    /// at once and the same every time, and the content is laid over it, at the size of the window, and never measured
    /// for the window's smallest size. A plain `frame(minWidth:minHeight:)` gave the same size, but measured the whole
    /// content each time to give it, the split view and the hosting views of its columns included.
    ///
    /// `report` is told, in a line for a log, when the window or a hosting view in it changes size over and over without
    /// the run loop turning in between: the sign of a size that does not settle, naming the view (`SizeWatch`).
    public func windowMinimum(width: CGFloat, height: CGFloat, report: @escaping @MainActor (String) -> Void = { _ in }) -> some View {
        Color.clear
            .frame(minWidth: width, minHeight: height)
            .overlay { self }
            .watchWindowSize(report: report)
    }

    /// A watch on content whose window is owned by SwiftUI. `name` can identify a window that has no title.
    public func watchWindowSize(name: String? = nil, threshold: Int = SizeWatch.threshold, report: @escaping @MainActor (String) -> Void) -> some View {
        background(SizeWatcher(name: name, threshold: threshold, report: report))
    }

    /// For the content of a split view's column: never asks the column for more height than the window gives it.
    ///
    /// Each column is a hosting view of its own, which sets the column's smallest size from its content's. Content
    /// that does not scroll, such as requests stacked above the message field, could ask for more height than the
    /// window has, and the split view was then laid out taller than the window, its sidebar pushed up under the title
    /// bar. Its width is left as it is: how wide the content must be decides when the sidebar gives way.
    public func columnGivesWay() -> some View {
        frame(minHeight: 0, maxHeight: .infinity)
    }
}

/// An empty view that keeps a `SizeWatch` on the window it is in.
private struct SizeWatcher: NSViewRepresentable {
    let name: String?
    let threshold: Int
    let report: @MainActor (String) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher(name: name, threshold: threshold, report: report) }
    func updateNSView(_ view: Watcher, context: Context) {}

    static func dismantleNSView(_ view: Watcher, coordinator: ()) {
        view.watch.stop()
    }

    final class Watcher: NSView {
        let watch: SizeWatch

        init(name: String?, threshold: Int, report: @escaping @MainActor (String) -> Void) {
            watch = SizeWatch(name: name, threshold: threshold, report: report)
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { watch.start(window) } else { watch.stop() }
        }
    }
}

/// Watches a window for a size that does not settle: a SwiftUI hosting view in it, the window's own included, changing
/// size again and again without the run loop turning in between, as it would in the passes before AppKit gives up
/// (#400). The first time in a launch, it reports a line naming the view, its last sizes and the window's, for
/// app.log, so that if the crash comes back the log says which view it was. It does no layout of its own, which inside
/// such a pass would only add to it.
@MainActor
public final class SizeWatch {
    /// Changes of size of one view in one turn of the run loop before it is reported. A window resized by hand changes
    /// it once or twice a turn; AppKit gives up after as many passes as the window has views, hundreds.
    public static let threshold = 40
    /// A pill has only a few AppKit views, and AppKit can stop after fewer than 40 passes.
    public static let panelThreshold = 4

    private let name: String?
    private let threshold: Int
    private let report: @MainActor (String) -> Void
    private weak var window: NSWindow?
    private var observer: NSObjectProtocol?
    private var counts: [ObjectIdentifier: (name: String, sizes: [CGSize])] = [:]
    private var resetScheduled = false
    private var settingFrame = false
    public private(set) var reported = false

    public init(name: String? = nil, threshold: Int = SizeWatch.threshold, report: @escaping @MainActor (String) -> Void) {
        self.name = name
        self.threshold = threshold
        self.report = report
    }

    public func start(_ window: NSWindow) {
        stop()
        self.window = window
        // Every view's change of frame is posted to all observers, so this one is told of views in other windows too
        // and keeps only the hosting views in this one.
        observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: nil, queue: nil) { [weak self] note in
            // A view's frame changes on the main thread, which is where this is told of it.
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let self, let view = object as? NSView, view is HostingSizing, let window = self.window, view.window === window else { return }
                self.changed(view, in: window)
            }
        }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        window = nil
        counts = [:]
    }

    /// Apply an explicit resize without counting it as unexpected layout churn. Do not display synchronously.
    package func setFrame(_ frame: NSRect, of window: NSWindow) {
        guard frame != window.frame else { return }
        settingFrame = true
        defer { settingFrame = false }
        window.setFrame(frame, display: false)
    }

    private func changed(_ view: NSView, in window: NSWindow) {
        guard !reported, !settingFrame else { return }
        let key = ObjectIdentifier(view)
        let size = view.frame.size
        guard counts[key]?.sizes.last != size else { return }
        if !resetScheduled {
            resetScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.counts = [:]
                    self?.resetScheduled = false
                }
            }
        }
        var entry = counts[key] ?? (name: Self.name(of: view, in: window), sizes: [])
        entry.sizes.append(size)
        counts[key] = entry
        guard entry.sizes.count >= threshold else { return }
        reported = true
        let last = entry.sizes.suffix(6).map(Self.text).joined(separator: ", ")
        report("The window “\(name ?? window.title)” did not settle on a size: \(entry.name) changed size \(entry.sizes.count) times without the run loop turning (last \(last)). The window is \(Self.text(window.frame.size)), its smallest content size \(Self.text(window.contentMinSize)).")
    }

    /// The view's kind, with what it hosts cut short: SwiftUI's types run to thousands of characters.
    static func name(of view: NSView, in window: NSWindow) -> String {
        let type = String(describing: Swift.type(of: view))
        let short = type.count > 240 ? String(type.prefix(240)) + "…" : type
        return view === window.contentView ? "the window's own hosting view, \(short)" : short
    }

    static func text(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }
}
