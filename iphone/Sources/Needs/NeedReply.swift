import EngineKit
import Foundation
import PiModels

/// One answer to a card, as the request the Mac app makes for the same button: the same method and the same parameters,
/// so that it is the engine, never the phone, that decides what an answer does (docs/iphone.md 4.2; docs/projects.md 3.9).
///
/// Where each comes from on the Mac (`app/Sources/pi2`):
/// - `decide`: `InboxCard.decide` (`InboxViews.swift`), `inbox.decide { id, decision }`, for an approval the Inbox holds.
/// - `answerInbox`: `InboxCard.send`, `inbox.answer { id, text }`, for a question an agent waits on (`ask_user`).
/// - every other: `NeedCard.answer` (`ProjectNowTab.swift`) and `RuleProposalCard.answer` (`ProjectRulesTab.swift`),
///   `needs.answer { id, answer }` with the contract's `NeedAnswer`.
enum NeedReply: Equatable, Sendable {
    /// What an approval's buttons send: `once`, `always`, `rule` or `deny`.
    enum Decision: String, Sendable {
        case once, always, rule, deny
    }

    /// An approval the Inbox holds, answered as the Inbox's card answers it.
    case decide(Decision)
    /// An approval a project's switch asked for (projects.md 8.1): Allow once or Deny alone.
    case switchApproval(Decision)
    /// A question an agent is held on (`ask_user`), answered as the Inbox's card answers it.
    case answerInbox(String)
    /// A question put with `needs_you`.
    case question(String)
    /// One of a decision's choices, by its id.
    case choice(String)
    /// A decision answered in the person's own words.
    case decisionWords(String)
    /// More reach: Allow or Refuse.
    case reach(allow: Bool)
    /// A proposed rule refused.
    case refuseRule
    /// A proposed rule accepted, as it is or with its text and whom it binds changed.
    case acceptRule(text: String? = nil, binds: ProjectRule.Binds? = nil)
    /// A start the project's limit held back: Start anyway, or Leave it.
    case limit(start: Bool)

    /// The request the Mac makes for this answer to need `id`: its method and parameters.
    func request(for id: String) -> (method: String, params: [String: Any]) {
        switch self {
        case .decide(let decision):
            return ("inbox.decide", ["id": id, "decision": decision.rawValue])
        case .answerInbox(let text):
            return ("inbox.answer", ["id": id, "text": text])
        default:
            return ("needs.answer", ["id": id, "answer": answer])
        }
    }

    /// The contract's `NeedAnswer` for a `needs.answer`.
    private var answer: [String: Any] {
        switch self {
        case .decide(let decision), .switchApproval(let decision):
            ["kind": "approval", "decision": decision.rawValue]
        case .answerInbox(let text), .question(let text):
            ["kind": "question", "text": text]
        case .choice(let id):
            ["kind": "decision", "choice": id]
        case .decisionWords(let text):
            ["kind": "decision", "text": text]
        case .reach(let allow):
            ["kind": "reach", "allow": allow]
        case .refuseRule:
            ["kind": "rule", "accept": false]
        case .acceptRule(let text, let binds):
            ["kind": "rule", "accept": true].merging(
                [("text", text as Any?), ("binds", binds?.rawValue as Any?)].compactMap { key, value in value.map { (key, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
        case .limit(let start):
            ["kind": "limit", "start": start]
        }
    }
}

/// Sends a card's answer through the session's client, as the Mac's card sends it, and gives back the engine's refusal in
/// the words it was given. This is the one place every answer leaves the phone, so it is where the phone's own handling
/// of an answer attaches as it is built:
///
/// - **The presence signature** (docs/iphone.md 4.3) is not added here on a live channel: the channel was attached, and is
///   resumed, under signatures by the presence key, and the engine holds every request of the session to them. It is
///   added per answer only to a sealed item for the relay's mailbox, which the Outbox (#692) and notification actions
///   (#691) write while the Mac is out of reach; such an item is made from this same `request(for:)`.
/// - Until the channel exists (the rest of #680), the client is connected to the recorded session or to nothing, and
///   both refuse: the card shows that refusal. Nothing here answers in the engine's place.
@MainActor
enum NeedAnswering {
    /// Nil when the engine took the answer; otherwise why it did not, as the person reads it.
    static func send(_ reply: NeedReply, to id: String, through engine: EngineSession<MessageField>) async -> String? {
        let request = reply.request(for: id)
        do {
            try await engine.call(request.method, request.params)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
