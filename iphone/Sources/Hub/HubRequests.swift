import EngineKit
import Foundation
import PiModels

/// The requests a project's hub and the Dashboard's pages send, each made as the Mac app makes it, through the same
/// client (`session.engine`), so that they work as they are the day a Mac answers them. Each answers nil once the engine
/// has taken the request, or the engine's own words when it refused it or could not be reached, for the screen to say
/// where it was asked. Nothing here answers for the engine.
@MainActor
enum HubRequests {
    /// The project's switch for reports waking the orchestrator (docs/projects.md, 3.10), as the Mac's Now tab sets it
    /// (`ProjectNowTab.wakeBinding`: `projects.set`).
    static func setWake(_ engine: EngineSession<MessageField>, project: String, on: Bool) async -> String? {
        await failure { try await engine.call("projects.set", ["id": project, "settings": ["wakeOnReports": on]]) }
    }

    /// Stops a run where it is, and the command it is running, as the Mac's working row's Stop does (`WorkingRow.stop`:
    /// `abort`). Its conversation stays as it is and can be continued.
    static func stop(_ engine: EngineSession<MessageField>, conversation: Int) async -> String? {
        await failure { try await engine.call("abort", ["id": conversation]) }
    }

    /// Makes the conversation with the orchestrator of a project that has none yet, as the Mac's hub does as it opens
    /// (`ProjectHubs.startConversation`: `projects.startFresh`). The `projects` event then names it.
    static func startConversation(_ engine: EngineSession<MessageField>, project: String) async -> String? {
        await failure { try await engine.call("projects.startFresh", ["id": project]) }
    }

    /// Sends the project's orchestrator a message, as the Mac's strip under a Dashboard column does (`HubStrip.send`):
    /// steered into the answer it is writing, if it is writing one, else queued.
    static func message(_ engine: EngineSession<MessageField>, _ text: String, to project: ProjectRow) async -> String? {
        guard let id = project.conversation else { return "The conversation with the orchestrator has not started yet." }
        let busy = engine.conversations.first { $0.id == id }?.busy == true
        switch await engine.submit(text, to: id, steer: busy) {
        case .sent: return nil
        case .refused, .unconfirmed: return engine.lastError ?? "The message was not sent."
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

/// What the phone has told the engine it shows of a project, through `projects.watch` (docs/projects.md, 4.2, 10.3), as
/// the Mac's `ProjectTabWatch` does: while a hub's Now tab shows, the engine reads the project's GitHub listing again.
/// The engine keeps one watch for each connection, so every send names the project last shown and all of its tabs on
/// screen; a tab that goes tells the engine what is left. The Work tab (#694) says so through the same `shows` and
/// `hides` when it is built. A refusal changes nothing on screen: the watch only keeps a listing fresh.
@MainActor
final class HubTabWatch {
    static let shared = HubTabWatch()

    private var shown: [String: Set<HubTab>] = [:]
    private var order: [String] = []
    /// The last send, so that the requests reach the engine in the order they were made.
    private var sending: Task<Void, Never>?

    func shows(_ project: String, tab: HubTab, engine: EngineSession<MessageField>) {
        var tabs = shown[project] ?? []
        guard !tabs.contains(tab) else { return }
        tabs.insert(tab)
        shown[project] = tabs
        order.removeAll { $0 == project }
        order.append(project)
        send(engine)
    }

    func hides(_ project: String, tab: HubTab, engine: EngineSession<MessageField>) {
        guard var tabs = shown[project], tabs.contains(tab) else { return }
        tabs.remove(tab)
        shown[project] = tabs
        send(engine)
    }

    /// What the next `projects.watch` says: the newest project that still has a tab on screen, with every tab of it that
    /// does, or none.
    var parameters: [String: Any] {
        if let project = order.last(where: { !(shown[$0] ?? []).isEmpty }) {
            return ["projectId": project, "tabs": (shown[project] ?? []).map(\.rawValue).sorted()]
        }
        return ["projectId": NSNull(), "tabs": [String]()]
    }

    private func send(_ engine: EngineSession<MessageField>) {
        let params = parameters
        let before = sending
        sending = Task {
            _ = await before?.value
            _ = try? await engine.call("projects.watch", params)
        }
    }
}
