import AppKit
import PiStyle
import SwiftUI

/// The pill's window and contents, shared by the app and the off-screen window check.
///
/// The hosting view is never the window's content view (#589). An `NSHostingView` that is a window's content view sizes
/// that window itself after each layout, to its content's ideal size; the pill's label is shortened in the middle to
/// fit, so at each narrower width it asked for a little less, the passes never settled, and AppKit threw once there were
/// more of them than views in the window, which ended the app. The window's content view is a plain `NSView` here
/// (`PanelContent`), holding the hosting view at a frame set by hand, and the pill's size comes from its text at full
/// length, capped to the screen: the same size however often it is asked for, and whatever size the window has now.
@MainActor
package final class IndicatorPanel {
    package private(set) var panel: NSPanel?
    private var host: NSHostingController<IndicatorPill>?
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
        let pill: IndicatorPill
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
        if panel == nil { makePanelAndContent() }
        coming = Coming(pill: IndicatorPill(text: text, reveal: reveal, stop: stop), limit: max(1, (visibleFrame.width - 24).rounded(.down)), visibleFrame: visibleFrame)
        // A computer action brings a show of its own every few milliseconds. One frame for all of them in a turn.
        guard !applying else { return }
        applying = true
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private func makePanelAndContent() {
        let panel = makePanel()
        panel.title = row == 0 ? "Computer Indicator" : "Browser Indicator"
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingController(rootView: IndicatorPill(text: "", reveal: nil, stop: {}))
        // Nothing is measured for inside AppKit's passes, and the window is never SwiftUI's to size (#542, #589).
        host.sizingOptions = []
        let content = PanelContent()
        panel.contentView = content
        content.hold(host.view)
        self.panel = panel
        self.host = host
    }

    private func apply() {
        applying = false
        guard let coming, let panel, let host else { return }
        self.coming = nil
        host.rootView = coming.pill
        // The label at its full length, capped to the screen: no proposal from the window's present width, so asking
        // twice gives the same size (#589).
        let fitting = host.sizeThatFits(in: NSSize(width: .greatestFiniteMagnitude, height: coming.visibleFrame.height))
        let size = NSSize(width: min(coming.limit, ceil(fitting.width)), height: ceil(fitting.height))
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

private struct IndicatorPill: View {
    let text: String
    let reveal: (() -> Void)?
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Spinner(size: 11)
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.tx)
                .lineLimit(1).truncationMode(.middle)
            Text("Esc Esc").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.tx3)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Theme.card2, in: .rect(cornerRadius: 4))
                .fixedSize()
            if let reveal {
                Button("Show") { reveal() }
                    .buttonStyle(PiButtonStyle(kind: .secondary, compact: true))
                    .fixedSize()
                    .help("Show the page in pi²’s browser")
            }
            Button("Stop", systemImage: "stop.fill", action: stop)
                .buttonStyle(PiButtonStyle(kind: .danger, compact: true))
                .fixedSize()
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 7)
        .background(Theme.panel, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.acc.opacity(0.55)))
        .padding(6)
        .environment(\.colorScheme, .dark)
    }
}
