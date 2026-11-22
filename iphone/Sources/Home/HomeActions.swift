
import EngineKit
import Foundation
import Observation
import PiModels

/// What the projects list asks of the Mac's engine, each request made as the Mac app makes it, through the session's
/// client. What the engine refuses is kept in `failure`, which the list shows; nothing changes on the phone until the
/// engine says so in its events.
@MainActor
@Observable
final class HomeActions {
    /// A request the engine refused or could not be sent, as the person reads it.
    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    var failure: Failure?
    /// A new chat being made, so that New Chat is not sent twice.
    private(set) var makingChat = false

    /// Sends one request; a refusal becomes `failure`. True when the engine answered.
    @discardableResult
    func send(_ engine: EngineSession<MessageField>, _ method: String, _ params: [String: Any], failing title: String) async -> JSONValue? {
        do {
            return try await engine.call(method, params)
        } catch {
            failure = Failure(title: title, message: error.localizedDescription)
            return nil
        }
    }

    /// Stop the Orchestrator, from a project's menu: `abort` on its conversation (the Mac's `ProjectBlock` menu).
    func stopOrchestrator(of project: HomeProject, in engine: EngineSession<MessageField>) async {
        guard let conversation = project.conversation else { return }
        await send(engine, "abort", ["id": conversation], failing: String(localized: "The orchestrator was not stopped"))
    }

    /// Rename…: `projects.rename` with the new name, trimmed; nothing when it is empty or the same (`AppModel.finishRename`).
    func rename(_ project: HomeProject, to name: String, in engine: EngineSession<MessageField>) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != project.name else { return }
        await send(engine, "projects.rename", ["id": project.id, "name": name], failing: String(localized: "The project was not renamed"))
    }

    /// Archive: `projects.archive` (`AppModel.archiveProject`).
    func archive(_ project: HomeProject, in engine: EngineSession<MessageField>) async {
        await send(engine, "projects.archive", ["id": project.id], failing: String(localized: "The project was not archived"))
    }

    /// Pin or unpin a chat: `conversation.pin` (`EngineClient.pin`).
    func pin(_ chat: ConversationSummary, _ pinned: Bool, in engine: EngineSession<MessageField>) async {
        await send(engine, "conversation.pin", ["id": chat.id, "pinned": pinned],
                   failing: pinned ? String(localized: "The chat was not pinned") : String(localized: "The chat was not unpinned"))
    }

    /// Archive a chat: `conversation.archive` (`AppModel.archive`).
    func archive(_ chat: ConversationSummary, in engine: EngineSession<MessageField>) async {
        await send(engine, "conversation.archive", ["id": chat.id], failing: String(localized: "The chat was not archived"))
    }

    /// New Chat: the chat waiting to be written in if there is one, else `conversation.create` with `chat: true`
    /// (`AppModel.newChat`, `EngineClient.createChat`). The chat's id, to open, or nil when none was made.
    func newChat(in engine: EngineSession<MessageField>) async -> Int? {
        if let waiting = HomeLists.emptyChat(engine.conversations) { return waiting.id }
        guard !makingChat else { return nil }
        makingChat = true
        defer { makingChat = false }
        let result = await send(engine, "conversation.create", ["chat": true], failing: String(localized: "No chat was made"))
        return result?["id"]?.intValue
    }
}
