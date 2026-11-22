import EngineKit
import Foundation
import Observation
import PiModels

/// What one Work screen keeps while the person acts on it, in memory only (the phone's store is #692's): the changes on
/// their way, shown at once where their piece is until the engine answers; a start the project's limit held; notes on
/// their way; and the engine's words for the last refusal. Every change goes through `WorkRequests`, so nothing here
/// answers for the engine: a refused change puts the piece back as it was and says why.
@MainActor
@Observable
final class WorkDesk {
    /// Changes the engine has not answered yet, by piece.
    private(set) var pending: [Int: WorkChange] = [:]
    /// A note sent and not answered for yet, by the piece it is on.
    private(set) var sending: [Int: String] = [:]
    /// Writes of unknown outcome being settled, by intent.
    private(set) var settling: Set<String> = []
    /// A start the project's limit refused, to confirm or leave.
    var held: WorkHeldStart?
    /// What the engine answered to the last change it refused.
    var problem: String?

    /// Sends one action of the state table, shown at once as `change`; answers whether the engine took it.
    @discardableResult
    func act(_ engine: EngineSession<MessageField>, project: String, item: WorkItem, _ action: String,
             _ extra: [String: Any] = [:], change: WorkChange? = nil) async -> Bool {
        guard pending[item.id] == nil else { return false }
        pending[item.id] = change ?? WorkChange.of(action, as: extra["as"] as? String)
        defer { pending[item.id] = nil }
        let refused = await WorkRequests.act(engine, project: project, item: item.id, action, extra)
        problem = refused
        return refused == nil
    }

    /// Adds a note (or, on GitHub, a comment); answers the engine's refusal, for the field to take its words back.
    func note(_ engine: EngineSession<MessageField>, project: String, item: WorkItem, text: String) async -> String? {
        guard pending[item.id] == nil else { return "Wait for the change on its way." }
        sending[item.id] = text
        defer { sending[item.id] = nil }
        let taken = await act(engine, project: project, item: item, "note", ["text": text])
        return taken ? nil : problem
    }

    /// Gives a piece to an agent, shown at once as given; past the project's limit the engine holds it, for the person to
    /// confirm that one start (`confirming`) or leave it.
    func assign(_ engine: EngineSession<MessageField>, project: String, item: WorkItem, to agent: AgentProfile,
                confirming: WorkLimitReading? = nil) async {
        guard pending[item.id] == nil else { return }
        pending[item.id] = WorkChange(word: "Giving to \(agent.name)", state: "in_progress", holderAgentId: agent.id)
        defer { pending[item.id] = nil }
        switch await WorkRequests.assign(engine, project: project, item: item.id, agent: agent.id, confirming: confirming) {
        case .given:
            held = nil
            problem = nil
        case .held(let limit):
            held = WorkHeldStart(item: item, agent: agent, limit: limit)
        case .refused(let words):
            held = nil
            problem = words
        }
    }

    func settle(_ engine: EngineSession<MessageField>, project: String, write: WorkUnknownWrite, happened: Bool) async {
        guard !settling.contains(write.intent) else { return }
        settling.insert(write.intent)
        defer { settling.remove(write.intent) }
        problem = await WorkRequests.settle(engine, project: project, intent: write.intent, happened: happened)
    }
}
