
import Foundation
import os
import RemoteKit
import Synchronization

/// The phone's own connection to the relay once paired (docs/iphone.md 5.3): RemoteKit's `RelayClient` as this
/// device, kept open while the app connects, which carries one channel at a time to the Mac.
///
/// What the relay says is its word (remotekit.md, "What a caller must and must not do"): whether the Mac is there, a
/// stop for `left`, `removed`, `not-listed` or any other word, `busy`. Each is reported to show, never acted on: the
/// phone forgets, wipes and re-pairs on nothing the relay says, only on the Mac's signed revocation, which comes inside
/// the channel. After a stop the relay path stays down until the app starts it again (the next launch, or the person's
/// word), and the home path is still tried.
final class RelayPath: Sendable {
    /// What the relay last said, for the connection's state.
    struct Status: Equatable, Sendable {
        /// Connected and proved just now.
        var ready = false
        /// The relay says the Mac is connected: a hint.
        var macOnline: Bool?
        /// The relay stopped the client, with its word (or an HTTP status): shown, never acted on.
        var stopped: RelayStop?
    }

    let client: RelayClient
    private let state = Mutex<(status: Status, link: RelayChannelLink?)>((Status(), nil))
    private let changes: @Sendable (Status) -> Void

    init(mac: PairedMac, keys: PairedKeys, build: RelayBuild, connector: any RelayConnector, options: RelayOptions, changed: @escaping @Sendable (Status) -> Void) throws {
        client = try RelayClient(
            relay: mac.relay, role: .device(mac.pairing, mac.device), build: build,
            signer: try DeviceStatementSigner(keys.device).relaySigner, connector: connector, options: options)
        changes = changed
    }

    var status: Status { state.withLock { $0.status } }

    func start() {
        let client = client
        Task {
            await client.start()
            for await event in client.events { self.handle(event) }
        }
    }

    func stop() {
        let client = client
        Task { await client.stop() }
        state.withLock { $0.link }?.close()
    }

    private func handle(_ event: RelayEvent) {
        var status: Status?
        var closing: RelayChannelLink?
        state.withLock { state in
            switch event {
            case let .deviceReady(macOnline, _):
                state.status.ready = true
                state.status.macOnline = macOnline
                status = state.status
            case let .macOnline(online):
                state.status.macOnline = online
                status = state.status
            case let .data(_, bytes):
                state.link?.inbox.push(bytes)
            case let .disconnected(drop, _):
                Logger(subsystem: "dev.pi2.ios", category: "relay").notice("relay connection dropped: \(String(describing: drop), privacy: .public)")
                state.status.ready = false
                closing = state.link
                state.link = nil
                status = state.status
            case let .stopped(reason):
                state.status.ready = false
                // The user's own stop says nothing of the relay.
                if reason != .stopped { state.status.stopped = reason }
                closing = state.link
                state.link = nil
                status = state.status
            default:
                // A Mac's notices never reach a phone's client; `mail` is the mailbox's (#692).
                break
            }
        }
        closing?.close()
        if let status { changes(status) }
    }

    /// A link to the Mac for one channel, once the relay is ready: within `limit`, or `LinkError.timedOut`. A link
    /// opened before it is closed: one channel at a time.
    func openLink(within limit: Duration) async throws -> any MessageLink {
        let deadline = ContinuousClock.now + limit
        while !status.ready {
            if let stopped = status.stopped { throw LinkError.relay(RelayWord(word: Self.word(stopped))) }
            guard ContinuousClock.now < deadline else { throw LinkError.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
        let link = RelayChannelLink(client: client)
        let previous = state.withLock { state in
            defer { state.link = link }
            return state.link
        }
        previous?.close()
        return link
    }

    static func word(_ stop: RelayStop) -> String {
        switch stop {
        case .stopped: "stopped"
        case let .refused(why): why.word
        case let .http(status): "http-\(status)"
        case .cannotSign: "cannot-sign"
        }
    }
}

/// One channel's link over the phone's relay connection.
final class RelayChannelLink: MessageLink {
    let inbox = Inbox<Data>()
    private let client: RelayClient

    init(client: RelayClient) {
        self.client = client
    }

    func send(_ message: Data) async throws {
        guard !inbox.isFinished else { throw LinkError.closed }
        do {
            try await client.send(message)
        } catch {
            throw LinkError.closed
        }
    }

    func close() {
        inbox.finish()
    }
}
