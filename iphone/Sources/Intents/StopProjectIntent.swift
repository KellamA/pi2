
import AppIntents
import Foundation
import PiModels
import SwiftUI

/// "Stop pi² in <project>": every agent at work in the project stops where it is, sub-chats included, after a
/// confirmation that names how many runs, as the Mac's Stop All does for the projects it is given (`RunStopping`,
/// `StopAllConfirmation`). A chat answering is not an agent's work, and is left alone, as on the Mac.
struct StopProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop a Project"
    static let description = IntentDescription(
        "Stops every agent at work in a project on your Mac, and the commands they are running. Each conversation stays as it is and can be continued.",
        categoryName: "Projects"
    )
    /// Nothing runs on a locked phone (docs/iphone.md 4.5).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Project", requestValueDialog: "Which project should stop?")
    var project: IntentProject?

    static var parameterSummary: some ParameterSummary {
        Summary("Stop the agents in \(\.$project)")
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
        let reply: StopProject.Reply
        if let words = IntentRun.words(for: reach, unreachable: IntentWords.unreachableNotSent) {
            reply = StopProject.Reply(dialog: words)
        } else {
            switch IntentRun.project(project, in: session, orLast: false) {
            case .ask:
                throw $project.needsValueError("Which project should stop?")
            case .none(let words):
                reply = StopProject.Reply(dialog: words)
            case .project(let row):
                let runs = StopProject.runs(in: row, session: session)
                if !runs.isEmpty {
                    try await IntentRun.confirm(self, StopProject.question(runs, in: row, session: session))
                }
                reply = await StopProject.stop(runs, in: row, session: session, courier: EngineCourier(session: session))
            }
        }
        return .result(dialog: IntentDialog("\(reply.dialog)"), view: StopSnippet(reply: reply))
    }
}

/// What "Stop pi² in <project>" does once it knows the project.
@MainActor
enum StopProject {
    struct Reply: Equatable, Sendable {
        var dialog: String
        var project: String?
        /// How many runs the Mac took a stop for, how many wait for it in the Outbox, and how many were refused.
        var stopped = 0
        var kept = 0
        var refused = 0
    }

    /// The agents' runs in the project, ordered as the Mac stops them: those whose parent is not among them first, so
    /// that a conversation waiting on a sub-chat is stopped before the sub-chat, and does not go on with its turn when
    /// the sub-chat's result comes back (`RunStopping.stop`).
    static func runs(in project: ProjectRow, session: AppSession) -> [ActivityRun] {
        let runs = session.engine.activity.filter { $0.chat != true && $0.projectId == project.id }
        let ids = Set(runs.map(\.conversationId))
        let tops = runs.filter { run in run.parent.map { !ids.contains($0) } ?? true }
        let rest = runs.filter { run in run.parent.map(ids.contains) ?? false }
        return tops + rest
    }

    /// What the confirmation asks, in the Mac's words.
    static func question(_ runs: [ActivityRun], in project: ProjectRow, session: AppSession) -> String {
        let away = IntentSessions.outOfReach(session) ? " \(IntentWords.away(session)): the stop waits for it in the mailbox." : ""
        return "Stop \(IntentWords.count(runs.count, "run", "runs")) in \(project.name)? Every agent at work there stops where it is, sub-chats included, and so do the commands they are running. Each conversation stays as it is and can be continued.\(away)"
    }

    /// Stops each run with `abort`, the Mac's request, one after another in that order.
    static func stop(_ runs: [ActivityRun], in project: ProjectRow, session: AppSession, courier: some IntentCourier) async -> Reply {
        var reply = Reply(dialog: "", project: project.name)
        guard !runs.isEmpty else {
            reply.dialog = IntentSessions.outOfReach(session)
                ? "\(IntentWords.away(session)). When it was last heard from, nothing was running in \(project.name)."
                : "Nothing is running in \(project.name)."
            return reply
        }
        var problems: [String] = []
        for run in runs {
            switch await courier.request("abort", ["id": run.conversationId]) {
            case .taken: reply.stopped += 1
            case .kept: reply.kept += 1
            case .refused(let words), .unreachable(let words):
                reply.refused += 1
                if !problems.contains(words) { problems.append(words) }
            }
        }
        var said: [String] = []
        if reply.stopped > 0 {
            said.append(reply.stopped == runs.count
                ? "Stopped \(IntentWords.count(runs.count, "run", "runs")) in \(project.name). Each conversation stays as it is and can be continued."
                : "Stopped \(reply.stopped) of \(runs.count) runs in \(project.name).")
        }
        if reply.kept > 0 {
            said.append("\(IntentWords.away(session)), so the stop for \(IntentWords.count(reply.kept, "run", "runs")) waits in the mailbox and reaches it when it wakes.")
        }
        if reply.refused > 0 {
            let what = reply.refused == runs.count ? "Couldn’t stop the runs in \(project.name)" : "\(IntentWords.count(reply.refused, "run wasn’t", "runs weren’t")) stopped"
            said.append("\(what): \(problems.joined(separator: " "))")
        }
        reply.dialog = said.joined(separator: " ")
        return reply
    }
}
