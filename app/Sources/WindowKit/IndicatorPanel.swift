import AppKit

/// The pill's window, shared by the app and the off-screen window check.
///
/// There is no SwiftUI in this panel at all (#589). An `NSHostingView` sizes the window it is the content view of after
/// each layout, to its content's ideal size: the pill's label is shortened to fit, so at each narrower width it asked for
/// a little less, the passes never settled, and AppKit threw once there were more of them than views in the window,
/// which ended the app. Two releases crashed there, and nothing in the app could make that path prove it had stopped, so
/// the pill is drawn with AppKit views alone (`PillView`) and the window is sized by hand, from the label's full length
/// capped to the screen: the same size however often it is asked for, and whatever size the window has now.
@MainActor
package final class IndicatorPanel {
    package private(set) var panel: NSPanel?
    private var pill: PillView?
    private var report: @MainActor (String) -> Void = { _ in }
    private lazy var watch = SizeWatch(threshold: SizeWatch.panelThreshold) { [weak self] in self?.report($0) }
    /// Which line the pill sits on, so that two kinds of work at once do not cover each other.
    private let row: Int
    /// Makes the panel the first time the pill is shown. The window check gives one that counts AppKit's passes (#589).
    private let makePanel: @MainActor () -> NSPanel
    /// What the pill should show, put together with whatever else arrives in the same turn of the run loop.
    private var coming: Coming?
    private var applying = false

    private struct Coming {
        let text: String
        let reveal: (() -> Void)?
        let stop: () -> Void
        /// The widest the pill may be: the screen's visible width less a margin.
        let limit: CGFloat
        let visibleFrame: NSRect
    }

    package init(row: Int, makePanel: @escaping @MainActor () -> NSPanel = {
        NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    }) {
        self.row = row
        self.makePanel = makePanel
    }

    package func show(agent: String, app: String, doing: String, reveal: (() -> Void)?, report: @escaping @MainActor (String) -> Void = { _ in }, stop: @escaping () -> Void, visibleFrame: NSRect? = NSScreen.main?.visibleFrame) {
        guard let visibleFrame else { return }
        self.report = report
        let text = "\(agent) \(doing) \(app)".components(separatedBy: .newlines).joined(separator: " ")
        if panel == nil { makePanelAndPill() }
        coming = Coming(text: text, reveal: reveal, stop: stop, limit: max(1, (visibleFrame.width - 24).rounded(.down)), visibleFrame: visibleFrame)
        // A computer action brings a show of its own every few milliseconds. One frame for all of them in a turn.
        guard !applying else { return }
        applying = true
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private func makePanelAndPill() {
        let panel = makePanel()
        panel.title = row == 0 ? "Computer Indicator" : "Browser Indicator"
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // A plain view with no Auto Layout and no SwiftUI in it: nothing here can size the window but this class (#589).
        let pill = PillView()
        panel.contentView = pill
        self.panel = panel
        self.pill = pill
    }

    private func apply() {
        applying = false
        guard let coming, let panel, let pill else { return }
        self.coming = nil
        pill.update(text: coming.text, reveal: coming.reveal, stop: coming.stop)
        // The label at its full length, capped to the screen: nothing of the window's present width is asked about, so
        // asking twice gives the same size (#589).
        let size = pill.fittedSize(limit: coming.limit)
        let origin = NSPoint(x: (coming.visibleFrame.midX - size.width / 2).rounded(), y: (coming.visibleFrame.maxY - size.height - 8 - CGFloat(row) * (size.height - 6)).rounded())
        watch.setFrame(NSRect(origin: origin, size: size), of: panel)
        if !panel.isVisible {
            watch.start(panel)
            panel.orderFrontRegardless()
        }
    }

    package func dismiss() {
        coming = nil
        panel?.orderOut(nil)
        watch.stop()
    }
}
