#if DEBUG
import EngineKit
import Foundation

/// A debug build's stand-in for a Mac: it plays the session `pi2-client-check` replays
/// (`app/Sources/pi2-client-check/Fixture/session.jsonl`, copied into a debug build's bundle and left out of a release
/// build) to the client, so that a screen can be drawn with data in it before the demo mode (#684) or pairing exists.
/// Chosen with `PI2_TRANSPORT=replay` (docs/iphone-app.md).
///
/// It is ready at once, then sends every event of the recording but each conversation's own; those it sends when the
/// client opens that conversation (`conversation.open`), as the engine would. It answers `conversation.open`,
/// `conversation.close` and `conversations.shown`, and refuses every other request with a message saying why, so that
/// a screen that sends one sees an error rather than waiting for ever. Nothing it is sent changes what it plays.
@MainActor
final class ReplayTransport: EngineTransport {
    /// The recording's events but conversations', in order, each ending with a line break.
    private let events: Data
    /// Each conversation's events, in order, each ending with a line break.
    private let conversations: [Int: Data]
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?

    /// The recording in this build's bundle, or nil when it is not there.
    static func recording() -> ReplayTransport? {
        guard let url = Bundle.main.url(forResource: "session", withExtension: "jsonl"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return ReplayTransport(recording: text)
    }

    private struct Envelope: Decodable {
        let event: String?
        let id: Int?
    }

    init(recording: String) {
        var events = Data()
        var conversations: [Int: Data] = [:]
        let decoder = JSONDecoder()
        for line in recording.split(separator: "\n", omittingEmptySubsequences: true) {
            var data = Data(line.utf8)
            guard let envelope = try? decoder.decode(Envelope.self, from: data) else { continue }
            data.append(0x0A)
            switch envelope.event {
            case nil:
                // An answer to a request the recording's app made, which this client never made.
                continue
            case "conversation", "conversation.older":
                if let id = envelope.id { conversations[id, default: Data()].append(data) }
            default:
                events.append(data)
            }
        }
        self.events = events
        self.conversations = conversations
    }

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        self.handler = handler
        let events = events
        Task { @MainActor [weak self] in
            self?.handler?(.ready)
            self?.handler?(.received(events))
        }
    }

    private struct Request: Decodable {
        let id: Int
        let method: String
    }
    private struct Conversation: Decodable {
        struct Params: Decodable { let id: Int }
        let params: Params
    }

    func send(_ data: Data) {
        guard let request = try? JSONDecoder().decode(Request.self, from: data) else { return }
        var reply = Data()
        switch request.method {
        case "conversation.open":
            let id = (try? JSONDecoder().decode(Conversation.self, from: data))?.params.id
            if let id, let recorded = conversations[id] {
                reply.append(recorded)
                reply.append(Self.line(["id": request.id, "result": [String: Any]()]))
            } else {
                reply.append(Self.line(["id": request.id, "error": "The recorded session has no conversation \(id.map(String.init) ?? "?")."]))
            }
        case "conversation.close", "conversations.shown":
            reply.append(Self.line(["id": request.id, "result": [String: Any]()]))
        default:
            reply.append(Self.line(["id": request.id, "error": "The recorded session (PI2_TRANSPORT=replay) does not answer \(request.method)."]))
        }
        // Answered after the request is sent, as a connection would.
        Task { @MainActor [weak self] in self?.handler?(.received(reply)) }
    }

    func cancel() {
        handler = nil
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }
}
#endif
