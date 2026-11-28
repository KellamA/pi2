import Foundation
import RemoteKit

/// The Mac's addresses, and moving a session to one of them (docs/iphone.md 5.1, 5.4, 5.8; #693).
///
/// The relay is the path that must always work; a direct channel is tried because it is cheaper, never because something
/// needs it. A phone that is away reaches its Mac over the relay, and when it comes home the Mac's listener is reachable
/// at an address of the Mac's: while the session runs over the relay, the addresses of the Mac's `device` event are tried
/// in the background, and the first channel whose Mac proves itself there resumes the session (`Attach.attach` with the
/// session and the count of lines the phone has had). Nothing of a move is decided here: the Mac's identity key, the
/// device key and the presence key check the channel as every other, and the engine resumes the session alone. Once the
/// Mac resumes it, `RemoteConnection` closes the relay channel and carries on: the lines in flight at the moment of the
/// move come twice, which the phone drops by their count (5.8).
///
/// The addresses are the ones the Mac last gave, in `paired` and in its `device` event (5.6). They are kept with the
/// pairing record, so the next connection tries them too.
struct Paths: Sendable {
    let mac: PairedMac
    let keys: PairedKeys
    let routes: Routes
    let build: String
    let now: @Sendable () -> Date

    /// What trying the Mac's addresses came to.
    enum Outcome: Sendable {
        /// A channel the Mac proved itself on, which resumed `session` from `named` lines: the session is on it now, and
        /// the channel it was on is the caller's to close.
        case moved(OpenChannel, Attached, named: UInt64)
        /// The Mac refused the attach, with a reason this build reads (`Refusal.Reason`), or none: the caller says what
        /// it means, or ignores it while the session goes on over the relay.
        case refused(Refusal.Reason?)
        /// No address gave a channel that proved, before the move stopped being wanted (the channel it was for ending,
        /// or the task cancelled). A channel the Mac gave a new session instead of resuming is one of these too.
        case unavailable
    }

    /// Tries the Mac's addresses, all at once, until one gives a channel whose Mac proved itself; on it, attaches with
    /// `session` to resume, the count `received` being the phone's at the moment of the attach. One round: the caller
    /// tries it again while it still wants the move, which is also how the addresses a `device` event brings are picked up.
    ///
    /// A channel the Mac answers with a new session instead of the one to resume is dropped: that session is not the one
    /// over the relay, and the phone would hold two at the engine.
    func move(session: SessionID, received: @MainActor @Sendable () -> UInt64) async -> Outcome {
        let attempts = attempts()
        guard !attempts.isEmpty else { return .unavailable }
        do {
            let proved = try await Race.first(attempts, closing: { $0.channel.drop() })
            // Read at the attach, never before: a line that comes while the channel is made is one the phone has, and
            // the Mac must not send it again.
            let named = await received()
            switch try await Attach.attach(proved, mac: mac, keys: keys, resume: Attach.Resume(session: session, received: named), build: build, now: now) {
            case let .attached(attached, channel):
                guard attached.resume, attached.session == session else {
                    channel.drop()
                    return .unavailable
                }
                return .moved(channel, attached, named: named)
            case let .refused(reason):
                return .refused(reason)
            case .revoked:
                // Its signed revocation comes on the session's own channel, which is the one to act on it (3.6).
                return .unavailable
            case .closed:
                return .unavailable
            }
        } catch {
            // A network that changed under it, or no answer: another round, if the move is still wanted.
            return .unavailable
        }
    }

    /// Each of the Mac's addresses, dialled and proved at once, as the connection's own attempts are (5.4): the first
    /// channel whose Mac proves itself is kept by `Race`.
    private func attempts() -> [@Sendable () async throws -> Attach.Proved] {
        let mac = mac, keys = keys, routes = routes
        return mac.addresses.compactMap(MacAddress.endpoint).map { endpoint in
            {
                let link = try await routes.dialer.dial(endpoint, within: routes.dialWithin)
                return try await Attach.prove(over: link, path: .direct, mac: mac, keys: keys)
            }
        }
    }
}

/// What the phone reads of the Mac's `device` event (docs/iphone.md 5.6): the addresses it tries.
enum MacEvent {
    /// The Mac's addresses, as its `device` event gives them; nil for a line that is not one. An event with no addresses
    /// is an empty list: the Mac has none to give now, and the phone tries none.
    static func addresses(in line: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["event"] as? String == "device" else { return nil }
        return object["addresses"] as? [String] ?? []
    }
}
