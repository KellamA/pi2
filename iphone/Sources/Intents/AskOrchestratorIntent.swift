
import AppIntents
import EngineKit
import Foundation
import PiModels
import SwiftUI

/// "Ask pi² to …": a message to a project's orchestrator, chosen or the last one used, and its answer spoken or shown
/// when it comes in time (docs/design/iphone.md, "What a phone adds"). If the Mac is asleep, the message waits in the
/// mailbox and the Shortcut says the answer will come later.
struct AskOrchestratorIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask an Orchestrator"
    static let description = IntentDescription(
        "Sends a message to a project’s orchestrator on your Mac and gives its answer. If your Mac is asleep, the message waits for it and the answer comes later, in pi².",
        categoryName: "Projects"
    )
    /// Nothing runs on a locked phone (docs/iphone.md 4.5).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "What do you want to ask?")
    var message: String

    @Parameter(title: "Project", description: "Whose orchestrator to ask; the last one asked when left out.", requestValueDialog: "Which project’s orchestrator?")
    var project: IntentProject?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$project)’s orchestrator \(\.$message)")
    }

    init() {}

    init(message: String, project: IntentProject?) {
        self.message = message
        self.project = project
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let registration = IntentSessions.current()
        try await IntentSessions.unlock(registration) { try await IntentRun.foreground(self, $0) }
        let session = registration.session
        let reach = await IntentSessions.reach(session)
        let reply: AskOrchestrator.Reply
        if let words = IntentRun.words(for: reach, unreachable: IntentWords.unreachableNotSent) {
            reply = AskOrchestrator.Reply(outcome: .notSent, dialog: words)
        } else {
            switch IntentRun.project(project, in: session, orLast: true) {
            case .ask:
                throw $project.needsValueError("Which project’s orchestrator?")
            case .none(let words):
                reply = AskOrchestrator.Reply(outcome: .notSent, dialog: words)
            case .project(let row):
                reply = await AskOrchestrator.ask(message, of: row, session: session, courier: IntentEngineCourier(session: session))
            }
        }
        return .result(dialog: IntentDialog("\(reply.dialog)"), view: AskSnippet(reply: reply))
    }
}

/// What "Ask pi²" does once it knows the project: the message sent as the Mac's Dashboard strip sends it, and the answer
/// read from the conversation as the Mac's Quick Ask reads it.
@MainActor
enum AskOrchestrator {
    struct Reply: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            /// The orchestrator answered in time.
            case answered
            /// The Mac took the message; the answer was not there in time.
            case stillWorking
            /// The message waits for the Mac in the Outbox.
            case kept
            /// Refused or not sent.
            case notSent
        }

        var outcome: Outcome
        var dialog: String
        var project: String?
        var message: String?
        var answer: String?
    }

    /// How long the intent waits for the answer before it says the answer will be in pi². Siri keeps an intent about
    /// half a minute; a test sets its own.
    static var answerWait: Duration = .seconds(20)
    /// How much of the answer Siri reads aloud; the snippet shows more, and pi² the whole.
    static let spokenLength = 600
    static let shownLength = 4_000

    static func ask(_ text: String, of project: ProjectRow, session: AppSession, courier: some IntentCourier) async -> Reply {
        let engine = session.engine
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var reply = Reply(outcome: .notSent, dialog: "", project: project.name, message: message)
        guard !message.isEmpty else {
            reply.dialog = "There was nothing to send."
            return reply
        }
        guard let id = project.conversation else {
            // The Mac's hub starts it as it opens (`projects.startFresh`).
            reply.dialog = "\(project.name)’s orchestrator hasn’t started yet. Open the project in pi² to start it, then ask again."
            return reply
        }

        // Opened first, so that the answer that follows the message can be told from what was there before.
        engine.openConversation(id)
        _ = await wait(until: .now + .seconds(5)) { engine.open[id]?.arrived == true }
        let before = engine.open[id]?.items.last?.id
        let busy = engine.conversations.first { $0.id == id }?.busy == true

        switch await courier.message(message, to: id, steer: busy) {
        case .taken:
            IntentRun.lastProject = project.id
        case .kept:
            IntentRun.lastProject = project.id
            reply.outcome = .kept
            reply.dialog = "\(IntentWords.away(session)), so your message to \(project.name)’s orchestrator waits in the mailbox and goes to it when your Mac wakes. The answer will come later, in pi²."
            return reply
        case .refused(let words):
            reply.dialog = "Not sent to \(project.name)’s orchestrator: \(words)"
            return reply
        case .unreachable(let words):
            reply.dialog = words
            return reply
        }

        let answered = await wait(until: .now + answerWait) { answer(in: engine.open[id], after: before) != nil }
        guard answered, let text = answer(in: engine.open[id], after: before) else {
            reply.outcome = .stillWorking
            reply.dialog = "Sent to \(project.name)’s orchestrator. It’s still working on the answer, which will be in pi²."
            return reply
        }
        reply.outcome = .answered
        reply.answer = String(text.prefix(shownLength))
        let spoken = text.count > spokenLength ? String(text.prefix(spokenLength)) + "… The whole answer is in pi²." : text
        reply.dialog = spoken
        return reply
    }

    /// The orchestrator's answer to the newest message after entry `before`, once it has finished: its last words in that
    /// turn, as Quick Ask shows them. Nil while it is still working, and before the message shows.
    static func answer(in conversation: OpenConversation<MessageField>?, after before: Int?) -> String? {
        guard let conversation, conversation.state?.busy == false else { return nil }
        let items = conversation.items.filter { item in before.map { item.id > $0 } ?? true }
        guard let sent = items.lastIndex(where: { $0.kind == "user" }) else { return nil }
        let answer = items[items.index(after: sent)...].last { $0.kind == "assistant" && !$0.text.isEmpty }
        return answer?.text
    }

    /// Waits for `condition`, polling, until `end`; whether it held.
    static func wait(until end: ContinuousClock.Instant, _ condition: () -> Bool) async -> Bool {
        while !condition() {
            if ContinuousClock.now >= end { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}
