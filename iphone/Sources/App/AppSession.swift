import EngineKit
import Foundation
import Observation
import os
import PiModels

/// What the whole app shares (docs/iphone-app.md): EngineKit's client, `engine`, over whatever `EngineTransport` carries
/// the engine's lines (docs/iphone.md section 8), and the state of the connection that the connection bar draws. Every
/// screen reads the engine's state from `engine` (its projects, needs, conversations and the rest, as on the Mac) and
/// sends its requests through it; none holds a transport or a client of its own.
///
/// For now `connection` is set from outside: by the debug launch arguments, and later by pairing and the channel (the
/// rest of #680) and the demo mode (#684), which also choose the transport (`Launch`).
@MainActor
@Observable
final class AppSession: EngineSessionHost {
    /// How the phone reaches its Mac while connected (docs/design/iphone.md, "On any network").
    enum Path: String, CaseIterable, Sendable {
        /// Over the home network, straight to the Mac ("At home").
        case home
        /// Through pi²'s relay ("Through pi²'s relay").
        case relay
        /// Straight to the Mac from another network ("Direct").
        case direct
    }

    /// What the connection bar says (docs/design/iphone.md, "The projects list" and "The phone when the Mac is asleep or
    /// out of reach").
    enum Connection: Equatable, Sendable {
        /// No Mac paired, and not in the demo mode: the app shows its first screen.
        case notPaired
        /// The demo mode: canned data, no Mac, no network (docs/iphone.md 9.4).
        case demo
        /// Paired, and reaching for the Mac.
        case connecting
        /// Connected, by this path. `relayReachable` false is "Relay unreachable · at home only".
        case connected(Path, relayReachable: Bool = true)
        /// Paired, and the Mac cannot be reached: asleep, off, or no path. `lastSeen` is when the phone last heard from
        /// it, if ever ("Mac asleep since 23:10").
        case outOfReach(lastSeen: Date?)
    }

    var connection: Connection
    /// The paired Mac's name, for the bar; nil when none is paired or its name is not known yet.
    var macName: String?
    /// The engine's client: what the Mac's engine has sent, read into the shared models, and its requests.
    let engine = EngineSession<MessageField>()

    @ObservationIgnored private let log = Logger(subsystem: "dev.pi2.ios", category: "session")

    init(connection: Connection = .notPaired) {
        self.connection = connection
        engine.host = self
    }

    /// Connects the client over `transport`, and says how the bar is to describe it.
    func start(_ transport: any EngineTransport, as connection: Connection) {
        self.connection = connection
        engine.connect(transport)
    }

    // MARK: - EngineSessionHost

    func note(_ message: String) {
        log.notice("\(message, privacy: .public)")
    }
}

/// What the client keeps of a conversation's message field while the phone shows it: its unsent text. The
/// conversation's screen (#687) reads and writes `text`; the client keeps a field with text when the conversation closes.
@MainActor
@Observable
final class MessageField: MessageDraft {
    var text = ""

    init() {}

    var hasInput: Bool { !text.isEmpty }

    func discard() {
        text = ""
    }
}
