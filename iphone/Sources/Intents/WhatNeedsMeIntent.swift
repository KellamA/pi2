
import AppIntents
import Foundation
import PiModels
import SwiftUI

/// "What needs me in pi²": what waits for the person, in one project or all, as the Mac's menu bar item lists it
/// (`MenuBarNeedRow`: who asks, what, and where). It only reads: the list the engine's `needs` event keeps in the
/// session's client. Answering stays in pi², where the whole card shows before any answer (docs/iphone.md 4.2).
struct WhatNeedsMeIntent: AppIntent {
    static let title: LocalizedStringResource = "What Needs Me"
    static let description = IntentDescription(
        "Says what waits for you on your Mac: questions, decisions and approvals, in one project or all of them.",
        categoryName: "Projects"
    )
    /// Nothing runs on a locked phone (docs/iphone.md 4.5).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Project", description: "Only what waits in this project; everything when left out.")
    var project: IntentProject?

    static var parameterSummary: some ParameterSummary {
        Summary("What needs me in \(\.$project)")
    }

    init() {}

    init(project: IntentProject?) {
        self.project = project
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let registration = IntentSessions.current()
        try await IntentSessions.unlock(registration) { try await IntentRun.foreground(self, $0) }
        let session = registration.session
        let reach = await IntentSessions.reach(session)
        let reply: WhatNeedsMe.Reply
        if let words = IntentRun.words(for: reach, unreachable: IntentWords.unreachableNeeds) {
            reply = WhatNeedsMe.Reply(dialog: words)
        } else if let project {
            switch IntentRun.project(project, in: session, orLast: false) {
            case .project(let row): reply = WhatNeedsMe.list(session: session, project: row, reach: reach)
            case .none(let words): reply = WhatNeedsMe.Reply(dialog: words)
            case .ask: reply = WhatNeedsMe.list(session: session, project: nil, reach: reach)
            }
        } else {
            reply = WhatNeedsMe.list(session: session, project: nil, reach: reach)
        }
        return .result(dialog: IntentDialog("\(reply.dialog)"), view: NeedsSnippet(reply: reply))
    }
}

/// What "What needs me" says, from the session's list of what waits.
@MainActor
enum WhatNeedsMe {
    /// One thing that waits, as a line says it.
    struct Line: Equatable, Identifiable, Sendable {
        let id: String
        /// Who asks: the agent's name.
        let who: String
        /// What it asks, in one short line (`NeedItem.short`).
        let what: String
        /// Where it waits: "in Demo project · sub-chat “Fix login”".
        let place: String
        /// How Siri says it: "Beacon asks for approval: npm test."
        let spoken: String
    }

    struct Reply: Equatable, Sendable {
        var dialog: String
        var lines: [Line] = []
        /// More than the snippet shows.
        var more = 0
        /// Said when the list is what the Mac last sent, not what it says now.
        var asOf: String?
    }

    /// How many lines Siri reads, and the snippet shows.
    static let spoken = 3
    static let shown = 8

    static func list(session: AppSession, project: ProjectRow?, reach: IntentSessions.Reach) -> Reply {
        let projects = Dictionary(session.engine.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let needs = session.engine.needs
            .filter { need in project.map { need.projectId == $0.id } ?? true }
            .sorted { $0.createdAt < $1.createdAt }
        let lines = needs.map { need in
            // The project when the list is of all of them, then the conversation that asks, as the Mac's row says it.
            let named = project == nil ? need.projectId.flatMap { projects[$0] } : nil
            let place = [named, need.placeWords.isEmpty ? nil : need.placeWords].compactMap(\.self).joined(separator: " · ")
            let who = need.agentName ?? "Someone"
            return Line(id: need.id, who: who, what: need.short, place: place.isEmpty ? "" : "in \(place)", spoken: "\(who)\(asks(need.kind))\(sentence(need.short))")
        }
        let scope = project.map { " in \($0.name)" } ?? ""
        let stale = reach == .connected(outOfReach: true)
        var reply = Reply(dialog: "", lines: Array(lines.prefix(shown)), more: max(0, lines.count - shown))
        if stale { reply.asOf = "\(IntentWords.away(session)). This is what it last sent." }

        if lines.isEmpty {
            reply.dialog = stale ? "\(IntentWords.away(session)). When it was last heard from, nothing needed you\(scope)." : "Nothing needs you\(scope)."
            return reply
        }
        let count = lines.count == 1 ? "1 thing needs you\(scope)" : "\(lines.count) things need you\(scope)"
        let said = lines.prefix(spoken).map(\.spoken).joined(separator: " ")
        let rest = lines.count > spoken ? " And \(IntentWords.count(lines.count - spoken, "more", "more")) in pi²." : ""
        reply.dialog = (stale ? "\(IntentWords.away(session)). When it was last heard from, \(count)." : "\(count).") + " " + said + rest
        return reply
    }

    /// What comes between who asks and what, said aloud: an approval's line is a command or a call, not a question.
    private static func asks(_ kind: String) -> String {
        switch kind {
        case "approval": " asks for approval: "
        case "reach": " asks for more reach: "
        case "question", "decision": " asks: "
        // A proposed rule's and a held start's lines say what they are.
        default: ": "
        }
    }

    /// A line as a sentence, ending in a stop unless it ends in other punctuation.
    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".?!…".contains(last) ? trimmed : trimmed + "."
    }
}
