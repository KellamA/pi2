
import Foundation
import Observation
import os
import RemoteKit

/// The connection to the paired Mac (docs/iphone.md 3.4, 5.1, 5.3, 5.4, 5.8, 6.5): the one object `App/` holds. It
/// reaches the Mac by whichever path comes first, home or relay, attaches with both signatures, carries the engine's
/// lines through `transport()`, resumes the session on a new channel when one drops, and says where it stands in
/// `connection`, in the words the connection bar draws.
///
/// What it acts on, and what it only shows:
/// - It unpairs (deletes the keys and the record) on the Mac's signed revocation alone, checked against the identity
///   key kept from pairing. Nothing the relay says is acted on: a stop with `left`, `removed` or any other word is
///   shown (`problem`), the relay path stays down until `start` is called again, and the home path is still tried.
/// - A refusal that trying again cannot help (`update`, `suspended`, `presence`, `clock`) stops it, with `problem`
///   saying what to do, until the person's word (`tryAgain`) or the next `start`; `resume` sends it to attach afresh
///   once; anything else, or a channel that closes with no word, is tried again after a wait that grows.
/// - It moves no session between paths (#693): a path is chosen at connect time, and its loss is a drop.
@MainActor
@Observable
final class RemoteConnection {
    /// What the connection bar says: `.connecting`, `.connected(path, relayReachable:)`, `.outOfReach(lastSeen:)`, and
    /// `.notPaired` once the Mac revoked this phone.
    private(set) var connection: AppSession.Connection = .connecting
    /// Why it stopped trying, or what the relay said, for the bar or a sheet to show; nil when all is well.
    private(set) var problem: ConnectionProblem?
    /// The Mac's name, as `paired` gave it.
    let macName: String
    /// The Mac revoked this phone: its keys and record are deleted, and the first screen comes back.
    private(set) var unpaired = false

    @ObservationIgnored private let mac: PairedMac
    @ObservationIgnored private let keys: PairedKeys
    @ObservationIgnored private let keyStore: any PairingKeySource
    @ObservationIgnored private let store: any PairingStore
    @ObservationIgnored private let routes: Routes
    @ObservationIgnored private let build: String
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var relay: RelayPath?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var channel: OpenChannel?
    @ObservationIgnored private var current: ChannelTransport?
    @ObservationIgnored private var session: SessionID?
    @ObservationIgnored private var lastSeen: Date?
    @ObservationIgnored private var waiting: [Data] = []
    @ObservationIgnored private var lastAcked: UInt64 = 0
    @ObservationIgnored private let log = Logger(subsystem: "dev.pi2.ios", category: "connection")
    /// How long it waits before trying again, by failures in a row: as the relay's client does (remotekit.md).
    @ObservationIgnored var backoff = RelayBackoff()

    /// A connection for the pairing kept in `store` with the keys kept in `keyStore`, or nil when none is paired (or
    /// what is kept does not read, which counts as none: nothing half kept is used).
    static func paired(keyStore: any PairingKeySource, store: any PairingStore, routes: Routes = Routes(), build: String = PhoneDescription.bundleBuild, now: @escaping @Sendable () -> Date = { Date() }) async -> RemoteConnection? {
        guard let record = try? store.load(), let keys = try? await keyStore.pairedKeys() else { return nil }
        return try? RemoteConnection(record: record, keys: keys, keyStore: keyStore, store: store, routes: routes, build: build, now: now)
    }

    init(record: PairingRecord, keys: PairedKeys, keyStore: any PairingKeySource, store: any PairingStore, routes: Routes = Routes(), build: String = PhoneDescription.bundleBuild, now: @escaping @Sendable () -> Date = { Date() }) throws {
        mac = try record.mac()
        macName = record.macName
        self.keys = keys
        self.keyStore = keyStore
        self.store = store
        self.routes = routes
        self.build = build
        self.now = now
    }

    /// The engine's lines for the session being attached or kept: the same transport until the session is lost, then
    /// a new one. Hand it to `EngineSession.connect`, again each time the session says it was lost.
    func transport() -> ChannelTransport {
        if let current, current.ended == nil { return current }
        let next = ChannelTransport(connection: self)
        current = next
        return next
    }

    /// Starts reaching the Mac, and keeps at it until `stop`. Called as a session opens (after Face ID, 4.5).
    func start() {
        guard runner == nil, !unpaired else { return }
        problem = nil
        if relay == nil {
            relay = try? RelayPath(
                mac: mac, keys: keys, build: RelayBuild(build) ?? RelayBuild("1")!, connector: routes.relayConnector, options: routes.relayOptions,
                changed: { [weak self] status in Task { @MainActor in self?.relayChanged(status) } })
            relay?.start()
        }
        connection = lastSeen.map { .outOfReach(lastSeen: $0) } ?? .connecting
        runner = Task { [weak self] in await self?.run() }
    }

    /// Ends the session (4.5): says so on the channel (`sessionEnd`), closes it and the relay's connection, and tries no
    /// more until `start`.
    func stop() {
        runner?.cancel()
        runner = nil
        if let channel {
            try? channel.send(.sessionEnd)
            channel.close()
        }
        channel = nil
        session = nil
        current?.end("The session ended.")
        relay?.stop()
        relay = nil
        if !unpaired { connection = .outOfReach(lastSeen: lastSeen) }
    }

    /// "Unpair this iPhone" from the phone's side, and the first step of pairing again (3.3, 3.6): the relay is told
    /// `leave`, signed with the device key, if it is connected; the session ends and the keys and the record are
    /// deleted at once, without waiting for the relay's answer (`leave` has a deadline of its own and may end `lost`).
    /// The relay's client is handed to the leave, which stops it once answered or not. `devices.forgetSelf`, which
    /// revokes the phone on the Mac, is a request of the engine's the app sends through its client before this.
    func unpairHere() async {
        if let relay, relay.status.ready {
            // The leave keeps the client; `stop` below must not close its socket under it.
            self.relay = nil
            let client = relay.client
            Task {
                try? await client.leave()
                await client.stop()
            }
        }
        stop()
        await unpair()
    }

    /// The person's word after a problem: try again now.
    func tryAgain() {
        stop()
        start()
    }

    // MARK: - From the transport

    func send(line: Data, from transport: ChannelTransport) {
        guard transport === current else { return }
        guard let channel, transport.isAttached else {
            waiting.append(line)
            return
        }
        do {
            try channel.send(line: line)
        } catch {
            waiting.append(line)
            channel.drop()
        }
    }

    func cancelled(_ transport: ChannelTransport) {}

    // MARK: - The loop

    private func run() async {
        var failures = 0
        var resumeRefused = false
        while !Task.isCancelled, !unpaired {
            do {
                let reached = try await Race.first(attempts())
                let resume = session.flatMap { session in current.map { Attach.Resume(session: session, received: $0.received) } }
                let outcome = try await Attach.run(over: reached.link, path: reached.path, mac: mac, keys: keys, resume: resume, build: build, now: now)
                guard !Task.isCancelled else {
                    if case let .attached(_, channel) = outcome { channel.close() }
                    return
                }
                switch outcome {
                case let .attached(attached, channel):
                    failures = 0
                    resumeRefused = false
                    if !attached.resume, session != nil { current?.end("The Mac did not resume the session.") }
                    session = attached.session
                    await carry(channel, attached: attached)
                    continue
                case .refused(.resume?) where !resumeRefused:
                    // The session is gone: attach afresh at once, once (remotekit.md).
                    resumeRefused = true
                    forgetSession("The Mac could not resume the session.")
                    continue
                case let .refused(reason?) where reason != .resume:
                    stopTrying(ConnectionProblem(reason))
                    return
                case .revoked:
                    await unpair()
                    return
                case .refused, .closed:
                    failures += 1
                }
            } catch let failure as Attach.Failure {
                switch failure {
                case let .presence(error):
                    stopTrying(.faceID(error))
                    return
                case .macNotProved:
                    problem = .macNotProved
                    failures += 1
                case .deviceKey, .unreadable:
                    failures += 1
                }
            } catch {
                failures += 1
            }
            if Task.isCancelled { return }
            connection = .outOfReach(lastSeen: lastSeen)
            let wait = backoff.delay(attempt: max(failures - 1, 0), random: Double.random(in: 0..<1))
            try? await Task.sleep(for: .milliseconds(wait))
        }
    }

    /// The paths for one attempt: the Mac's last addresses and Bonjour, and the relay unless it stopped.
    private func attempts() -> [@Sendable () async throws -> Reached] {
        var attempts = HomeReach.attempts(addresses: mac.addresses, macChannelKey: mac.channelKey, pairing: mac.pairing, routes: routes)
        if let relay, relay.status.stopped == nil {
            let within = routes.relayWithin
            attempts.append { Reached(link: try await relay.openLink(within: within), path: .relay) }
        }
        return attempts
    }

    /// Carries the session's lines on `channel` until it drops.
    private func carry(_ channel: OpenChannel, attached: Attached) async {
        self.channel = channel
        let transport = transport()
        lastAcked = transport.received
        transport.becameAttached()
        lastSeen = now()
        connection = .connected(channel.path, relayReachable: channel.path == .relay || relay?.status.ready == true)
        let queued = waiting
        waiting = []
        for line in queued { send(line: line, from: transport) }

        let acks = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.ack(force: true)
            }
        }
        defer { acks.cancel() }
        var bytes = 0
        while !Task.isCancelled {
            let event: ChannelEvent?
            do {
                event = try await channel.next()
            } catch {
                log.notice("channel failed: \(String(describing: error), privacy: .public)")
                break
            }
            guard let event else {
                log.notice("channel closed")
                break
            }
            lastSeen = now()
            switch event {
            case let .line(line):
                if line.starts(with: Data(#"{"revoked":"#.utf8)), case let .revoked(revocation)? = try? ControlLine.parse(line) {
                    if (try? Attach.verified(revocation, mac: mac)) == true {
                        await unpair()
                        return
                    }
                    channel.drop()
                    break
                }
                transport.deliver(line)
                bytes += line.count
                // An ack every second or every 64 KB (5.8), whichever comes first.
                if bytes >= 64 * 1024 {
                    bytes = 0
                    ack(force: true)
                }
            case .ack, .ping:
                continue
            case .bye:
                log.notice("channel ended with bye")
            }
            if case .bye = event { break }
        }
        if self.channel === channel { self.channel = nil }
        channel.drop()
        if !Task.isCancelled, !unpaired { connection = .connecting }
    }

    private func ack(force: Bool) {
        guard let channel, let current, current.received > lastAcked else { return }
        lastAcked = current.received
        try? channel.sendAck(current.received)
    }

    private func forgetSession(_ why: String) {
        session = nil
        waiting = []
        current?.end(why)
    }

    private func stopTrying(_ problem: ConnectionProblem) {
        self.problem = problem
        log.notice("stopped trying: \(problem.title, privacy: .public)")
        runner = nil
        connection = .outOfReach(lastSeen: lastSeen)
    }

    /// The Mac's signed revocation (3.6): the keys and the record go, and the first screen comes back. The cache, the
    /// Outbox and the notifications are the store's to clear (#692).
    private func unpair() async {
        unpaired = true
        runner = nil
        channel?.drop()
        channel = nil
        relay?.stop()
        relay = nil
        forgetSession("This iPhone was revoked on the Mac.")
        try? await keyStore.wipe()
        try? store.delete()
        connection = .notPaired
    }

    private func relayChanged(_ status: RelayPath.Status) {
        if let stopped = status.stopped, problem == nil { problem = .relaySaid(RelayPath.word(stopped)) }
        if case let .connected(path, _) = connection {
            connection = .connected(path, relayReachable: path == .relay || status.ready)
        }
    }
}

/// What stopped the connection, or what the relay said, in the words the phone shows (docs/design/iphone.md, "The
/// phone when the Mac is asleep or out of reach"; remotekit.md, "The refused line").
enum ConnectionProblem: Equatable, Sendable {
    /// `refused` with `update`.
    case update
    /// `refused` with `suspended`.
    case suspended
    /// `refused` with `presence`.
    case presence
    /// `refused` with `clock`.
    case clock
    /// Face ID has not opened a session, or it ended.
    case faceID(PresenceError)
    /// What answered on a path did not prove it is the paired Mac.
    case macNotProved
    /// The relay stopped this phone's connection, with its word: shown as the relay's word, never acted on.
    case relaySaid(String)

    init(_ reason: Refusal.Reason) {
        switch reason {
        case .update: self = .update
        case .suspended: self = .suspended
        case .presence: self = .presence
        case .clock: self = .clock
        case .resume: self = .relaySaid("resume")
        }
    }

    var title: String {
        switch self {
        case .update: "Update pi² for iPhone"
        case .suspended: "Your Mac suspended this iPhone"
        case .presence: "Your Mac did not take Face ID"
        case .clock: "The clocks are apart"
        case .faceID: "Face ID needed"
        case .macNotProved: "Not your Mac"
        case .relaySaid: "What pi²'s relay says"
        }
    }

    var words: String {
        switch self {
        case .update:
            "This version of pi² for iPhone is older than your Mac takes. Update it from TestFlight, then open it again."
        case .suspended:
            "Your Mac suspended this iPhone after tries it refused. To use it again, resume this iPhone on your Mac in pi² › Settings › Devices."
        case .presence:
            "Your Mac did not take this iPhone's Face ID. Open pi² again to use Face ID. If Face ID was set up again on this iPhone, accept its new key on your Mac in Settings › Devices first."
        case .clock:
            "This iPhone's clock and your Mac's differ by more than two minutes. On both, turn on setting the date and time automatically, then try again."
        case .faceID(.sessionNotOpen):
            "pi² is locked. Open it with Face ID to reach your Mac."
        case .faceID(.faceIDNotPassed):
            "Face ID did not pass, so pi² did not connect to your Mac. Try again."
        case .macNotProved:
            "Something answered as your Mac but could not prove it is. Nothing was sent to it; pi² keeps trying your Mac."
        case let .relaySaid(word):
            switch word {
            case "left", "removed", "not-listed", "deleted", "unknown-pairing":
                "pi²'s relay says this iPhone is no longer paired with your Mac there. Only your Mac can unpair it, so nothing was forgotten: pi² still reaches your Mac on your home network, and tries the relay again the next time it opens."
            case "update-required":
                "pi²'s relay says this version of pi² for iPhone is too old. Update it from TestFlight."
            default:
                "pi²'s relay stopped this iPhone's connection (it says “\(word)”). Nothing was forgotten: pi² still reaches your Mac on your home network, and tries the relay again the next time it opens."
            }
        }
    }
}
