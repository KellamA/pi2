import EngineKit
import Foundation
import PiModels

/// What carries the Outbox's items to the Mac: the session satisfies it, over the channel when it is attached and
/// through the relay's mailbox when only the relay can be reached (docs/iphone.md 5.3, 5.8). The Outbox hands it one
/// item at a time, oldest first, and waits for each.
@MainActor
protocol OutboxCourier {
    /// Hands `item` to the Mac, as the engine's request `item.method` with `item.parameters`, and says what came of it.
    /// An item can be handed over again after the app stopped mid-send: its id and its request id are the same each
    /// time, so the Mac takes it once.
    func deliver(_ item: OutboxItem) async -> OutboxDelivery
}

/// What came of handing an item to the Mac.
enum OutboxDelivery: Equatable, Sendable {
    /// The Mac answered and took it.
    case taken
    /// The Mac answered and refused it, with why in the person's words.
    case refused(String)
    /// Sealed in the relay's mailbox; the Mac's receipt comes later (`Outbox.receipt`).
    case inMailbox
    /// No answer: not reached, or the connection went before the Mac answered. It stays, to go again with the same id.
    case unreachable(String)
}

/// The courier over a connected session: each item is the engine's own request, sent through the client as any other
/// (`EngineSession.call`), on whatever channel the session is on. Once the channel has attached, `AppSession` sends the
/// Outbox through it before anything new: `await outbox.send(through: EngineOutboxCourier(engine))`.
@MainActor
struct EngineOutboxCourier<Draft: MessageDraft>: OutboxCourier {
    let engine: EngineSession<Draft>

    init(_ engine: EngineSession<Draft>) {
        self.engine = engine
    }

    func deliver(_ item: OutboxItem) async -> OutboxDelivery {
        do {
            _ = try await engine.call(item.method, item.parameters)
            return .taken
        } catch let error as EngineError {
            return error.unanswered ? .unreachable(error.message) : .refused(error.message)
        } catch {
            return .refused(error.localizedDescription)
        }
    }
}
