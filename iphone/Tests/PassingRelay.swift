
import Foundation
import RemoteKit
import Synchronization
@testable import pi2

/// A relay in memory that does its work (#898): it speaks the protocol's first messages to the phone's client, then
/// passes each channel's bytes between it and a `TestMac`, as the relay passes them between the phone's socket and the
/// Mac's. Or it says the Mac is not connected, and the phone's bytes go nowhere.
final class PassingRelay: RelayConnector {
    enum Mac: Sendable {
        /// Connected to the relay: the phone's bytes reach it, and its own come back, the first of each channel `late`.
        case connected(TestMac, late: Duration = .zero)
        /// Not connected to the relay: `ready` says so (`mac: false`), and the phone's bytes are dropped.
        case away
    }

    let mac: Mac
    let connections = Mutex(0)
    /// How many messages the phone sent on each channel through it, in the order the channels began.
    let fromPhone = Mutex<[Int]>([])

    init(_ mac: Mac) {
        self.mac = mac
    }

    func connect(to url: URL, pairing: PairingID?) async throws -> any RelaySocket {
        connections.withLock { $0 += 1 }
        return PassingSocket(self)
    }
}

final class PassingSocket: RelaySocket {
    private let relay: PassingRelay
    private var mac: PassingRelay.Mac { relay.mac }
    private let frames = Inbox<RelayFrame>()
    /// The Mac's end of the channel the phone's bytes go to now.
    private let channel = Mutex<RelayedLink?>(nil)

    init(_ relay: PassingRelay) {
        self.relay = relay
    }

    func send(_ frame: RelayFrame) async throws {
        guard !frames.isFinished else { throw RelaySocketClosed() }
        switch frame {
        case let .text(text):
            if text.hasPrefix(#"{"hello""#) {
                frames.push(.text(JSON.text(.object([("challenge", .string(Base64URL.encode(Bytes.random(32))))]))))
            } else if text.hasPrefix(#"{"proof""#) {
                let online = if case .connected = mac { true } else { false }
                frames.push(.text(JSON.text(.object([("ready", .object([("mac", .bool(online)), ("mail", .integer(0))]))]))))
            } else if text.hasPrefix(#"{"ping""#) {
                frames.push(.text(JSON.text(.object([("pong", .object([]))]))))
            }
        case let .binary(bytes):
            guard case let .connected(testMac, late) = mac else { return }
            // A handshake's first message begins a new channel, as at the test Mac's end of the real relay: the phone
            // pads every frame, so none of its transport messages is that short.
            let (link, fresh): (RelayedLink, Bool) = channel.withLock { channel in
                if bytes.count != ChannelHandshake.connectionFirstMessageLength, let link = channel { return (link, false) }
                channel?.close()
                let link = RelayedLink(toPhone: frames, late: late)
                channel = link
                return (link, true)
            }
            relay.fromPhone.withLock { counts in
                if fresh { counts.append(1) } else { counts[counts.count - 1] += 1 }
            }
            link.inbox.push(bytes)
            if fresh { Task { await testMac.serve(link) } }
        }
    }

    func receive() async throws -> RelayFrame {
        if let frame = await frames.next() { return frame }
        throw RelaySocketClosed(code: 1000, reason: nil)
    }

    func close() {
        frames.finish()
        channel.withLock { $0 }?.close()
    }
}

/// The Mac's end of one channel through `PassingRelay`: what it sends goes to the phone's socket, the first message
/// after `late`, the rest in order behind it.
final class RelayedLink: MessageLink {
    let inbox = Inbox<Data>()
    private let toPhone: Inbox<RelayFrame>
    private let late: Mutex<Duration?>

    init(toPhone: Inbox<RelayFrame>, late: Duration) {
        self.toPhone = toPhone
        self.late = Mutex(late)
    }

    func send(_ message: Data) async throws {
        guard !inbox.isFinished else { throw LinkError.closed }
        if let wait = late.withLock({ late in
            defer { late = nil }
            return late
        }), wait > .zero {
            try? await Task.sleep(for: wait)
        }
        toPhone.push(.binary(message))
    }

    func close() { inbox.finish() }
}
