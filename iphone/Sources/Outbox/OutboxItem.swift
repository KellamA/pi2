import Foundation
import Security

/// One thing the person wrote while the Mac was out of reach, which the Mac has not been seen to take
/// (docs/iphone.md section 1, "Outbox"): a message, a stop, or an answer to what waits for them.
///
/// Its `id` is made once, when it is written, and never again: it is the id of the sealed item that carries it through
/// the relay's mailbox (the request's nonce, 4.3), which the Mac takes only once, and a message's `requestId`, by which
/// the engine finds a submission it already took rather than take it twice. So sending it again, after the app stopped
/// mid-send or an answer was lost, is never a second message or a second answer.
struct OutboxItem: Codable, Identifiable, Equatable, Sendable {
    /// What kind of thing it is, for the list.
    enum Kind: String, Codable, Sendable {
        case message
        case stop
        case answer
    }

    /// Where it stands.
    enum State: Codable, Equatable, Sendable {
        /// Not sent yet.
        case waiting
        /// Handed to the Mac, with no answer yet. If the app stops here, it is sent again, with the same id.
        case sending
        /// Sealed in the relay's mailbox at this time; the Mac's receipt says whether it took it.
        case inMailbox(Date)
        /// Not sent, with why: the Mac refused it, or it waited too long. Its text stays, to send again.
        case notSent(String)
    }

    let id: String
    let kind: Kind
    /// The engine's request, and its parameters as JSON text, exactly as they will be sent.
    let method: String
    let params: String
    /// A request that widens reach (a `"face"` one, 4.2), which the Mac takes for an hour, not a day.
    let widens: Bool
    let writtenAt: Date
    /// What the list shows: the message, or the answer in words.
    let summary: String
    /// The conversation it goes to, when it names one.
    let conversation: Int?
    var state: State
    /// How many times it was handed to the Mac with no answer.
    var tries: Int

    /// How long the Mac takes it after it was written (4.3): an hour for one that widens reach, else a day.
    var lifetime: TimeInterval { widens ? 3_600 : 86_400 }

    func isExpired(at date: Date) -> Bool {
        date.timeIntervalSince(writtenAt) > lifetime
    }

    /// What the person reads when it waited too long.
    var tooLate: String {
        widens
            ? "Not sent: more than an hour passed before your Mac could take it. Send it again if it still matters."
            : "Not sent: more than a day passed before your Mac could take it. Send it again if it still matters."
    }

    /// Its parameters, to send.
    var parameters: [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(params.utf8))) as? [String: Any]) ?? [:]
    }

    var isPending: Bool {
        switch state {
        case .waiting, .sending: true
        case .inMailbox, .notSent: false
        }
    }

    /// An id for a sealed item: 16 random bytes as base64url, as RemoteKit's `ItemID` reads it.
    static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - What the Outbox takes

extension OutboxItem {
    /// The longest message the Outbox takes: what the relay's mailbox carries (4.2).
    static let longestMessage = 4_000

    /// The item for `method` with `params`, written at `date`, or why the Outbox does not take it. It takes what may wait
    /// in the relay's mailbox while the Mac is away (4.2): a message in words alone, of at most 4,000 characters; a
    /// stop; an answer to an approval, a question, or anything under Needs you. Everything else needs the Mac.
    static func make(_ method: String, _ params: [String: Any], at date: Date) -> Result<OutboxItem, Refusal> {
        var params = params
        let kind: Kind
        let summary: String
        var conversation: Int?
        var widens = params["confirmLimit"] as? Bool == true
        switch method {
        case "submit":
            guard let id = params["id"] as? Int else { return .failure(.notKept) }
            if let attachments = params["attachments"] as? [Any], !attachments.isEmpty {
                return .failure(.because("Photos and files go only once your Mac can be reached. Send the words alone to keep them in the Outbox."))
            }
            let text = (params["text"] as? String) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.notKept) }
            guard text.count <= longestMessage else {
                return .failure(.because("While your Mac can't be reached, a message can be at most \(longestMessage.formatted()) characters. Shorten it, or send it once your Mac is back."))
            }
            // The engine knows a message by its request id: one is given now if the client gave none.
            if (params["requestId"] as? String)?.isEmpty != false { params["requestId"] = UUID().uuidString }
            kind = .message
            summary = text
            conversation = id
        case "abort":
            guard let id = params["id"] as? Int else { return .failure(.notKept) }
            kind = .stop
            summary = "Stop what it is doing"
            conversation = id
        case "inbox.decide":
            guard params["id"] is String, let decision = params["decision"] as? String else { return .failure(.notKept) }
            kind = .answer
            summary = Self.words(approval: decision)
            if decision == "always" || decision == "rule" { widens = true }
        case "inbox.answer":
            guard params["id"] is String, let text = params["text"] as? String, !text.isEmpty else { return .failure(.notKept) }
            kind = .answer
            summary = text
        case "needs.answer":
            guard params["id"] is String, let answer = params["answer"] as? [String: Any] else { return .failure(.notKept) }
            kind = .answer
            (summary, widens) = Self.words(answer: answer, widens: widens)
        default:
            return .failure(.notKept)
        }
        guard JSONSerialization.isValidJSONObject(params),
              let json = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]),
              let text = String(data: json, encoding: .utf8) else { return .failure(.notKept) }
        return .success(OutboxItem(
            id: newID(), kind: kind, method: method, params: text, widens: widens, writtenAt: date, summary: summary,
            conversation: conversation, state: .waiting, tries: 0
        ))
    }

    /// Why the Outbox did not take a request.
    enum Refusal: Error, Equatable {
        /// Not something that can wait for the Mac.
        case notKept
        /// Something that could, but not as it is: why, in the person's words.
        case because(String)
    }

    private static func words(approval decision: String) -> String {
        switch decision {
        case "once": "Allow once"
        case "always": "Always allow"
        case "rule": "Allow, with a rule"
        case "deny": "Deny"
        default: decision
        }
    }

    /// The answer in words, and whether it widens reach: allowing always or with a rule, allowing a reach request, or
    /// starting past a limit (4.2's rows that widen). An approval allowed once whose project switch widens is known only
    /// to the Mac, which takes it as one that widens, within the hour.
    private static func words(answer: [String: Any], widens: Bool) -> (String, Bool) {
        switch answer["kind"] as? String {
        case "approval":
            let decision = answer["decision"] as? String ?? ""
            return (words(approval: decision), widens || decision == "always" || decision == "rule")
        case "question":
            return (answer["text"] as? String ?? "", widens)
        case "decision":
            return (answer["choice"] as? String ?? answer["text"] as? String ?? "", widens)
        case "reach":
            let allow = answer["allow"] as? Bool == true
            return (allow ? "Allow" : "Deny", widens || allow)
        case "rule":
            return (answer["accept"] as? Bool == true ? "Add the rule" : "Don't add it", widens)
        case "limit":
            let start = answer["start"] as? Bool == true
            return (start ? "Start anyway" : "Wait", widens || start)
        default:
            return ("Answer", true)
        }
    }
}
