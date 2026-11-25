import Foundation
import PiModels

/// What the screen shows around the transcript, read from what the engine sent of the conversation: what the run is
/// doing, what was sent and waits, what waits for the person, and whether the conversation can be written to. The
/// lines and labels are the Mac's (`ChatView`), so that both say the same thing.
struct ConversationStatus: Equatable {
    /// A message on its way, or waiting in the conversation's queue: the outgoing and queued chips above the field.
    struct Chip: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Handed to the client, not yet taken by the engine; `macAway` while the engine is not connected.
            case sending(macAway: Bool)
            /// The engine has it; the conversation does not show it yet.
            case sent
            /// In the conversation's queue, to be read later; it can be taken back by its submission.
            case queued(submission: Int)
        }

        let id: String
        let kind: Kind
        /// What it waits for ("Queued until the answer"), or what is happening to it ("Sending").
        let label: String
        /// Its text, or what it carries.
        let summary: String
    }

    /// A line about the run: summarising, a provider's limit, a retry.
    struct Banner: Identifiable, Equatable {
        enum Tone: Equatable { case accent, warning }
        let id: String
        let text: String
        let symbol: String
        let tone: Tone
    }

    /// How the last run ended without an answer.
    struct Failure: Equatable {
        let message: String
        /// The person stopped it.
        let stopped: Bool
        /// Continue resumes it.
        let canContinue: Bool
    }

    /// Something waiting for the person in this conversation or its sub-chats, answered under Needs you.
    struct Waiting: Identifiable, Equatable {
        let id: String
        let text: String
    }

    enum Archived: Equatable {
        /// It is in the archive.
        case itself
        /// It is a sub-chat of this archived conversation.
        case parent(Int)
    }

    var agentName = "the agent"
    /// A chat with pi²'s own assistant: no agent to name, and a message sent while it answers waits for the answer.
    var isChat = false
    var busy = false
    /// A sub-chat: a message to it goes to the agent directly, and the orchestrator is told.
    var isSubChat = false
    var archived: Archived?
    var banners: [Banner] = []
    var failure: Failure?
    /// While it works: what a message sent now would wait for, steered or queued.
    var arrivalSteered: String?
    var arrivalQueued: String?
    var chips: [Chip] = []
    var waiting: [Waiting] = []
    /// The conversation's model, when it is known not to take pictures.
    var blindModel: String?

    /// The field's placeholder, as the Mac's.
    func placeholder(steer: Bool) -> String {
        if isChat { return busy ? "Write your next message…" : "Ask anything" }
        if busy { return steer ? "Steer \(agentName) while it works…" : "Queue a follow-up for \(agentName)…" }
        return isSubChat ? "Message \(agentName) directly…" : "Message \(agentName)…"
    }

    /// What the screen reads of the engine's view of the conversation.
    static func make(
        conversationID: Int, state: ConversationState?, agentName: String?, outgoing: [OutgoingMessage], connected: Bool,
        inbox: [InboxItem], needs: [TranscriptFeed.Need], archivedInLibrary: Bool, models: [ModelInfo], chat: Bool = false
    ) -> ConversationStatus {
        var status = ConversationStatus()
        status.isChat = chat || state?.chat == true
        let name = agentName ?? (status.isChat ? "pi²’s assistant" : "the agent")
        status.agentName = name
        status.busy = state?.busy ?? false
        status.isSubChat = state?.agent.parent != nil

        if archivedInLibrary {
            status.archived = .itself
        } else if state?.archived == true {
            status.archived = state?.agent.parent.map { .parent($0) } ?? .itself
        }

        if state?.compacting == true {
            status.banners.append(Banner(id: "compacting", text: "Summarising earlier messages to free up context…", symbol: "arrow.down.right.and.arrow.up.left", tone: .accent))
        }
        if let error = state?.compactionError, state?.compacting != true {
            status.banners.append(Banner(id: "compaction-error", text: error, symbol: "exclamationmark.triangle", tone: .warning))
        }
        if let wait = state?.limitWait {
            status.banners.append(Banner(id: "limit", text: wait.sentence, symbol: "hourglass", tone: .warning))
        } else if let retry = state?.retry {
            let text = retry.closed == true ? "The provider closed the connection. Trying again…"
                : retry.network == true ? "No network just now. Trying again…"
                : "The request failed and will be retried: \(retry.error)"
            status.banners.append(Banner(id: "retry", text: text, symbol: "arrow.clockwise", tone: .warning))
        }

        if let failure = state?.failure, !status.busy {
            status.failure = Failure(
                message: failure.message, stopped: failure.reason == "aborted",
                canContinue: failure.reason != "nothing_to_answer" && status.archived == nil
            )
        }

        // A chat's message always waits for the answer, which the Mac does not say either.
        if status.busy, !status.isChat, let waits = state?.messageWaits {
            let agent = agentName ?? "The agent"
            status.arrivalSteered = waits.sentence(agent: agent, steer: true, limit: state?.limitWait)
            status.arrivalQueued = waits.sentence(agent: agent, steer: false, limit: state?.limitWait)
        }

        for message in outgoing {
            let kind: Chip.Kind = message.submission == nil ? .sending(macAway: !connected) : .sent
            let label = message.submission != nil ? "Sent" : connected ? "Sending" : "Sending when your Mac is back"
            status.chips.append(Chip(id: "out-\(message.id)", kind: kind, label: label, summary: message.summary))
        }
        for item in state?.queued ?? [] {
            status.chips.append(Chip(id: "queued-\(item.id)", kind: .queued(submission: item.id), label: queuedLabel(item, state: state), summary: summary(of: item)))
        }

        for item in inbox where item.rootConversationId == conversationID {
            let who = item.agentName ?? name
            let what = item.kind == "approval" ? "\(who) needs approval: \(item.title)" : "\(who) asks: \(item.question ?? item.title)"
            status.waiting.append(Waiting(id: "inbox-\(item.id)", text: what))
        }
        for need in needs where need.conversationId == conversationID {
            let who = need.agentName ?? name
            let what = need.kind == "rule" ? "\(who) proposes a rule" : "\(who) asks for more reach"
            status.waiting.append(Waiting(id: "need-\(need.id)", text: need.change.map { "\(what): \($0.summary)" } ?? what))
        }

        if let ref = state?.agent.model, let model = models.first(where: { $0.ref == ref }), model.vision == false {
            status.blindModel = model.name
        }
        return status
    }

    /// What a queued message waits for, on its chip (the Mac's `queuedLabel`).
    static func queuedLabel(_ item: QueuedInput, state: ConversationState?) -> String {
        guard item.mode == "steer" else { return "Queued until the answer" }
        if let limit = state?.limitWait { return "After \(limit.provider)’s \(limit.kind == "overloaded" ? "overload" : "limit"), \(limit.untilText)" }
        return state?.messageWaits?.waitingFor.map { "After \($0)" } ?? "Steering"
    }

    /// One line for a queued message: what was typed, or what it carries.
    static func summary(of item: QueuedInput) -> String {
        let carried = item.attachments ?? []
        if carried.isEmpty { return item.text }
        let names = carried.count == 1 ? carried[0].name : "\(carried.count) attachments"
        return item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? names : "\(item.text) · \(names)"
    }
}
