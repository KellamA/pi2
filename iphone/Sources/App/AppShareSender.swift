
import EngineKit
import Foundation
import PiModels

/// What carries a draft from the share sheet to the Mac (`SharePickup`'s `ShareDraftSender`, docs/iphone-app.md, "The
/// extensions"): `submit` through the session's client while it is on the channel, the same mapping as the Outbox's
/// courier; a draft of words alone into the Outbox while the client shows the store's last state; nothing while no
/// session Face ID opened is open. The draft's id is its `requestId`, so a draft handed over twice is one message.
@MainActor
struct AppShareSender: ShareDraftSender {
    /// How a draft can go now.
    enum Way: Equatable, Sendable {
        /// On the channel to the Mac, attached.
        case channel
        /// Into the Outbox: the Mac is out of reach and the store's last state shows.
        case outbox
        /// Not at all: no session is open, or nothing is paired.
        case none
    }

    let way: @MainActor () -> Way
    let call: @MainActor (_ method: String, _ params: [String: Any]) async throws -> Void
    let keep: @MainActor (_ method: String, _ params: [String: Any]) throws -> Void

    /// What a photo or a file waits for while the Mac is out of reach: the mailbox takes words alone.
    static let waitsForTheMac = "Your Mac can't be reached, and a photo or a file can't wait in pi²'s relay: it goes once your Mac can be reached."
    static let locked = "pi² is locked: it goes once Face ID opens pi²."

    /// The way for the app's link: the client on the channel once the greeting came, the Outbox while the store's last
    /// state shows.
    static func way(for link: PhoneLink) -> Way {
        switch link.carrier {
        case .live: link.session.engine.status == .connected ? .channel : .none
        case .cached: .outbox
        case .none: .none
        }
    }

    func deliver(_ draft: ShareDraft) async -> ShareDelivery {
        switch way() {
        case .channel:
            do {
                try await call("submit", draft.submitParameters)
                return .taken
            } catch let error as EngineError {
                return error.unanswered ? .unreachable(error.message) : .refused(error.message)
            } catch {
                return .refused(error.localizedDescription)
            }
        case .outbox:
            guard draft.mayWaitInMailbox else { return .unreachable(Self.waitsForTheMac) }
            do {
                try keep("submit", draft.submitParameters)
                return .kept
            } catch {
                return .refused(error.localizedDescription)
            }
        case .none:
            return .unreachable(Self.locked)
        }
    }
}
