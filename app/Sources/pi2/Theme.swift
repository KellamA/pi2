import AppKit
import SwiftUI

/// pi²'s look: the palette from the mockups, plus the small pieces (tags, buttons, cards) every screen is built from.
/// Colours are dynamic, so the same names work in dark (the default) and light appearance.
enum Theme {
    static let window = dynamic(dark: 0x17181C, light: 0xF7F7FA)
    static let side = dynamic(dark: 0x1D1E23, light: 0xEDEDF2)
    static let panel = dynamic(dark: 0x1F2026, light: 0xFFFFFF)
    static let card = dynamic(dark: 0x24262D, light: 0xF1F1F6)
    static let card2 = dynamic(dark: 0x2A2C34, light: 0xE8E8F0)
    static let line = dynamic(dark: 0xFFFFFF, darkAlpha: 0.08, light: 0x000000, lightAlpha: 0.08)
    static let line2 = dynamic(dark: 0xFFFFFF, darkAlpha: 0.14, light: 0x000000, lightAlpha: 0.14)
    static let tx = dynamic(dark: 0xECECF1, light: 0x1B1C22)
    static let tx2 = dynamic(dark: 0xA3A5B0, light: 0x5D5F6C)
    static let tx3 = dynamic(dark: 0x6E7080, light: 0x8C8E9B)

    /// Lavender in the dark, a deeper violet in the light so text on it stays readable.
    static let acc = dynamic(dark: 0x8B93FF, light: 0x5B62E8)
    static let ok = dynamic(dark: 0x4CC38A, light: 0x1D9A60)
    static let warn = dynamic(dark: 0xF0B24A, light: 0xB87507)
    static let bad = dynamic(dark: 0xF2647A, light: 0xD3384F)
    /// A branch with commits of its own not yet pushed or merged.
    static let ahead = dynamic(dark: 0x5BA8FF, light: 0x1F6FDB)
    /// A branch whose work is merged, as code hosts show it.
    static let merged = dynamic(dark: 0xB48CFF, light: 0x8250DF)
    /// Text on an accent-filled button.
    static let onAcc = dynamic(dark: 0x10112A, light: 0xFFFFFF)

    static let mono = Font.system(size: 11.5, design: .monospaced)
    /// The small uppercase labels above groups ("AGENTS", "CONTEXT").
    static let label = Font.system(size: 10.5, weight: .semibold)

    private static func dynamic(dark: UInt32, darkAlpha: CGFloat = 1, light: UInt32, lightAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    static let piAccent = Theme.acc
}

// MARK: - Appearance

/// Dark is pi²'s own look; light and following the system are there for those who want them.
enum AppAppearance: String, CaseIterable, Identifiable {
    case dark, light, system
    static let key = "appearance"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Match System"
        }
    }

    static var current: AppAppearance { AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dark }

    @MainActor
    static func apply(_ value: AppAppearance = current) {
        NSApp.appearance = switch value {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }
}

// MARK: - Pieces

/// A small tinted label: a tool's name, a status, a count.
struct Tag: View {
    enum Tone { case neutral, acc, ok, warn, bad, ahead, merged }
    let text: String
    var tone: Tone = .neutral

    init(_ text: String, _ tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    private var color: Color {
        switch tone {
        case .neutral: Theme.tx2
        case .acc: Theme.acc
        case .ok: Theme.ok
        case .warn: Theme.warn
        case .bad: Theme.bad
        case .ahead: Theme.ahead
        case .merged: Theme.merged
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .foregroundStyle(color)
            .background(tone == .neutral ? Theme.card2 : color.opacity(0.14), in: .rect(cornerRadius: 5))
    }
}

/// A status dot.
struct Dot: View {
    var color: Color = Theme.tx3
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// A small spinning ring in the accent colour, for "working".
struct Spinner: View {
    var size: CGFloat = 10

    var body: some View {
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

/// Three dots that breathe while the model has not said anything yet.
struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (sin((t * 4) - Double(index) * 0.7) + 1) / 2
                    Circle()
                        .fill(Theme.acc)
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * phase)
                        .scaleEffect(0.75 + 0.25 * phase)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityLabel("Working")
    }
}

/// The blinking block at the end of text that is still arriving.
struct Caret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.acc)
                .frame(width: 7, height: 14)
                .opacity(on ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}

/// pi²'s buttons: filled accent for the main action, a quiet card for the rest, red text for the risky one.
struct PiButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, ghost }
    var kind: Kind = .secondary
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
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

extension ButtonStyle where Self == PiButtonStyle {
    static var piPrimary: PiButtonStyle { PiButtonStyle(kind: .primary) }
    static var piSecondary: PiButtonStyle { PiButtonStyle(kind: .secondary) }
    static var piDanger: PiButtonStyle { PiButtonStyle(kind: .danger) }
    static var piGhost: PiButtonStyle { PiButtonStyle(kind: .ghost) }
}

/// A rounded panel with a hairline border: the container for cards, tiles and lists.
struct Panel: ViewModifier {
    var radius: CGFloat = 10
    var fill: Color = Theme.panel
    var border: Color = Theme.line

    func body(content: Content) -> some View {
        content
            .background(fill, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border))
    }
}

extension View {
    func panel(radius: CGFloat = 10, fill: Color = Theme.panel, border: Color = Theme.line) -> some View {
        modifier(Panel(radius: radius, fill: fill, border: border))
    }

    /// The small uppercase heading style used above groups.
    func sectionLabel() -> some View {
        font(Theme.label).textCase(.uppercase).tracking(0.6).foregroundStyle(Theme.tx3)
    }
}

extension Text {
    /// The explanation under a group of settings: left-aligned, wrapping, the full width of the group.
    func formFooter() -> some View {
        multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The pi² mark, drawn in type so it scales: a large π with a small ² in the accent gradient.
struct PiMark: View {
    var size: CGFloat = 56

    var body: some View {
        HStack(alignment: .top, spacing: size * 0.02) {
            Text("π").font(.system(size: size, weight: .semibold, design: .serif))
            Text("2").font(.system(size: size * 0.42, weight: .bold, design: .rounded)).offset(y: size * 0.1)
        }
        .foregroundStyle(LinearGradient(colors: [Theme.acc, Color(nsColor: Theme.rgb(0x7FD8C4))], startPoint: .topLeading, endPoint: .bottomTrailing))
        .accessibilityLabel("pi squared")
    }
}
