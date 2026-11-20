import AppKit

/// The content view of a small panel whose content is SwiftUI: a plain `NSView` that holds the hosting view at a frame
/// set by hand. No Auto Layout, and no constraints, so AppKit has nothing to solve and SwiftUI has no window of its own.
///
/// An `NSHostingView` that is a window's content view sizes that window itself after every layout, to its content's
/// ideal size, whatever its sizing options say (#589). The pill's ideal width shrank a little at each narrower width,
/// because its label is shortened in the middle to fit, so the layout passes never settled, and AppKit threw once
/// there were more of them than views in the window, which ended the app. In a plain view the hosting view is measured
/// by nobody but the code that gives it its frame.
@MainActor
package final class PanelContent: NSView {
    private var hosted: NSView?

    /// Puts `view` in the panel, filling it.
    package func hold(_ view: NSView) {
        hosted?.removeFromSuperview()
        hosted = view
        view.frame = bounds
        addSubview(view)
    }

    package override func layout() {
        super.layout()
        guard let hosted, hosted.frame != bounds else { return }
        hosted.frame = bounds
    }
}

/// A small panel's height, taken from its SwiftUI content: as tall as the content says, with the top edge kept in place,
/// one frame change a turn and none from inside the layout that measured it (#542, #589).
@MainActor
package final class PanelHeight {
    private weak var panel: NSPanel?
    private let watch: SizeWatch
    private var pending: CGFloat?

    package init(panel: NSPanel, watch: SizeWatch) {
        self.panel = panel
        self.watch = watch
    }

    /// The height the content needs now. Everything that arrives in one turn is put together into one frame change on
    /// the next turn.
    package func want(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        let scheduled = pending != nil
        pending = height.rounded(.up)
        guard !scheduled else { return }
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private func apply() {
        guard let height = pending else { return }
        pending = nil
        guard let panel else { return }
        var content = panel.contentRect(forFrameRect: panel.frame)
        content.size.height = height
        var frame = panel.frameRect(forContentRect: content)
        frame.origin.y = panel.frame.maxY - frame.height
        watch.setFrame(frame, of: panel)
    }
}
