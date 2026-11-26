
import Foundation
import Network
import RemoteKit
import Synchronization

// The link layer (docs/iphone.md 5.1): whatever carries a channel's Noise messages between the phone and pi² Remote,
// whole, in order, both ways. Above it nothing knows which path it is: the home path's TCP with the two-byte length
// framing (5.2, 5.4), or the relay's binary WebSocket messages, through the join's link while pairing and the phone's
// own relay connection after (5.3).

/// One path's link for one channel.
protocol MessageLink: AnyObject, Sendable {
    /// The Mac's messages, as they come; closed when the link is.
    var inbox: Inbox<Data> { get }
    func send(_ message: Data) async throws
    /// Closes it. The inbox is closed with it.
    func close()
}

/// A Mac's address as the payload's `a` and `paired` write it: `a.b.c.d:port` or `[v6]:port` (remotekit.md).
enum MacAddress {
    static func endpoint(_ text: String) -> NWEndpoint? {
        guard PairingPayload.isHostAndPort(text), let colon = text.lastIndex(of: ":"),
              let port = UInt16(text[text.index(after: colon)...]), port > 0, let nwPort = NWEndpoint.Port(rawValue: port)
        else { return nil }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
            guard let address = IPv6Address(host) else { return nil }
            return .hostPort(host: .ipv6(address), port: nwPort)
        }
        guard let address = IPv4Address(host) else { return nil }
        return .hostPort(host: .ipv4(address), port: nwPort)
    }
}

/// Opens TCP links. The app's is `TCPDialer`; a test may give its own.
protocol Dialer: Sendable {
    func dial(_ endpoint: NWEndpoint, within limit: Duration) async throws -> any MessageLink
}

struct TCPDialer: Dialer {
    func dial(_ endpoint: NWEndpoint, within limit: Duration) async throws -> any MessageLink {
        try await TCPLink.connect(to: endpoint, within: limit)
    }
}

/// The home path's TCP connection (5.4): each Noise message preceded by its length, two bytes, big-endian
/// (`LengthFraming`). Network.framework's own connection, on a queue of its own.
final class TCPLink: MessageLink, @unchecked Sendable {
    // `framing` is touched only on `queue`; everything else is immutable or locked.
    let inbox = Inbox<Data>()
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.pi2.ios.tcp-link")
    private var framing = LengthFraming()
    private let closed = Mutex(false)

    /// Wraps a connection that is ready, as a listener gives it (the tests' Mac).
    init(ready connection: NWConnection) {
        self.connection = connection
        receive()
    }

    private init(connecting connection: NWConnection) {
        self.connection = connection
    }

    /// Connects, or throws `LinkError.timedOut` or `.closed`.
    static func connect(to endpoint: NWEndpoint, within limit: Duration) async throws -> TCPLink {
        let parameters = NWParameters.tcp
        // The channel is all the phone sends; Nagle would hold back its small messages.
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        let link = TCPLink(connecting: NWConnection(to: endpoint, using: parameters))
        let once = Mutex<CheckedContinuation<Void, any Error>?>(nil)
        let settle: @Sendable (Result<Void, any Error>) -> Void = { result in
            let waiting = once.withLock { waiting in
                defer { waiting = nil }
                return waiting
            }
            waiting?.resume(with: result)
        }
        let deadline = Task {
            try? await Task.sleep(for: limit)
            settle(.failure(LinkError.timedOut))
        }
        defer { deadline.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    once.withLock { $0 = continuation }
                    link.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: settle(.success(()))
                        // Waiting is a network with no way there now: for a path raced against others, a failure.
                        case .failed, .waiting, .cancelled: settle(.failure(LinkError.closed))
                        default: break
                        }
                    }
                    link.connection.start(queue: link.queue)
                    if Task.isCancelled { settle(.failure(CancellationError())) }
                }
            } onCancel: {
                settle(.failure(CancellationError()))
            }
        } catch {
            link.close()
            throw error
        }
        link.connection.stateUpdateHandler = { [weak link] state in
            switch state {
            case .failed, .cancelled: link?.close()
            default: break
            }
        }
        link.receive()
        return link
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try self.framing.push(data) { self.inbox.push(message) }
                } catch {
                    self.close()
                    return
                }
            }
            if complete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    func send(_ message: Data) async throws {
        guard !closed.withLock({ $0 }) else { throw LinkError.closed }
        let framed = try LengthFraming.encode(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: LinkError.closed) } else { continuation.resume() }
            })
        }
    }

    func close() {
        let first = closed.withLock { closed in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        connection.cancel()
        inbox.finish()
    }
}

/// A joined phone's socket at the relay, while pairing (3.3 step 2): the channel's bytes to and from the Mac.
final class JoinMessageLink: MessageLink {
    let inbox = Inbox<Data>()
    private let link: RelayJoinLink

    init(_ link: RelayJoinLink) {
        self.link = link
        let inbox = inbox
        Task {
            for await event in link.events {
                if case let .data(bytes) = event { inbox.push(bytes) }
            }
            inbox.finish()
        }
    }

    func send(_ message: Data) async throws {
        do {
            try await link.send(message)
        } catch {
            throw LinkError.closed
        }
    }

    func close() {
        inbox.finish()
        let link = link
        Task { await link.close() }
    }
}
