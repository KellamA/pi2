import AppKit
import WindowKit

@MainActor
private final class PillProbe {
    let pill: IndicatorPanel
    let window: NSPanel
    let host: NSView
    let reports: Lines
    private(set) var resizes = 0
    private var observer: NSObjectProtocol?

    init?(row: Int, visibleFrame: NSRect) {
        let pill = IndicatorPanel(row: row)
        let reports = Lines()
        pill.show(agent: "Atlas", app: "Notes", doing: "is using", reveal: row == 1 ? {} : nil, report: { reports.lines.append($0) }, stop: {}, visibleFrame: visibleFrame)
        guard let window = pill.panel, let host = window.contentView else { return nil }
        self.pill = pill
        self.window = window
        self.host = host
        self.reports = reports
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.resizes += 1 }
        }
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        pill.dismiss()
    }
}

@MainActor
func indicatorCheck() async {
    // Order the app's real pills off screen so AppKit still runs the display cycle. No computer actions or Esc monitors.
    // A narrow synthetic screen makes the same check exercise truncation even on a wide display.
    let visible = NSRect(x: -20000, y: -20000, width: 440, height: 900)
    let probes = (0...1).compactMap { PillProbe(row: $0, visibleFrame: visible) }
    defer { for probe in probes { probe.close() } }
    check("both pill rows are made", probes.count == 2)
    guard probes.count == 2 else { return }

    func layOut() {
        for probe in probes {
            probe.window.updateConstraintsIfNeeded()
            probe.window.layoutIfNeeded()
            probe.window.displayIfNeeded()
        }
    }
    layOut()
    await settle()
    let initial = probes.map(\.window.frame)
    let minima = probes.map(\.window.contentMinSize)
    let maxima = probes.map(\.window.contentMaxSize)
    check("short names fit without stretching to the width limit", initial.allSatisfy { $0.width > 100 && $0.width < visible.width - 24 }, "frames \(initial)")
    check("the rows do not cover one another's pill", initial[0].minY >= initial[1].maxY - 6)

    func show(_ step: Int) {
        for (row, probe) in probes.enumerated() {
            let long = !step.isMultiple(of: 3)
            let reveal: (() -> Void)? = row == 1 ? {} : nil
            let resizes = probe.resizes
            probe.pill.show(
                agent: long ? "Pi Squared Worker (Deepseek v4.1 Flash)" + String(repeating: " Long Name", count: step % 8) : "Atlas",
                app: long ? "pi² (test-r541)" : "Notes", doing: row == 0 || !long ? "is using" : "is browsing", reveal: reveal,
                report: { [reports = probe.reports] in reports.lines.append($0) }, stop: {}, visibleFrame: visible
            )
            let frame = probe.window.frame
            check("row \(row): at most one resize per show", probe.resizes - resizes <= 1)
            check("row \(row): one window and host", probe.pill.panel === probe.window && probe.window.contentView === probe.host)
            check("row \(row): the host has no sizing options", (probe.host as? HostingSizing)?.sizingOptions.isEmpty == true)
            check("row \(row): the centered pill leaves a margin", abs(frame.midX - visible.midX) <= 0.5 && frame.width <= visible.width - 24, "frame \(frame)")
            check("row \(row): a long label does not add a line", frame.height == initial[row].height, "frame \(frame), short \(initial[row])")
            check("row \(row): returning to a short name restores its frame", long || frame == initial[row], "frame \(frame), short \(initial[row])")
            if long && step % 8 >= 4 {
                check("row \(row): very long names use the available width", frame.width > initial[row].width, "frame \(frame), short \(initial[row])")
            }
        }
    }

    func checkSettled(_ frames: [NSRect], resizes: [Int]) {
        check("layout does not resize either pill", probes.map(\.window.frame) == frames && probes.map(\.resizes) == resizes)
        check("layout does not set either window's content size limits", probes.map(\.window.contentMinSize) == minima && probes.map(\.window.contentMaxSize) == maxima)
        check("ordinary shows do not trip the panel watches", probes.allSatisfy { $0.reports.lines.isEmpty })
    }

    for step in 0..<100 {
        show(step)
        let frames = probes.map(\.window.frame), resizes = probes.map(\.resizes)
        layOut()
        try? await Task.sleep(for: .milliseconds(10))
        checkSettled(frames, resizes: resizes)
    }
    for step in 100..<200 { show(step) }
    let frames = probes.map(\.window.frame), resizes = probes.map(\.resizes)
    layOut()
    await settle()
    checkSettled(frames, resizes: resizes)

    for (probe, title) in zip(probes, ["Computer Indicator", "Browser Indicator"]) {
        probe.pill.dismiss()
        probe.pill.show(agent: "Atlas", app: "Notes", doing: "is using", reveal: nil,
                            report: { [reports = probe.reports] in reports.lines.append($0) }, stop: {}, visibleFrame: visible)
        await settle()
        check("\(title) keeps the same host when reopened", probe.window.contentView === probe.host)
        for _ in 0..<8 { probe.host.setFrameSize(NSSize(width: probe.host.frame.width + 1, height: probe.host.frame.height)) }
        check("\(title) reports an unsettled hosting size once and names the panel and view",
              probe.reports.lines.count == 1 && probe.reports.lines[0].contains(title) && probe.reports.lines[0].contains("NSHostingView<IndicatorPill>"),
              probe.reports.lines.joined(separator: "\n"))
    }
}
