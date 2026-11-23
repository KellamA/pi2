
import AppIntents
import Foundation
import PiModels

/// What every intent does before its own part: the session, Face ID's session, the Mac reached, and the project named.
@MainActor
enum IntentRun {
    /// Which project an intent is about.
    enum Choice {
        case project(ProjectRow)
        /// None was named and more than one could be meant: Shortcuts and Siri ask.
        case ask
        /// None can be: what the person reads.
        case none(String)
    }

    /// The project last asked about by name in this run of the app, which "Ask pi²" uses when none is named
    /// (docs/design/iphone.md: "chosen, or the last one used"). In memory only until the phone's store (#692) keeps it.
    static var lastProject: String?

    /// The project `chosen` names, the last one used when it names none, or the only one there is.
    static func project(_ chosen: IntentProject?, in session: AppSession, orLast: Bool) -> Choice {
        let projects = IntentProject.all(in: session)
        if let chosen {
            guard let row = projects.first(where: { $0.id == chosen.id }) else { return .none(IntentWords.noProject) }
            return .project(row)
        }
        if orLast, let last = lastProject, let row = projects.first(where: { $0.id == last }) { return .project(row) }
        switch projects.count {
        case 0: return .none(IntentWords.noProjects)
        case 1: return .project(projects[0])
        default: return .ask
        }
    }

    /// Opens pi² in the foreground for Face ID, from an intent that may continue there (iOS 26 and later); before then
    /// it can only say so.
    static func foreground(_ intent: some AppIntent, _ why: String) async throws {
        if #available(iOS 26.0, *) {
            try await intent.continueInForeground(IntentDialog("\(why)"), alwaysConfirm: false)
        } else {
            throw IntentRefusal(why)
        }
    }

    /// Asks the person to confirm, through the system, or a test's stand-in.
    static func confirm(_ intent: some AppIntent, _ question: String) async throws {
        if let confirm = IntentSessions.prompts?.confirm {
            try await confirm(question)
        } else {
            try await intent.requestConfirmation(actionName: .continue, dialog: IntentDialog("\(question)"))
        }
    }

    /// The Mac's state as a sentence, for the outcomes every intent shares; nil once the engine answers.
    static func words(for reach: IntentSessions.Reach, unreachable: String) -> String? {
        switch reach {
        case .notPaired: IntentWords.notPaired
        case .unreachable: unreachable
        case .connected: nil
        }
    }
}
