import AppKit
import PiStyle
import SwiftUI

// Shared with the indicator pill, which the window check draws too.
typealias Theme = PiStyle.Theme
typealias Spinner = PiStyle.Spinner
typealias PiButtonStyle = PiStyle.PiButtonStyle

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
