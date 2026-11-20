import AppKit
import PiStyle
import SwiftUI

/// The pill's window and contents, shared by the app and the off-screen window check.
@MainActor
package final class IndicatorPanel {
    package private(set) var panel: NSPanel?
    private var host: NSHostingController<IndicatorPill>?
    private var report: @MainActor (String) -> Void = { _ in }
    private lazy var watch = SizeWatch(threshold: SizeWatch.panelThreshold) { [weak self] in self?.report($0) }
    /// Which line the pill sits on, so that two kinds of work at once do not cover each other.
    private let row: Int

    package init(row: Int) { self.row = row }

    package func show(agent: String, app: String, doing: String, reveal: (() -> Void)?, report: @escaping @MainActor (String) -> Void = { _ in }, stop: @escaping () -> Void, visibleFrame: NSRect? = NSScreen.main?.visibleFrame) {
        guard let visibleFrame else { return }
        self.report = report
        let width = max(1, (visibleFrame.width - 24).rounded(.down))
        let text = "\(agent) \(doing) \(app)".components(separatedBy: .newlines).joined(separator: " ")
        let pill = IndicatorPill(text: text, reveal: reveal, stop: stop)
        let panel: NSPanel
        let host: NSHostingController<IndicatorPill>
        if let existing = self.panel, let hosting = self.host {
            panel = existing
            host = hosting
            host.rootView = pill
        } else {
            panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.title = row == 0 ? "Computer Indicator" : "Browser Indicator"
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            host = NSHostingController(rootView: pill)
            // Never have SwiftUI measure the pill from inside AppKit's Update Constraints pass (#542).
            host.sizingOptions = []
            panel.contentViewController = host
            self.panel = panel
            self.host = host
        }
        // `fittingSize` returns zero with no sizing options. Ask the controller for an explicit measurement instead.
        let fitting = host.sizeThatFits(in: NSSize(width: width, height: visibleFrame.height))
        let size = NSSize(width: min(width, ceil(fitting.width)), height: ceil(fitting.height))
        let origin = NSPoint(x: (visibleFrame.midX - size.width / 2).rounded(), y: (visibleFrame.maxY - size.height - 8 - CGFloat(row) * (size.height - 6)).rounded())
        watch.setFrame(NSRect(origin: origin, size: size), of: panel)
        if !panel.isVisible {
            watch.start(panel)
            panel.orderFrontRegardless()
        }
    }

    package func dismiss() {
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
