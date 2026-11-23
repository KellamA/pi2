import EngineKit
import Foundation
import PiModels

/// The requests the conversations' screens send, each made as the Mac app makes it, through the same client
/// (`session.engine`), so that they work as they are the day a Mac answers them. Each answers nil (or the answer) once the
/// engine has taken the request, or the engine's own words when it refused it or could not be reached, for the screen to
/// say where it was asked. Nothing here answers for the engine.
///
/// What a phone may send of these is the engine's to decide (docs/iphone.md, 4.2): every one here is on the device's
/// list, `conversation.unarchive`, `conversation.delete`, `projects.unarchive` and `projects.restoreConversation`
/// (without `dryRun`) among the changes the Mac notifies the person of.
@MainActor
enum ConversationsRequests {
    typealias Engine = EngineSession<MessageField>

    /// Puts a conversation in the Archive, as the Mac's sidebar and chat mode do (`AppModel.archive`: `conversation.archive`).
    static func archive(_ engine: Engine, conversation: Int) async -> String? {
        await failure { try await engine.call("conversation.archive", ["id": conversation]) }
    }

    /// Renames a conversation, as the Mac's Rename does (`conversation.rename`).
    static func rename(_ engine: Engine, conversation: Int, title: String) async -> String? {
        await failure { try await engine.call("conversation.rename", ["id": conversation, "title": title]) }
    }

    /// Pins a chat at the top of the chats, or unpins it, as chat mode does (`EngineClient.pin`: `conversation.pin`).
    static func pin(_ engine: Engine, conversation: Int, pinned: Bool) async -> String? {
        await failure { try await engine.call("conversation.pin", ["id": conversation, "pinned": pinned]) }
    }

    /// Makes a chat, as chat mode's New Chat does (`EngineClient.createChat`: `conversation.create` with `chat`), and
    /// answers its id.
    static func newChat(_ engine: Engine) async -> Result<Int, ConversationsProblem> {
        do {
            let result = try await engine.call("conversation.create", ["chat": true])
            guard let id = result["id"]?.intValue else { return .failure(ConversationsProblem("Your Mac made the chat but did not say which it is.")) }
            return .success(id)
        } catch {
            return .failure(ConversationsProblem(error.localizedDescription))
        }
    }

    /// Puts an archived conversation back where it was, as the Mac's Archive's Restore does (`conversation.unarchive`).
    static func unarchive(_ engine: Engine, conversation: Int) async -> String? {
        await failure { try await engine.call("conversation.unarchive", ["id": conversation]) }
    }

    /// Deletes a conversation, as the Mac's Delete does once confirmed (`AppModel.confirmDelete`: `conversation.delete`).
    /// Its worktree, if pi² made one, is kept, as the Mac's "Delete, Keep Worktree" keeps it.
    static func delete(_ engine: Engine, conversation: Int) async -> String? {
        await failure { try await engine.call("conversation.delete", ["id": conversation]) }
    }

    /// Puts an archived project back in the list, as the Mac's Archive's Restore does (`AppModel.restoreProject`:
    /// `projects.unarchive`).
    static func unarchiveProject(_ engine: Engine, project: String) async -> String? {
        await failure { try await engine.call("projects.unarchive", ["id": project]) }
    }

    /// What restoring a conversation of a deleted project would do, as the Mac's Archive asks before it shows its sheet
    /// (`ArchiveView.showRestore`: `projects.restoreConversation` with `dryRun`).
    static func restorePlan(_ engine: Engine, conversation: Int) async -> Result<CarryOverReport, ConversationsProblem> {
        do {
            let report = try CarryOverReport(try await engine.call("projects.restoreConversation", ["id": conversation, "dryRun": true]))
            guard report.plan != nil else { return .failure(ConversationsProblem("This conversation is not of a deleted project.")) }
            return .success(report)
        } catch {
            return .failure(ConversationsProblem(error.localizedDescription))
        }
    }

    /// Restores it on the plan the person was shown (`ArchiveView.go`). If what it would do changed meanwhile, the engine
    /// refuses and sends the new report, which is answered as `.changed` to be shown again.
    static func restore(_ engine: Engine, conversation: Int, plan: String) async -> ConversationsRestoreOutcome {
        do {
            let result = try await engine.call("projects.restoreConversation", ["id": conversation, "plan": plan])
            return .restored(project: (try? CarryOverReport(result))?.projectId)
        } catch let refusal as EngineError {
            if let data = refusal.data, let changed = try? CarryOverReport(.object(data)) { return .changed(changed) }
            return .failed(refusal.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Sets after how many unused days a conversation is archived on its own, or never, as the Mac's Archive does
    /// (`settings.setAutoArchive`).
    static func setAutoArchive(_ engine: Engine, days: Int?) async -> String? {
        await failure { try await engine.call("settings.setAutoArchive", ["days": days.map { $0 as Any } ?? NSNull()]) }
    }

    /// Stops a background command and everything it started, as the Mac's output window and strip do (`background.stop`).
    static func stopCommand(_ engine: Engine, command: String) async -> String? {
        await failure { try await engine.call("background.stop", ["id": command]) }
    }

    /// A command's output from `from` on, as the Mac's output window asks for it (`BackgroundOutputFeed.follow`:
    /// `background.output`), the engine holding the request up to `wait` seconds until there is more or it ends.
    static func output(_ engine: Engine, command: String, from: Int, wait: Int) async throws -> BackgroundOutput {
        let result = try await engine.call("background.output", ["id": command, "from": from, "wait": wait])
        return try JSONDecoder().decode(BackgroundOutput.self, from: JSONEncoder().encode(result))
    }

    /// The folders the Mac offers for a new project (`projects.folders`, docs/iphone.md 4.2), since a phone cannot browse
    /// the Mac's disk. The Mac's own New Project chooses in a folder panel instead, which stays on the Mac.
    static func folders(_ engine: Engine) async -> Result<[NewProjectFolder], ConversationsProblem> {
        do {
            return .success(try NewProjectFolder.list(try await engine.call("projects.folders")))
        } catch let error as DecodingError {
            return .failure(ConversationsProblem("Your Mac's list of folders could not be read (\(error.localizedDescription))."))
        } catch {
            return .failure(ConversationsProblem(error.localizedDescription))
        }
    }

    /// Makes a project, with its orchestrator and an empty conversation with it, as the Mac's New Project does
    /// (`AppModel.newProject`: `projects.create`): in a folder the Mac offered, or none; named, or after its folder; its
    /// orchestrator a copy of a template, or of pi²'s default orchestrator. Answers the new project's id.
    static func createProject(_ engine: Engine, folder: String?, name: String?, template: String?) async -> Result<String, ConversationsProblem> {
        var params: [String: Any] = ["folder": folder.map { $0 as Any } ?? NSNull()]
        if let name { params["name"] = name }
        if let template { params["template"] = template }
        do {
            let result = try await engine.call("projects.create", params)
            guard let id = result["id"]?.stringValue else { return .failure(ConversationsProblem("Your Mac made the project but did not say which it is.")) }
            return .success(id)
        } catch {
            return .failure(ConversationsProblem(error.localizedDescription))
        }
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

/// What a request failed with, in the engine's own words, for a screen to say where it was asked.
struct ConversationsProblem: Error, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// How restoring a conversation of a deleted project went.
enum ConversationsRestoreOutcome: Equatable {
    /// Restored, into this project (nil when the engine did not say).
    case restored(project: String?)
    /// What it would do changed since the person looked: this is what it would do now.
    case changed(CarryOverReport)
    case failed(String)
}
