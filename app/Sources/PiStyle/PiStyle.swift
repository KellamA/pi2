import AppKit
import SwiftUI

/// pi²'s look: the palette from the mockups, plus the small pieces (tags, buttons, cards) every screen is built from.
/// Colours are dynamic, so the same names work in dark (the default) and light appearance.
package enum Theme {
    package static let window = dynamic(dark: 0x17181C, light: 0xF7F7FA)
    package static let side = dynamic(dark: 0x1D1E23, light: 0xEDEDF2)
    package static let panel = dynamic(dark: 0x1F2026, light: 0xFFFFFF)
    package static let card = dynamic(dark: 0x24262D, light: 0xF1F1F6)
    package static let card2 = dynamic(dark: 0x2A2C34, light: 0xE8E8F0)
    package static let line = dynamic(dark: 0xFFFFFF, darkAlpha: 0.08, light: 0x000000, lightAlpha: 0.08)
    package static let line2 = dynamic(dark: 0xFFFFFF, darkAlpha: 0.14, light: 0x000000, lightAlpha: 0.14)
    package static let tx = dynamic(dark: 0xECECF1, light: 0x1B1C22)
    package static let tx2 = dynamic(dark: 0xA3A5B0, light: 0x5D5F6C)
    package static let tx3 = dynamic(dark: 0x6E7080, light: 0x8C8E9B)

    /// Lavender in the dark, a deeper violet in the light so text on it stays readable.
    package static let acc = dynamic(dark: 0x8B93FF, light: 0x5B62E8)
    package static let ok = dynamic(dark: 0x4CC38A, light: 0x1D9A60)
    package static let warn = dynamic(dark: 0xF0B24A, light: 0xB87507)
    package static let bad = dynamic(dark: 0xF2647A, light: 0xD3384F)
    /// A branch with commits of its own not yet pushed or merged.
    package static let ahead = dynamic(dark: 0x5BA8FF, light: 0x1F6FDB)
    /// A branch whose work is merged, as code hosts show it.
    package static let merged = dynamic(dark: 0xB48CFF, light: 0x8250DF)
    /// Text on an accent-filled button.
    package static let onAcc = dynamic(dark: 0x10112A, light: 0xFFFFFF)

    package static let mono = Font.system(size: 11.5, design: .monospaced)
    /// The small uppercase labels above groups ("AGENTS", "CONTEXT").
    package static let label = Font.system(size: 10.5, weight: .semibold)

    private static func dynamic(dark: UInt32, darkAlpha: CGFloat = 1, light: UInt32, lightAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    package static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// A small spinning ring in the accent colour, for "working".
package struct Spinner: View {
    var size: CGFloat

    package init(size: CGFloat = 10) { self.size = size }

    package var body: some View {
        SpinnerLayer()
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel("Working")
    }
}

/// The spinner's ring, turned by Core Animation. A SwiftUI animation that repeats for ever lays the window out again on
/// the main thread every frame, for every spinner on screen: with twenty conversations working, the sidebar's spinners
/// alone kept the main thread a third busy (#347). A layer's animation runs outside the app, and costs it nothing.
private struct SpinnerLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }
    func updateNSView(_ view: SpinnerView, context: Context) {}
}

private final class SpinnerView: NSView {
    private let turning = CALayer()
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

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

/// pi²'s buttons: filled accent for the main action, a quiet card for the rest, red text for the risky one.
package struct PiButtonStyle: ButtonStyle {
    package enum Kind { case primary, secondary, danger, ghost }
    var kind: Kind
    var compact: Bool
    @Environment(\.isEnabled) private var enabled

    package init(kind: Kind = .secondary, compact: Bool = false) {
        self.kind = kind
        self.compact = compact
    }

    package func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: kind == .primary ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, compact ? 8 : 11).padding(.vertical, compact ? 3 : 5)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(kind == .primary ? Color.clear : Theme.line2))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(.rect)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.onAcc
        case .danger: Theme.bad
        case .secondary: Theme.tx
        case .ghost: Theme.tx2
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: pressed ? Theme.acc.opacity(0.8) : Theme.acc
        case .ghost: pressed ? Theme.card2 : .clear
        default: pressed ? Theme.card : Theme.card2
        }
    }
}
