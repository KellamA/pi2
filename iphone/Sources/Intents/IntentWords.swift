
import Foundation

/// What the intents say, in one place, so that the three say the same thing of the same state (docs/design/iphone.md,
/// "What a phone adds": Shortcuts and Siri). Spoken by Siri as well as shown, so each is a whole sentence or two.
enum IntentWords {
    static let notPaired = "pi² isn’t paired with a Mac yet. Open pi² to pair it with your Mac, or to try it without one."
    static let unlock = "Open pi² and unlock it with Face ID to go on."
    static let stayedLocked = "pi² stayed locked, so nothing was sent. Open pi² with Face ID and try again."
    static let noProjects = "Your Mac has no projects in pi² yet."
    static let noProject = "That project isn’t on your Mac any more."

    /// The Mac cannot be reached and nothing on the phone stands in for it, so nothing was sent.
    static let unreachableNotSent = "Your Mac can’t be reached, so nothing was sent. Try again once your Mac is awake."
    static let unreachableNeeds = "Your Mac can’t be reached, so pi² can’t say what needs you now. Try again once your Mac is awake."

    /// The Mac out of reach, as the start of a sentence: "Your Mac has been out of reach since 23:10", or without the
    /// time when it is not known.
    static func away(_ lastSeen: Date?) -> String {
        guard let lastSeen else { return "Your Mac is asleep or out of reach" }
        let calendar = Calendar.current
        let time = lastSeen.formatted(date: .omitted, time: .shortened)
        let when = calendar.isDateInToday(lastSeen) ? time
            : calendar.isDateInYesterday(lastSeen) ? "yesterday at \(time)"
            : lastSeen.formatted(date: .abbreviated, time: .shortened)
        return "Your Mac has been asleep or out of reach since \(when)"
    }

    /// `away` for the session's connection.
    @MainActor
    static func away(_ session: AppSession) -> String {
        if case .outOfReach(let lastSeen) = session.connection { return away(lastSeen) }
        return away(nil)
    }

    /// "1 run", "3 runs".
    static func count(_ number: Int, _ one: String, _ many: String) -> String {
        number == 1 ? "1 \(one)" : "\(number) \(many)"
    }
}
