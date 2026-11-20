import AppKit
import SwiftUI
import WindowKit

/// The window work done on a small window, counted whichever code asked for it (#589): the frames set, the layout and
/// Update Constraints passes, and the resizes. The system log's repeating pass was SwiftUI resizing the window it was
/// the content view of, from inside a layout pass, so these counts are what shows whether that happens again.
@MainActor
final class CountedPanel: NSPanel {
    private(set) var framesSet = 0
    private(set) var layouts = 0
    private(set) var constraintPasses = 0
    private(set) var resizes = 0
    private var observer: NSObjectProtocol?

    // A designated initializer: a convenience one on a panel subclass gives the window a title bar, whatever mask it is
    // given, and with a title bar the content view is 28 points shorter than the count of passes is about.
    init(contentRect: NSRect = .zero, styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: true)
    }

    required init?(coder: NSCoder) { nil }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        framesSet += 1
        super.setFrame(frameRect, display: flag)
    }

    override func layoutIfNeeded() {
        layouts += 1
        super.layoutIfNeeded()
    }

    override func updateConstraintsIfNeeded() {
        constraintPasses += 1
        super.updateConstraintsIfNeeded()
    }

    /// The check keeps every window it makes off every screen. AppKit would otherwise pull a visible window onto one,
    /// which changes the frames the check is counting, and needs a display to run at all.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func countResizes() {
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.resizes += 1 }
        }
    }

    func reset() {
        framesSet = 0
        layouts = 0
        constraintPasses = 0
        resizes = 0
    }

    var counts: String {
        "frames set \(framesSet), layout passes \(layouts), Update Constraints passes \(constraintPasses), resizes \(resizes)"
    }

    /// A display cycle as AppKit runs one for a window that needs it: Update Constraints, then layout.
    func cycle() {
        updateConstraintsIfNeeded()
        layoutIfNeeded()
    }
}

/// Lets one turn of the run loop pass, and the display cycle that goes with it.
@MainActor
func nextTurn() async {
    await withCheckedContinuation { (turned: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { turned.resume() }
    }
}

// MARK: - The pill

/// One pill as the app makes it, its window made by the check so that the passes can be counted.
@MainActor
private final class PillProbe {
    let pill: IndicatorPanel
    let panel: CountedPanel
    let reports = Lines()

    init?(row: Int, visibleFrame: NSRect) {
        let counted = CountedPanel()
        pill = IndicatorPanel(row: row, makePanel: { counted })
        panel = counted
        counted.countResizes()
        show(agent: "Atlas", app: "Notes", reveal: row == 1 ? {} : nil, visibleFrame: visibleFrame)
        guard pill.panel === counted else { return nil }
    }

    func show(agent: String, app: String, reveal: (() -> Void)?, visibleFrame: NSRect) {
        let reports = reports
        pill.show(
            agent: agent, app: app, doing: "is using",
            reveal: reveal, report: { reports.lines.append($0) }, stop: {}, visibleFrame: visibleFrame
        )
    }

    /// The hosting view, which sits inside the panel's plain content view (#589).
    var hosted: NSView? { panel.contentView?.subviews.first { $0 is HostingSizing } }

    func close() { pill.dismiss() }
}

// MARK: - Quick Ask

/// The shape of Quick Ask's content: 620 points wide, as tall as its text needs, and it says so as the text changes.
private struct QuickAskLike: View {
    let text: String
    let heightChanged: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Ask anything…").font(.title3)
            }
            if !text.isEmpty {
                Divider()
                Text(text).fixedSize(horizontal: false, vertical: true)
                HStack { Button("Open in pi²") {}; Button("New Question") {}; Spacer(); Text("esc to close").font(.caption) }
            }
        }
        .padding(16)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heightChanged($0) }
        .background(.regularMaterial)
    }
}

/// Quick Ask's panel, made as the app makes it: a plain content view holding the hosting view, its height set from the
/// content one turn at a time, with the top edge in place.
@MainActor
private final class QuickAskProbe {
    let panel: CountedPanel
    let host: NSHostingView<QuickAskLike>
    let watch: SizeWatch
    let height: PanelHeight
    let reports = Lines()

    init() {
        panel = CountedPanel(contentRect: NSRect(x: -20000, y: -20000, width: 620, height: 120), styleMask: [.titled, .fullSizeContentView, .utilityWindow])
        panel.title = "Quick Ask"
        panel.countResizes()
        let reports = reports
        watch = SizeWatch(threshold: SizeWatch.panelThreshold) { reports.lines.append($0) }
        let host = NSHostingView(rootView: QuickAskLike(text: "", heightChanged: { _ in }))
        host.sizingOptions = []
        let content = PanelContent()
        panel.contentView = content
        content.hold(host)
        self.host = host
        watch.start(panel)
        height = PanelHeight(panel: panel, watch: watch)
        host.rootView = QuickAskLike(text: "") { [weak self] in self?.height.want($0) }
        panel.orderFrontRegardless()
    }

    func show(_ text: String) {
        host.rootView = QuickAskLike(text: text) { [weak self] in self?.height.want($0) }
    }

    func close() { panel.orderOut(nil) }
}

// MARK: - The menu bar window

/// The shape of the menu bar window's content: 360 points wide, its rows one line each, so that its ideal size is the
/// same whatever width it is given.
private struct MenuBarLike: View {
    let waiting: String
    let rows: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Ask Atlas…", text: .constant("")).textFieldStyle(.roundedBorder).lineLimit(1...6)
            if !waiting.isEmpty {
                Text("NEEDS YOU").font(.caption2.weight(.semibold))
                Text(waiting).lineLimit(3)
            }
            Text("RUNNING").font(.caption2.weight(.semibold))
            if rows.isEmpty { Text("Nothing is running.").font(.callout) }
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    Text(row).lineLimit(1)
                    Spacer()
                    Text("working").font(.caption).lineLimit(1)
                }
            }
            Divider()
            HStack { Button("Open pi²") {}; Button("Quick Ask") {}; Spacer(); Button("Quit") {} }
        }
        .padding(14)
        .frame(width: 360)
    }
}

/// The menu bar window, made as SwiftUI makes it: a panel whose content view is the hosting view, with the options a
/// scene's window gets, and the watch the app puts on its content.
@MainActor
private final class MenuBarProbe {
    let panel: CountedPanel
    let host: NSHostingView<MenuBarLike>
    let watch: SizeWatch
    let reports = Lines()

    init() {
        panel = CountedPanel(contentRect: NSRect(x: -20000, y: -20000, width: 360, height: 200))
        panel.title = "Menu Bar"
        panel.countResizes()
        let reports = reports
        watch = SizeWatch(name: "Menu Bar", threshold: SizeWatch.panelThreshold) { reports.lines.append($0) }
        let host = NSHostingView(rootView: MenuBarLike(waiting: "", rows: []))
        host.sizingOptions = [.minSize]
        panel.contentView = host
        self.host = host
        watch.start(panel)
        panel.orderFrontRegardless()
    }

    func show(waiting: String, rows: [String]) {
        host.rootView = MenuBarLike(waiting: waiting, rows: rows)
    }

    func close() { panel.orderOut(nil) }
}

// MARK: - The check

@MainActor
func indicatorCheck() async {
    await pillCheck()
    await quickAskCheck()
    await menuBarCheck()
}

@MainActor
private func pillCheck() async {
    // The app's pill, at a laptop's width and at a narrow one, ordered off screen as the check's other windows are, so
    // that AppKit runs the display cycle without anything appearing on the person's screen.
    let screens: [(name: String, visible: NSRect)] = [
        ("a 1800-point screen", NSRect(x: -20000, y: -20000, width: 1800, height: 1128)),
        ("a 440-point screen", NSRect(x: -20000, y: -20000, width: 440, height: 900)),
    ]
    // The names in the report #542 added, and one long enough to be shortened on any screen.
    let agent = "Pi Squared Worker (Deepseek v4.1 Flash)"
    let app = "pi² (test-r571)"
    let longer = (1...6).map { _ in agent }.joined(separator: " and ")

    for (name, visible) in screens {
        let probes = (0...1).compactMap { PillProbe(row: $0, visibleFrame: visible) }
        defer { for probe in probes { probe.close() } }
        check("\(name): both pill rows are made", probes.count == 2)
        guard probes.count == 2 else { continue }
        await settle()
        let limit = (visible.width - 24).rounded(.down)
        let shortFrames = probes.map(\.panel.frame)
        check("\(name): a short name fits without stretching to the width limit", shortFrames.allSatisfy { $0.width > 100 && $0.width < limit }, "frames \(shortFrames)")
        check("\(name): the rows do not cover one another's pill", shortFrames[0].minY >= shortFrames[1].maxY - 6, "frames \(shortFrames)")

        for (row, probe) in probes.enumerated() {
            // The stack in the issue has SwiftUI resizing the window because its content view is the hosting view.
            check("\(name), row \(row): the panel's content view is a plain view, not a hosting view",
                  !(probe.panel.contentView is HostingSizing), "content view \(String(describing: probe.panel.contentView.map { type(of: $0) }))")
            check("\(name), row \(row): the hosting view sits inside the plain view, at a frame set by hand",
                  probe.hosted?.frame == probe.panel.contentView?.bounds, "hosting view \(String(describing: probe.hosted?.frame)), content \(String(describing: probe.panel.contentView?.bounds))")
        }

        // A hundred changes of the content, long and short, some of them several in one turn, each counted: the frame it
        // sets, the display cycle after it, and the turn after that.
        for step in 0..<100 {
            for (row, probe) in probes.enumerated() {
                let long = !step.isMultiple(of: 3)
                let label = "\(name), row \(row), step \(step)"
                probe.panel.reset()
                probe.show(agent: long ? agent : "Atlas", app: long ? app : "Notes", reveal: row == 1 && step.isMultiple(of: 2) ? {} : nil, visibleFrame: visible)
                if step.isMultiple(of: 10) {
                    // Several changes in one turn, as a burst of computer actions makes: one frame for all of them.
                    for _ in 0..<3 { probe.show(agent: longer, app: app, reveal: nil, visibleFrame: visible) }
                }
                await nextTurn()
                check("\(label): at most one frame in the turn after a change", probe.panel.framesSet <= 1, probe.panel.counts)
                let frame = probe.panel.frame
                check("\(label): the centered pill fits the screen with a margin",
                      frame.width <= limit + 0.5 && abs(frame.midX - visible.midX) <= 0.5, "frame \(frame) in \(visible)")
                check("\(label): a long label does not add a line", abs(frame.height - shortFrames[row].height) <= 0.5,
                      "frame \(frame), short \(shortFrames[row])")
                probe.panel.reset()
                probe.panel.cycle()
                check("\(label): at most two layout and two Update Constraints passes in a display cycle",
                      probe.panel.layouts <= 2 && probe.panel.constraintPasses <= 2, probe.panel.counts)
                check("\(label): the display cycle sets no frame of its own and resizes nothing",
                      probe.panel.framesSet == 0 && probe.panel.resizes == 0, probe.panel.counts)
                probe.panel.reset()
                await nextTurn()
                check("\(label): at most one frame in the turn after a display cycle", probe.panel.framesSet <= 1, probe.panel.counts)
            }
        }
        check("\(name): the size watch stayed quiet through every change", probes.allSatisfy { $0.reports.lines.isEmpty },
              probes.flatMap(\.reports.lines).joined(separator: "\n      "))

        // Asking again gives the same size, whatever size the window has when it is asked (#589).
        for (row, probe) in probes.enumerated() {
            probe.show(agent: agent, app: app, reveal: nil, visibleFrame: visible)
            await settle()
            let first = probe.panel.frame
            probe.show(agent: "Atlas", app: "Notes", reveal: nil, visibleFrame: visible)
            await settle()
            probe.panel.setFrame(NSRect(origin: probe.panel.frame.origin, size: NSSize(width: 120, height: probe.panel.frame.height)), display: false)
            probe.show(agent: agent, app: app, reveal: nil, visibleFrame: visible)
            await settle()
            check("\(name), row \(row): the same text gives the same size again, from a window of another width",
                  probe.panel.frame == first, "frame \(probe.panel.frame), first \(first)")
        }
    }
}

@MainActor
private func quickAskCheck() async {
    let probe = QuickAskProbe()
    defer { probe.close() }
    await settle()
    let short = probe.panel.frame
    check("Quick Ask: the content view is a plain view, not a hosting view", !(probe.panel.contentView is HostingSizing),
          "content view \(String(describing: probe.panel.contentView.map { type(of: $0) }))")
    check("Quick Ask: the hosting view sits inside it", probe.panel.contentView?.subviews.first is HostingSizing)
    let long = (1...12).map { "A long answer line \($0) that is long enough to wrap in the panel's width." }.joined(separator: " ")
    var tallest = short.height
    for step in 0..<100 {
        let label = "Quick Ask, step \(step)"
        probe.panel.reset()
        probe.show(step.isMultiple(of: 3) ? "" : (step.isMultiple(of: 2) ? long : "Short answer."))
        if step.isMultiple(of: 10) { probe.show(long + long) }
        await nextTurn()
        check("\(label): at most one frame in the turn after a change", probe.panel.framesSet <= 1, probe.panel.counts)
        check("\(label): the panel keeps its width and its top edge",
              probe.panel.frame.width == short.width && probe.panel.frame.maxY == short.maxY,
              "frame \(probe.panel.frame), short \(short)")
        probe.panel.reset()
        probe.panel.cycle()
        check("\(label): at most two layout and two Update Constraints passes in a display cycle",
              probe.panel.layouts <= 2 && probe.panel.constraintPasses <= 2, probe.panel.counts)
        check("\(label): the display cycle sets no frame of its own and resizes nothing",
              probe.panel.framesSet == 0 && probe.panel.resizes == 0, probe.panel.counts)
        tallest = max(tallest, probe.panel.frame.height)
        probe.panel.reset()
        await nextTurn()
        check("\(label): at most one frame in the turn after a display cycle", probe.panel.framesSet <= 1, probe.panel.counts)
    }
    check("Quick Ask: a longer answer makes the panel taller", tallest > short.height + 100,
          "tallest \(tallest), short \(short)")
    check("Quick Ask: the size watch stayed quiet through every change", probe.reports.lines.isEmpty,
          probe.reports.lines.joined(separator: "\n      "))
}

@MainActor
private func menuBarCheck() async {
    let probe = MenuBarProbe()
    defer { probe.close() }
    await settle()
    let short = probe.panel.frame
    let longRow = (1...8).map { "A conversation title that is long enough to need shortening \($0)" }.joined()
    for step in 0..<100 {
        let label = "Menu Bar, step \(step)"
        let many = !step.isMultiple(of: 3)
        probe.panel.reset()
        probe.show(waiting: many ? longRow + longRow : "", rows: many ? (1...6).map { "\(longRow) \($0)" } : ["Fix the tests"])
        await nextTurn()
        check("\(label): at most one frame in the turn after a change", probe.panel.framesSet <= 1, probe.panel.counts)
        check("\(label): it keeps its width", abs(probe.panel.frame.width - short.width) <= 0.5,
              "frame \(probe.panel.frame), short \(short)")
        probe.panel.reset()
        probe.panel.cycle()
        check("\(label): at most two layout and two Update Constraints passes in a display cycle",
              probe.panel.layouts <= 2 && probe.panel.constraintPasses <= 2, probe.panel.counts)
        check("\(label): the display cycle sets the frame at most once", probe.panel.framesSet <= 1, probe.panel.counts)
        probe.panel.reset()
        await nextTurn()
        check("\(label): at most one frame in the turn after a display cycle", probe.panel.framesSet <= 1, probe.panel.counts)
    }
    check("Menu Bar: the size watch stayed quiet through every change", probe.reports.lines.isEmpty,
          probe.reports.lines.joined(separator: "\n      "))
}
