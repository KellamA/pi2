import AppKit
import PiStyle
import SwiftUI

/// The activity pill, drawn with AppKit views alone (#589).
///
/// No SwiftUI view is left in this panel. A hosting view listens for its window's layout wherever it sits, and sizes the
/// window from its content, which is what kept pi² crashing while agents used the computer, through two releases; the
/// app's own code cannot reach into that, and the window check could not make it happen again to prove it had stopped.
/// What is here instead is views whose frames this file sets by hand, from sizes measured once from the full text and
/// capped to the screen. It looks as the SwiftUI pill did: the numbers below are the ones it was laid out with.
@MainActor
package final class PillView: NSView {
    private enum Metrics {
        static let gap: CGFloat = 9
        static let leading: CGFloat = 12
        static let trailing: CGFloat = 8
        static let vertical: CGFloat = 7
        static let margin: CGFloat = 6
        /// The spinner's ring, as the SwiftUI `Spinner` drew it.
        static let spinner: CGFloat = 11
    }

    private let spinner = PillSpinner(size: Metrics.spinner)
    private let label = PillLabel()
    private let hint = PillHint(text: "Esc Esc")
    private var show: PillButton?
    private let stopButton = PillButton(title: "Stop", symbol: "stop.fill", tint: Theme.bad, background: Theme.card2)

    package init() {
        super.init(frame: .zero)
        // The pill has always drawn itself in the dark palette, whatever the Mac's appearance.
        appearance = NSAppearance(named: .darkAqua)
        addSubview(spinner)
        addSubview(label)
        addSubview(hint)
        addSubview(stopButton)
        stopButton.perform = {}
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// What the pill shows: the line the app gives it, the Show button's action when there is one, and Stop's.
    package func update(text: String, reveal: (() -> Void)?, stop: @escaping () -> Void) {
        label.stringValue = text
        if let reveal {
            let button = show ?? PillButton(title: "Show", symbol: nil, tint: Theme.tx, background: Theme.card2)
            button.perform = reveal
            button.toolTip = "Show the page in pi²’s browser"
            if show == nil {
                addSubview(button)
                show = button
            }
        } else {
            show?.removeFromSuperview()
            show = nil
        }
        stopButton.perform = stop
        needsLayout = true
    }

    /// The size the pill needs, whatever size it has now: its label at full length, capped so that the whole pill fits
    /// the width it is given (#589).
    package func fittedSize(limit: CGFloat) -> NSSize {
        let beside = besideSizes()
        let gaps = Metrics.gap * CGFloat(max(0, beside.count))
        let chrome = Metrics.margin * 2 + Metrics.leading + Metrics.trailing + gaps
        let width = min(limit, chrome + beside.reduce(0) { $0 + $1.width } + label.fullWidth)
        let tallest = (beside + [NSSize(width: 0, height: label.lineHeight)]).reduce(0) { max($0, $1.height) }
        return NSSize(width: width.rounded(.up), height: (Metrics.margin * 2 + Metrics.vertical * 2 + tallest).rounded(.up))
    }

    package override func layout() {
        super.layout()
        let capsule = NSRect(x: Metrics.margin, y: Metrics.margin, width: bounds.width - 2 * Metrics.margin, height: bounds.height - 2 * Metrics.margin)
        let beside = besideSizes()
        let gaps = Metrics.gap * CGFloat(max(0, beside.count))
        let fixed = Metrics.leading + Metrics.trailing + gaps + beside.reduce(0) { $0 + $1.width }
        let labelWidth = max(1, min(label.fullWidth, bounds.width - 2 * Metrics.margin - fixed))
        let sizes = [NSSize(width: spinner.frame.width, height: spinner.frame.height), NSSize(width: labelWidth, height: label.lineHeight), hint.size]
            + (show.map { [$0.size] } ?? []) + [stopButton.size]
        var x = capsule.minX + Metrics.leading
        for (view, size) in zip(items(), sizes) {
            view.frame = NSRect(x: x.rounded(), y: (capsule.midY - size.height / 2).rounded(), width: size.width, height: size.height)
            x += size.width + Metrics.gap
        }
    }

    /// The capsule, its border, and then the parts over it.
    package override func draw(_ dirtyRect: NSRect) {
        let capsule = NSRect(x: Metrics.margin, y: Metrics.margin, width: bounds.width - 2 * Metrics.margin, height: bounds.height - 2 * Metrics.margin)
        let path = NSBezierPath(roundedRect: capsule.insetBy(dx: 0.5, dy: 0.5), xRadius: capsule.height / 2, yRadius: capsule.height / 2)
        NSColor(Theme.panel).setFill()
        path.fill()
        NSColor(Theme.acc).withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// The parts beside the label, in the order they are shown.
    private func items() -> [NSView] {
        [spinner, label, hint] + (show.map { [$0] } ?? []) + [stopButton]
    }

    /// The sizes of the parts beside the label, which is the one part whose width the pill's width decides.
    private func besideSizes() -> [NSSize] {
        [NSSize(width: Metrics.spinner, height: Metrics.spinner), hint.size] + (show.map { [$0.size] } ?? []) + [stopButton.size]
    }
}

/// The spinner's ring, turned by Core Animation, as `PiStyle.Spinner` draws it: a layer's animation runs outside the app,
/// where a repeating SwiftUI animation laid the window out every frame (#347). An `NSProgressIndicator` here would be
/// the system's grey one, and the pill's ring is the accent colour.
@MainActor
private final class PillSpinner: NSView {
    private let turning = CALayer()
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    init(size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.masksToBounds = false
        for ring in [track, arc] {
            ring.fillColor = nil
            ring.lineWidth = 2
            turning.addSublayer(ring)
        }
        arc.lineCap = .round
        arc.strokeEnd = 0.28
        layer?.addSublayer(turning)
        setAccessibilityElement(true)
        setAccessibilityLabel("Working")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        turning.bounds = bounds
        turning.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGPath(ellipseIn: bounds, transform: nil)
        track.path = path
        arc.path = path
        colour()
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colour()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, turning.animation(forKey: "turn") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        // Clockwise on screen, as the SwiftUI spinner turned.
        turn.toValue = -2 * Double.pi
        turn.duration = 0.9
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        turning.add(turn, forKey: "turn")
    }

    private func colour() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor(Theme.acc)
            arc.strokeColor = accent.cgColor
            track.strokeColor = accent.withAlphaComponent(0.18).cgColor
        }
    }
}

/// The pill's line: one line, shortened in the middle when there is not room for all of it.
@MainActor
private final class PillLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 12.5, weight: .medium)
        textColor = NSColor(Theme.tx)
        lineBreakMode = .byTruncatingMiddle
        maximumNumberOfLines = 1
        usesSingleLineMode = true
        cell?.truncatesLastVisibleLine = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The whole line, unmeasured by any width: what the pill's width is worked out from (#589).
    var fullWidth: CGFloat {
        // Four points more than the text itself: what the label's cell keeps at each side, which it would otherwise
        // take out of the text and shorten it in the middle for no reason.
        ceil(NSAttributedString(string: stringValue, attributes: [.font: font ?? .systemFont(ofSize: 12.5)]).size().width) + 4
    }

    var lineHeight: CGFloat {
        ceil(NSAttributedString(string: stringValue.isEmpty ? " " : stringValue, attributes: [.font: font ?? .systemFont(ofSize: 12.5)]).size().height)
    }
}

/// The "Esc Esc" hint: small text on a rounded card.
@MainActor
private final class PillHint: NSTextField {
    init(text: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        font = .systemFont(ofSize: 10.5, weight: .medium)
        textColor = NSColor(Theme.tx3)
        wantsLayer = true
        layer?.cornerRadius = 4
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(Theme.card2).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The text plus the padding it sits in: five points each side, a point and a half above and below.
    var size: NSSize {
        let text = NSAttributedString(string: stringValue, attributes: [.font: font ?? .systemFont(ofSize: 10.5)]).size()
        return NSSize(width: ceil(text.width) + 10, height: ceil(text.height) + 3)
    }
}

/// One of the pill's buttons, drawn as `PiButtonStyle` drew it: a rounded card with a hairline border, an optional
/// symbol before the title, and the title's colour for a quiet button or red for the risky one.
@MainActor
private final class PillButton: NSButton {
    /// What the button does, in place of a target and a selector.
    var perform: () -> Void = {}

    init(title: String, symbol: String?, tint: SwiftUI.Color, background: SwiftUI.Color) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        // The title, and the symbol when there is one, centred in the card the way the SwiftUI button style had them:
        // the symbol is part of the title, so the two are one line and centre together.
        alignment = .center
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(background).cgColor
            layer?.borderColor = NSColor(Theme.line2).cgColor
        }
        let colour = NSColor(tint)
        let text = NSMutableAttributedString()
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) {
            let attachment = NSTextAttachment()
            attachment.image = Self.tinted(image, colour)
            attachment.bounds = NSRect(x: 0, y: -1.5, width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: title))
        text.addAttributes([.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: colour], range: NSRange(location: 0, length: text.length))
        attributedTitle = text
        setAccessibilityLabel(title)
        target = self
        action = #selector(pressed)
    }

    /// The symbol in the button's colour, as SwiftUI tinted it.
    private static func tinted(_ image: NSImage, _ colour: NSColor) -> NSImage {
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        colour.set()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func pressed() { perform() }

    /// The title with the padding `PiButtonStyle` gave it: eight points each side, three above and below.
    var size: NSSize {
        let title = NSAttributedString(string: self.title, attributes: [.font: NSFont.systemFont(ofSize: 12.5)]).size()
        return NSSize(width: ceil(attributedTitle.size().width) + 16, height: ceil(title.height) + 6)
    }
}
