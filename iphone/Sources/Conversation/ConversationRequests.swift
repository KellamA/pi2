import EngineKit
import Foundation

/// The requests the conversation's screen makes, each made as the Mac app makes it, through the same client
/// (`session.engine`), so that they work as they are once a real channel carries them (docs/iphone.md 4.2: every one of
/// them is a phone's to send). Each answers with what to tell the person when the engine refused it, in its words, or
/// nil when it was taken; none answers for the engine.
@MainActor
struct ConversationRequests {
    let engine: EngineSession<MessageField>
    let conversationID: Int

    /// Sends a message: `submit`, as the Mac's message field sends it (`ConversationDraft.send`, through
    /// `EngineSession.submit`, which keeps it in `outgoing` until the conversation shows it). `steer` while the agent
    /// works and the person chose Steer; queued otherwise.
    func send(_ text: String, pictures: [ConversationPicture], steer: Bool) async -> SendOutcome {
        // Refused here as the engine would refuse it (#924), and given back to the field without a request.
        if let tooLong = TypedTextLimit.refusal(text) { return .refused(Self.sentence("Not sent.", tooLong)) }
        let outcome = await engine.submit(text, attachments: pictures.map(\.payload), to: conversationID, steer: steer)
        switch outcome {
        case .sent:
            return .sent
        case .refused:
            return .refused(Self.sentence("Not sent.", engine.lastError))
        case .unconfirmed:
            return .unconfirmed(engine.lastError ?? "The message may not have been sent. Check the conversation before sending it again.")
        }
    }

    enum SendOutcome: Equatable {
        case sent
        /// The engine refused it: the message goes back in the field.
        case refused(String)
        /// No answer came: it may have been taken. It does not go back, so that it is not sent twice.
        case unconfirmed(String)
    }

    /// Stop: `abort`, as the Mac's Stop button sends it (`ChatView`): ends the run and everything it started.
    func stop() async -> String? {
        await request("abort", ["id": conversationID], failing: "Not stopped.")
    }

    /// Takes back a queued message before the model reads it: `withdraw`, as the Mac's chip's Remove sends it.
    func withdraw(_ submission: Int) async -> String? {
        await request("withdraw", ["submissionId": submission], failing: "Not taken back.")
    }

    /// Resumes a run that stopped, without a new message: `continue`, as the Mac's Continue sends it.
    func carryOn() async -> String? {
        await request("continue", ["id": conversationID], failing: "Not continued.")
    }

    /// Brings an archived conversation back, or the one this sub-chat belongs to: `conversation.unarchive`, as the
    /// Mac's Restore sends it.
    func restore(_ id: Int) async -> String? {
        await request("conversation.unarchive", ["id": id], failing: "Not restored.")
    }

    /// One of an entry's pictures, for the page: `conversation.image`, as the Mac's page bridge asks for it
    /// (`TranscriptBridge.sendPicture`). Nil when it could not be had.
    func picture(entry: Int, index: Int) async -> (data: String, mimeType: String)? {
        guard let result = try? await engine.call("conversation.image", ["id": conversationID, "entryId": entry, "index": index]),
              let data = result["data"]?.stringValue, let type = result["mimeType"]?.stringValue else { return nil }
        return (data, type)
    }

    private func request(_ method: String, _ params: [String: Any], failing: String) async -> String? {
        do {
            try await engine.call(method, params)
            return nil
        } catch {
            return Self.sentence(failing, error.localizedDescription)
        }
    }

    /// "Not sent." and the engine's reason after it.
    static func sentence(_ what: String, _ why: String?) -> String {
        guard let why, !why.isEmpty else { return what }
        return "\(what) \(why)"
    }
}
