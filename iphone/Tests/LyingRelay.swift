
import Foundation
import RemoteKit
import Synchronization
@testable import pi2

/// A relay that lies, in memory (#680; remotekit.md, "What a caller must and must not do"): it speaks the protocol's
/// first messages to the phone's client, then says what the test gives it. Every word of it is the relay's, which the
/// phone shows and never acts on.
final class LyingRelay: RelayConnector {
    enum Script: Sendable {
        /// Refuses the phone's hello with this word, then closes.
        case refuse(String)
        /// Ready, then sends this text, as if it were a message for this end.
        case readyThenSay(String)
    }

    let script: Script
    let connections = Mutex(0)

    init(_ script: Script) {
        self.script = script
    }

    func connect(to url: URL, pairing: PairingID?) async throws -> any RelaySocket {
        connections.withLock { $0 += 1 }
        return LyingSocket(script)
    }
}

final class LyingSocket: RelaySocket {
    private let script: LyingRelay.Script
    private let frames = Inbox<RelayFrame>()
    private let closing = Mutex<String?>(nil)

    init(_ script: LyingRelay.Script) {
        self.script = script
    }

    func send(_ frame: RelayFrame) async throws {
        guard !frames.isFinished else { throw RelaySocketClosed() }
        guard case let .text(text) = frame else { return }
        if text.hasPrefix(#"{"hello""#) {
            frames.push(.text(JSON.text(.object([("challenge", .string(Base64URL.encode(Bytes.random(32))))]))))
        } else if text.hasPrefix(#"{"proof""#) {
            switch script {
            case let .refuse(word):
                frames.push(.text(JSON.text(.object([("refused", .object([("why", .string(word))]))]))))
                closing.withLock { $0 = word }
                frames.finish()
            case let .readyThenSay(lie):
                frames.push(.text(JSON.text(.object([("ready", .object([("mac", .bool(true)), ("mail", .integer(0))]))]))))
                frames.push(.text(lie))
            }
        }
    }

    func receive() async throws -> RelayFrame {
        if let frame = await frames.next() { return frame }
        throw RelaySocketClosed(code: 1008, reason: closing.withLock { $0 })
    }

    func close() {
        frames.finish()
    }
}
