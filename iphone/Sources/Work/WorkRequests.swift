import EngineKit
import Foundation
import PiModels

/// The requests the Work screens send, each made as the Mac app makes it (app/Sources/pi2/ProjectWorkTab.swift and
/// ProjectWorkGitHub.swift), through the same client, so that they work as they are the day a Mac answers them. Each
/// answers nil once the engine has taken the request, or the engine's own words when it refused it or could not be
/// reached, for the screen to say where it was asked. Nothing here answers for the engine.
///
/// Every one of them is a phone's to send in an open session (docs/iphone.md, 4.2): `work.create` and `work.act` without
/// `confirmLimit` are the person's ordinary acts, `work.act` with it an answer that widens, of which the Mac notifies
/// the person; `github.refresh` reads; `github.settle` with `happened: false` is a change the Mac notifies of. Only
/// `github.show` is not named by the table, and so is the Mac's until the table names it: the screen says so when it
/// is refused.
@MainActor
enum WorkRequests {
    /// Files a piece of work as the person (`ProjectWorkTab.addWork`: `work.create`); on a project with a repository
    /// attached, the engine files it as an issue there.
    static func create(_ engine: EngineSession<MessageField>, project: String, title: String, text: String) async -> String? {
        await failure { try await engine.call("work.create", ["projectId": project, "title": title, "text": text]) }
    }

    /// One action of the state table (docs/projects.md, 3.11) on a piece: `release`, `resume`, `classify` (with
    /// `class`), `close` (with `as`), `reopen`, `edit` (with `title` and `text`) or `note` (with `text`), as the Mac's
    /// buttons send it (`ProjectWorkTab.send`: `work.act`).
    static func act(_ engine: EngineSession<MessageField>, project: String, item: Int, _ action: String,
                    _ extra: [String: Any] = [:]) async -> String? {
        let params: [String: Any] = ["projectId": project, "id": item, "action": action].merging(extra) { _, new in new }
        return await failure { try await engine.call("work.act", params) }
    }

    /// How giving a piece to an agent went.
    enum Given: Equatable {
        /// The engine took it: the agent has it and starts.
        case given
        /// The project's limit refused the start, with its reading, for the person to confirm that one start (8.3).
        case held(WorkLimit)
        /// Refused, in the engine's words.
        case refused(String)
    }

    /// Gives a piece to an agent, which starts it: the engine claims it and starts a sub-chat of the orchestrator's
    /// conversation in one step (`ProjectWorkTab.assign`: `work.act` with `assign`). `confirming` is the person's word to
    /// go past the limit that refused it before.
    static func assign(_ engine: EngineSession<MessageField>, project: String, item: Int, agent: String,
                       confirming: WorkLimit? = nil) async -> Given {
        var params: [String: Any] = ["projectId": project, "id": item, "action": "assign", "agentId": agent]
        if let confirming { params["confirmLimit"] = confirming.id }
        do {
            _ = try await engine.call("work.act", params)
            return .given
        } catch let error as EngineError {
            if let limit = WorkLimit(error.data?["limit"]) { return .held(limit) }
            return .refused(error.localizedDescription)
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// Reads the repository again now (`ProjectWorkGitHub.refresh`: `github.refresh`).
    static func refresh(_ engine: EngineSession<MessageField>, project: String) async -> String? {
        await failure { try await engine.call("github.refresh", ["projectId": project]) }
    }

    /// Reads one issue whole into the listing (`ProjectWorkGitHub.fill`: `github.show`), when the list holds less of it
    /// than its screen shows.
    static func show(_ engine: EngineSession<MessageField>, project: String, number: Int) async -> String? {
        await failure { try await engine.call("github.show", ["projectId": project, "number": number]) }
    }

    /// The person's word on a write whose outcome pi² could not tell (`ProjectWorkGitHub.settle`: `github.settle`).
    static func settle(_ engine: EngineSession<MessageField>, project: String, intent: String, happened: Bool) async -> String? {
        await failure { try await engine.call("github.settle", ["projectId": project, "intent": intent, "happened": happened]) }
    }

    /// The engine's words when `request` fails, nil when it is answered.
    private static func failure(_ request: () async throws -> Void) async -> String? {
        do {
            try await request()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
