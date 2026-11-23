
import EngineKit
import Foundation
import PiModels

/// What became of a request an intent sent (docs/iphone.md 4.2, the mailbox column).
enum IntentDelivery: Equatable, Sendable {
    /// The Mac took it.
    case taken
    /// The Mac is out of reach, and the request waits for it in the Outbox, to go through the relay's mailbox (#692).
    case kept
    /// The Mac, or what stands in for it, refused it: the engine's own words.
    case refused(String)
    /// It could not be sent, and nothing kept it.
    case unreachable(String)
}

/// Sends a request or keeps it for later: the one seam between the intents and the way the session reaches its Mac.
///
/// The Outbox (#692) keeps what the person writes while the Mac is out of reach by standing in for the Mac on the
/// session's own client: `AppSession` then runs `CachedTransport`, which answers a request it keeps with
/// `{ "outbox": <item id> }` and refuses the rest with why. So `IntentEngineCourier` below is the only courier the app
/// needs, and the Outbox has to offer nothing more than that answer, with the session running it while `.outOfReach`.
@MainActor
protocol IntentCourier {
    /// Sends the person's message to a conversation, steered into the answer being written when `steer`, else queued.
    func message(_ text: String, to conversation: Int, steer: Bool) async -> IntentDelivery
    /// Sends any other request.
    func request(_ method: String, _ params: [String: Any]) async -> IntentDelivery
}

/// The courier over the session's client, `session.engine`: the requests go exactly as the app's screens send them.
@MainActor
struct IntentEngineCourier: IntentCourier {
    let session: AppSession
    private var engine: EngineSession<MessageField> { session.engine }

    func message(_ text: String, to conversation: Int, steer: Bool) async -> IntentDelivery {
        // `submit` waits up to a minute for an engine that is not there; nothing is waiting to answer it.
        guard engine.status == .connected else { return .unreachable(IntentWords.unreachableNotSent) }
        // The Mac's own call for a message to an orchestrator (`HubStrip.send`), with its request id and its retry.
        switch await engine.submit(text, to: conversation, steer: steer) {
        case .sent:
            // While out of reach the client talks to the Outbox, which took it: the Mac has not.
            return IntentSessions.outOfReach(session) ? .kept : .taken
        case .refused:
            return .refused(engine.lastError ?? "The message was not sent.")
        case .unconfirmed:
            return .unreachable(engine.lastError ?? "Your Mac stopped answering, and pi² can’t tell whether it took the message.")
        }
    }

    func request(_ method: String, _ params: [String: Any]) async -> IntentDelivery {
        guard engine.status == .connected else { return .unreachable(IntentWords.unreachableNotSent) }
        do {
            let result = try await engine.call(method, params)
            return result["outbox"] == nil ? .taken : .kept
        } catch let error as EngineError where error.unanswered {
            return .unreachable(error.message)
        } catch {
            return .refused(error.localizedDescription)
        }
    }
}
