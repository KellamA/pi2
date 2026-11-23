import PiModels
import SwiftUI
import WidgetKit

/// The three widgets (docs/design/iphone.md, "What a phone adds"), each in every family: the Home Screen's three sizes,
/// StandBy (which draws the small one, larger and without its background), and the Lock Screen's three.
enum WidgetsKind: String, CaseIterable, Sendable {
    case needs, working, spending

    var kind: String { "dev.pi2.ios.widgets.\(rawValue)" }

    var name: String {
        switch self {
        case .needs: "Needs you"
        case .working: "Who is working"
        case .spending: "Today's spending"
        }
    }

    var summary: String {
        switch self {
        case .needs: "How many things wait for you, and who asks."
        case .working: "Which agents are at work, and in which project."
        case .spending: "What today has cost, against your plan's windows."
        }
    }

    var symbol: String {
        switch self {
        case .needs: "exclamationmark.bubble.fill"
        case .working: "person.2.fill"
        case .spending: "gauge.with.dots.needle.50percent"
        }
    }

    /// Where a tap on the widget outside its rows opens the app.
    var link: WidgetsLink {
        switch self {
        case .needs: .needs()
        case .working: .dashboard()
        case .spending: .usage
        }
    }

    static let families: [WidgetFamily] = [
        .systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline,
    ]
}

/// When a widget's content is marked `privacySensitive` (docs/iphone.md 4.5): on the Lock Screen, which draws the
/// accessory families, and in StandBy, which draws the small one without its background, so that a phone left locked on
/// a desk or a stand shows the shape of the widget and none of its words. On the Home Screen the phone is unlocked.
enum WidgetsPrivacy {
    static func isPrivate(_ family: WidgetFamily, showsBackground: Bool) -> Bool {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: true
        default: !showsBackground
        }
    }
}

extension EnvironmentValues {
    /// Whether the widget's words and numbers are marked `privacySensitive` where it is drawn (`WidgetsPrivacy`).
    @Entry var widgetsArePrivate = false
}

/// Marks what the Mac sent, names and numbers, as private where the widget is drawn so.
struct WidgetsPrivate: ViewModifier {
    @Environment(\.widgetsArePrivate) private var isPrivate

    func body(content: Content) -> some View {
        content.privacySensitive(isPrivate)
    }
}

extension View {
    func widgetsPrivate() -> some View { modifier(WidgetsPrivate()) }
}

/// The widgets' colours: pi²'s accent and the agents' pastels, as `App/Shared/` has them for the app (`Color.pi2Accent`,
/// `AgentColor`), which the extension cannot reach.
enum WidgetsColor {
    static let accent = Color(uiColor: UIColor { traits in
        rgb(traits.userInterfaceStyle == .dark ? 0x8B93FF : 0x5B62E8)
    })

    /// A widget's background on the Home Screen.
    static let background = Color(uiColor: .secondarySystemGroupedBackground)

    static func agent(_ name: String?) -> Color {
        let hex: UInt32 = switch name {
        case "blue": 0x9FC5FF
        case "teal": 0x7FD8C4
        case "green": 0xA8E39A
        case "yellow": 0xF5D77A
        case "orange": 0xFFB37A
        case "pink": 0xFFA8C8
        case "gray": 0xC3C5D0
        default: 0xB9A6FF
        }
        return Color(uiColor: rgb(hex))
    }

    static let lettering = Color(uiColor: rgb(0x15161C))

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// An agent's mark, as the app draws it (`AgentMark`): its first letter on its colour. Decoration: its name is beside it.
struct WidgetsMark: View {
    let name: String?
    let color: String?
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(WidgetsColor.agent(color))
            .frame(width: size, height: size)
            .overlay {
                Text(name?.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetsColor.lettering)
            }
            .accessibilityHidden(true)
    }
}

/// A widget's title line: its symbol and name, in the accent.
struct WidgetsHeader: View {
    let kind: WidgetsKind
    var title: String?

    var body: some View {
        Label(title ?? kind.name, systemImage: kind.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(WidgetsColor.accent)
            .labelStyle(WidgetsHeaderLabel())
            .lineLimit(1)
            .widgetAccentable()
    }
}

private struct WidgetsHeaderLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// When the Mac's state the widget draws was last heard: the widget is not live, and says how old it is.
struct WidgetsUpdated: View {
    let heardAt: Date
    var now = Date()

    var body: some View {
        Text("Updated \(Self.words(heardAt, now: now))")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// "14:02" today, "Mon 14:02" within a week, else the date.
    static func words(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if now.timeIntervalSince(date) < 6 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// A big number: a count, or an amount.
struct WidgetsFigure: View {
    let text: String
    var size: Font = .system(size: 40, weight: .semibold, design: .rounded)

    var body: some View {
        Text(text)
            .font(size)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .widgetsPrivate()
    }
}

/// What a widget draws with no snapshot: no Mac paired, nothing written yet, a build with no app group, or a snapshot
/// too old to draw. It says what to do, and shows nothing the Mac did not send.
struct WidgetsNothingYet: View {
    let kind: WidgetsKind
    let family: WidgetFamily

    private var words: String {
        switch kind {
        case .needs: "Open pi² to show what needs you here."
        case .working: "Open pi² to show who is working here."
        case .spending: "Open pi² to show today's spending here."
        }
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: kind.symbol).font(.title3)
            }
            .accessibilityLabel(words)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("pi²", systemImage: kind.symbol).font(.headline).widgetAccentable()
                Text(words).font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label("Open pi²", systemImage: kind.symbol)
        default:
            VStack(alignment: .leading, spacing: 6) {
                WidgetsHeader(kind: kind)
                Spacer(minLength: 0)
                Text(words)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// A widget, whatever its kind and family: the extension's entry view draws this, and the tests draw it to pictures.
struct WidgetsView: View {
    let kind: WidgetsKind
    let snapshot: WidgetsSnapshot?
    let family: WidgetFamily

    var body: some View {
        Group {
            if let snapshot {
                switch kind {
                case .needs: WidgetsNeedsView(snapshot: snapshot, family: family)
                case .working: WidgetsWorkingView(snapshot: snapshot, family: family)
                case .spending:
                    if let spending = snapshot.spending {
                        WidgetsSpendingView(spending: spending, heardAt: snapshot.heardAt, family: family)
                    } else {
                        WidgetsNothingYet(kind: kind, family: family)
                    }
                }
            } else {
                WidgetsNothingYet(kind: kind, family: family)
            }
        }
        // A widget is a few lines in a fixed box: past this size its words would not fit at all.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
