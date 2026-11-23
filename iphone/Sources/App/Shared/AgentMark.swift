import PiModels
import SwiftUI

/// The agents' colours by name, the Mac's soft pastels (`AgentColor` in app/Sources/pi2/AgentViews.swift), which take
/// dark lettering and read the same in light and dark. An agent's `color` is one of these names, or nil for violet.
enum AgentColor {
    static let names = ["violet", "blue", "teal", "green", "yellow", "orange", "pink", "gray"]

    static func color(_ name: String?) -> Color {
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
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// The lettering on a mark: dark in both appearances, as on the Mac.
    static let lettering = Color(red: 0x15 / 255, green: 0x16 / 255, blue: 0x1C / 255)
}

/// An agent's mark, or a project's (its orchestrator's colour): the first letter of its name on its colour, in the
/// rounded square the Mac's avatars draw (`AgentAvatar`). Any screen that names an agent uses this one, so that an agent
/// looks the same in the list, the hub, a card and a conversation. It grows with the text up to `maximum`, since at the
/// largest sizes the words beside it need the row's width more. Decoration: the row beside it says the name.
struct AgentMark: View {
    let name: String?
    let color: String?
    let maximum: CGFloat
    @ScaledMetric private var scaled: CGFloat

    /// `size` is its side at the default text size, scaled with `relativeTo`, and never more than `maximum` (by default
    /// one and a half times `size`).
    init(name: String?, color: String?, size: CGFloat = 28, maximum: CGFloat? = nil, relativeTo style: Font.TextStyle = .body) {
        self.name = name
        self.color = color
        self.maximum = maximum ?? size * 1.5
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: style)
    }

    /// An agent's mark, from its profile; a question mark on violet when the agent is not known.
    init(agent: AgentProfile?, size: CGFloat = 28, maximum: CGFloat? = nil, relativeTo style: Font.TextStyle = .body) {
        self.init(name: agent?.name, color: agent?.color, size: size, maximum: maximum, relativeTo: style)
    }

    var body: some View {
        let side = min(scaled, maximum)
        RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
            .fill(AgentColor.color(color))
            .frame(width: side, height: side)
            .overlay {
                Text(String((name ?? "").prefix(1)).uppercased().ifEmpty("?"))
                    .font(.system(size: side * 0.48, weight: .bold, design: .rounded))
                    .foregroundStyle(AgentColor.lettering)
            }
            .accessibilityHidden(true)
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
