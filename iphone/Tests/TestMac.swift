
import CryptoKit
import EngineKit
import Foundation
import Network
import RemoteKit
import Synchronization
@testable import pi2

/// A Mac for the phone's tests, made of real RemoteKit with test keys (#680): pi² Remote's side of pairing and of every
/// connection, as `pi2-remote-check` and `pi2-relay-check` play it, over loopback TCP (a listener on 127.0.0.1 only)
/// and through a relay (the local relay, started by `relay/`'s own scripts). Once a phone is attached it answers the
/// engine's lines from the recorded session `pi2-client-check` replays (the app's `ReplayTransport`, as the engine).
///
/// What the test makes it do is in `rules`: the digits the person types, a proof signed by another key, a refusal, a
/// clock, a revocation.
final class TestMac: @unchecked Sendable {
    let identity = P256.Signing.PrivateKey()
    let channelKey = Curve25519.KeyAgreement.PrivateKey()
    let recordKey = P256.KeyAgreement.PrivateKey()
    let relayKey = P256.Signing.PrivateKey()
    let name = "Test Mac"
    let secret = Bytes.random(32)

    struct Rules {
        /// What the person types on the Mac, given the digits the phone showed.
        var type: @Sendable (String) -> String = { $0 }
        /// Signs its proofs with this key, not its identity key: another Mac, or a copy without its Secure Enclave.
        var proofKey: P256.Signing.PrivateKey?
        /// Refuses every attach with this reason.
        var refuse: Refusal.Reason?
        /// Answers a claim, once the digits are typed, with `pairRefused` and this word (or the line as given) in place of `paired`.
        var refusePairing: PairRefusal.Why?
        var refusePairingLine: Data?
        /// Its clock, ahead of the phone's by this much.
        var clockAhead: TimeInterval = 0
        /// Answers an attach with its signed `revoked` line, signed by this key (its own identity key if nil).
        var revokeWithLine = false
        var revocationKey: P256.Signing.PrivateKey?
        /// Takes resumes; false answers every resume `resume: false`.
        var resumes = true
    }

    struct Device {
        let id: DeviceID
        let channelKey: Curve25519.KeyAgreement.PublicKey
        let deviceKey: P256.Signing.PublicKey
        let presenceKey: P256.Signing.PublicKey
    }

    struct State {
        var pairing: PairingID
        var devices: [Device] = []
        var revoked: Set<DeviceID> = []
        var claims: [PairClaim] = []
        var attaches: [AttachClaim] = []
        var attachLines: [Data] = []
        var challenges: [Data] = []
        var refusedAttaches = 0
        var attachedCount = 0
        var current: SessionID?
        var links: [any MessageLink] = []
        var relayLinks: [DeviceID: MacRelayLink] = [:]
        var channels: [MacChannel] = []
        var joined: [RelayJoinNotice] = []
        var paired: [DeviceID] = []
        var sessionEnds = 0
        var requests: [String] = []
        /// The home tag's key, sent in `paired` and after every `attached`.
        var homeKey = HomeKey.random()
    }

    let rules: Mutex<Rules>
    let state: Mutex<State>
    /// The digits the person types, as the test hands them in after reading them off the phone.
    let typed = Inbox<String>()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var relayClient: RelayClient?
    /// Each channel's outgoing lines to the phone, by session, so that a resume can serve what the phone missed.
    private let engines = Mutex<[SessionID: EngineEnd]>([:])

    init(pairing: PairingID = .random(), rules: Rules = Rules()) {
        self.rules = Mutex(rules)
        state = Mutex(State(pairing: pairing))
    }

    var pairing: PairingID { state.withLock { $0.pairing } }

    func payload(relay: String, addresses: [String], expires: Int64? = nil) throws -> PairingPayload {
        try PairingPayload(
            pairing: pairing, macName: name, channelKey: channelKey.publicKey, identityKey: identity.publicKey, recordKey: recordKey.publicKey,
            secret: secret, relay: relay, addresses: addresses, expires: expires ?? Int64(Date().timeIntervalSince1970) + 300)
    }

    // MARK: - Loopback TCP

    /// Listens on 127.0.0.1 only (never another interface, which could ask the firewall), on a port of the system's.
    func listen() async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "test-mac.listener")
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: queue)
            let link = TCPLink(ready: connection)
            self?.state.withLock { $0.links.append(link) }
            Task { await self?.serve(link) }
        }
        let ready = Inbox<UInt16>()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { ready.push(port) }
            if case .failed = state { ready.finish() }
        }
        listener.start(queue: queue)
        self.listener = listener
        guard let port = try await ready.next(within: .seconds(20)) else { throw LinkError.closed }
        self.port = port
        return "127.0.0.1:\(port)"
    }

    var endpoint: NWEndpoint { .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!) }

    // MARK: - The relay

    /// Registers a pairing at the relay, connects as its Mac, and opens the join window for this secret.
    func joinRelay(_ url: URL) async throws {
        let build = RelayBuild("200")!
        let pairing = try await RelayClient.register(relay: url, build: build, relayKey: RelaySigner(relayKey))
        state.withLock { $0.pairing = pairing }
        let client = try RelayClient(relay: url, role: .mac(pairing), build: build, signer: RelaySigner(relayKey))
        relayClient = client
        let ready = Inbox<Bool>()
        Task {
            await client.start()
            for await event in client.events {
                switch event {
                case .macReady: ready.push(true)
                case let .phoneJoined(notice): self.state.withLock { $0.joined.append(notice) }
                case let .data(from?, bytes): self.relayData(bytes, from: from, client: client)
                case let .offline(device): self.state.withLock { $0.relayLinks.removeValue(forKey: device) }?.close()
                case let .disconnected(drop, _): print("test Mac: relay connection dropped: \(drop)")
                default: break
                }
            }
        }
        guard try await ready.next(within: .seconds(30)) != nil else { throw LinkError.closed }
        let token = PairingSecrets.joinToken(secret: secret, pairing: pairing)
        try await client.openJoin(tokenHash: PairingSecrets.joinTokenHash(token), expires: Int64(Date().timeIntervalSince1970 * 1000) + 300_000)
    }

    /// A phone's bytes under its slot or its id. A message of a handshake's first length begins a new channel: the
    /// phone pads every frame, so none of its transport messages is that short.
    private func relayData(_ bytes: Data, from device: DeviceID, client: RelayClient) {
        let (link, fresh): (MacRelayLink, Bool) = state.withLock { state in
            if bytes.count != 48, bytes.count != 96, let link = state.relayLinks[device] { return (link, false) }
            state.relayLinks[device]?.close()
            let link = MacRelayLink(client: client, to: device)
            state.relayLinks[device] = link
            state.links.append(link)
            return (link, true)
        }
        link.inbox.push(bytes)
        if fresh { Task { await self.serve(link) } }
    }

    // MARK: - What the test does to it

    /// Ends every channel at once: a TCP connection is closed under the phone, as a network that drops; a channel
    /// through the relay, whose socket the test cannot pull, ends with `bye`.
    func dropChannels() {
        let (links, channels) = state.withLock { state in
            defer { state.links = []; state.relayLinks = [:]; state.channels = [] }
            return (state.links, state.channels)
        }
        for channel in channels where channel.link is MacRelayLink { channel.close() }
        for link in links where !(link is MacRelayLink) { link.close() }
    }

    func revoke(_ device: DeviceID) {
        state.withLock { _ = $0.revoked.insert(device) }
    }

    /// A new home key, as after a revocation; sent to the phones attached now, and to the others at their next attach.
    func newHomeKey() -> HomeKey {
        let key = HomeKey.random()
        let channels = state.withLock { state in
            state.homeKey = key
            return state.channels
        }
        for channel in channels { try? channel.send(.homeKey(key)) }
        return key
    }

    var homeKey: HomeKey { state.withLock { $0.homeKey } }

    /// Sends one more of the engine's lines in the current session, as an event the engine sent.
    /// How many of the engine's lines the current session has sent.
    var sentInSession: Int {
        state.withLock { $0.current }.flatMap { session in engines.withLock { $0[session] } }?.sentCount ?? 0
    }

    func sendEvent(_ line: String) {
        let end = state.withLock { $0.current }.flatMap { session in engines.withLock { $0[session] } }
        end?.send(Data(line.utf8))
    }

    func stop() {
        listener?.cancel()
        if let relayClient { Task { await relayClient.stop() } }
        dropChannels()
    }

    // MARK: - Serving a channel

    func serve(_ link: any MessageLink) async {
        guard let first = await link.inbox.next() else { return }
        do {
            switch first.count {
            case 96: try await pair(link, first)
            case ChannelHandshake.connectionFirstMessageLength: try await connect(link, first)
            default: link.close()
            }
        } catch {
            link.close()
        }
    }

    private func pair(_ link: any MessageLink, _ first: Data) async throws {
        let pairing = pairing
        let handshake = try ChannelHandshake.pairingResponder(pairing: pairing, secret: secret, channelKey: channelKey)
        try handshake.readMessage(first)
        try await link.send(try handshake.writeMessage())
        let channel = MacChannel(try handshake.channel(), link)
        let binding = channel.channel.handshakeHash
        let challenge = Bytes.random(32)
        let rules = rules.withLock { $0 }
        try channel.send(.mac(MacProof.make(challenge: challenge, pairing: pairing, binding: binding, identity: rules.proofKey ?? identity)))

        guard let line = try await channel.nextLine(), case let .pair(claim) = try ControlLine.parse(line) else { return channel.close() }
        try claim.verify(pairing: pairing, binding: binding, handshakeChannelKey: channel.channel.remoteChannelKey)
        state.withLock { $0.claims.append(claim) }
        // The stand-in attestation must be over the client data hash the engine works out (3.3 step 4).
        if let attestation = claim.attestation, let keyId = claim.keyId {
            let expected = PairingSecrets.attestationClientDataHash(challenge: challenge, deviceKey: claim.device.deviceKey, binding: binding) + Data(base64Encoded: keyId)!
            guard attestation == expected else { return channel.close() }
        }
        let expected = PairingSecrets.digits(secret: secret, binding: binding)
        guard let shown = try await typed.next(within: .seconds(60)), PairingSecrets.digitsMatch(rules.type(shown), expected) else {
            return channel.close()
        }
        if let why = rules.refusePairing {
            return try channel.refusePairing(why)
        }
        if let line = rules.refusePairingLine {
            try channel.send(line: line)
            return channel.close()
        }
        let device = DeviceID.random()
        if let relayClient, let link = link as? MacRelayLink {
            // The key and the App Attest key id from the claim the engine verified, never from the relay's notice.
            try await relayClient.addDevice(device, deviceKey: claim.device.deviceKey, attestKeyId: AttestKeyID(claim.keyId ?? "") ?? AttestKeyID(bytes: Bytes.random(32))!)
            try await relayClient.closeJoin()
            link.target.withLock { $0 = device }
        }
        state.withLock { state in
            state.devices.append(Device(id: device, channelKey: claim.device.channelKey, deviceKey: claim.device.deviceKey, presenceKey: claim.device.presenceKey))
            state.paired.append(device)
        }
        try channel.send(.paired(try Paired(device: device, pairing: pairing, name: name, addresses: port > 0 ? ["127.0.0.1:\(port)"] : [], homeKey: state.withLock { $0.homeKey })))
        if link is MacRelayLink {
            // Through the relay the pairing channel now goes to the device's id, which the phone's own connection will
            // use next: a late `bye` of this channel would land in the next one and fail it. So no bye: the phone
            // closes its join link once paired.
            channel.finish()
        } else {
            _ = try? await channel.nextLine(within: .seconds(5))
            channel.close()
        }
    }

    private func connect(_ link: any MessageLink, _ first: Data) async throws {
        let (pairing, devices) = state.withLock { state in
            (state.pairing, state.devices.filter { !state.revoked.contains($0.id) })
        }
        // A revoked device's key is no longer on the list: its handshake fails, and it reads nothing.
        let (id, handshake) = try ChannelHandshake.respond(toFirstMessage: first, pairing: pairing, channelKey: channelKey, devices: devices.map { ($0.id, $0.channelKey) })
        guard let device = devices.first(where: { $0.id == id }) else { return link.close() }
        try await link.send(try handshake.writeMessage())
        let channel = MacChannel(try handshake.channel(), link)
        let binding = channel.channel.handshakeHash
        let challenge = Bytes.random(32)
        let rules = rules.withLock { $0 }
        state.withLock { state in
            state.challenges.append(challenge)
            state.channels.append(channel)
        }
        try channel.send(.mac(MacProof.make(challenge: challenge, pairing: pairing, binding: binding, identity: rules.proofKey ?? identity)))

        guard let line = try await channel.nextLine() else { return channel.close() }
        state.withLock { $0.attachLines.append(line) }
        guard case let .attach(claim) = try ControlLine.parse(line) else { return channel.close() }
        state.withLock { $0.attaches.append(claim) }
        // pi² Remote's own check first: an attach not signed by this device's key is closed with bye alone.
        do {
            try claim.verifyDevice(deviceKey: device.deviceKey, pairing: pairing, device: id, binding: binding)
        } catch {
            state.withLock { $0.refusedAttaches += 1 }
            return channel.close()
        }
        do {
            try claim.verify(
                deviceKey: device.deviceKey, presenceKey: device.presenceKey, pairing: pairing, device: id, binding: binding, challenge: challenge,
                now: Date().addingTimeInterval(rules.clockAhead))
        } catch let error as RemoteKitError where error.reason.contains("two minutes") {
            state.withLock { $0.refusedAttaches += 1 }
            return try channel.refuse(.clock)
        } catch {
            state.withLock { $0.refusedAttaches += 1 }
            return channel.close()
        }
        if rules.revokeWithLine {
            let revocation = try Revocation.make(pairing: pairing, device: id, identity: rules.revocationKey ?? identity)
            try channel.send(.revoked(revocation))
            return channel.close()
        }
        if let reason = rules.refuse {
            state.withLock { $0.refusedAttaches += 1 }
            return try channel.refuse(reason)
        }

        let resumed: (SessionID, UInt64)? = {
            guard rules.resumes, let session = claim.session, let received = claim.received, engines.withLock({ $0[session] }) != nil else { return nil }
            return (session, received)
        }()
        let session = resumed?.0 ?? SessionID("s\(Int.random(in: 1...999_999))")!
        state.withLock { state in
            state.attachedCount += 1
            state.current = session
        }
        try channel.send(.attached(Attached(session: session, resume: resumed != nil)))
        // The home key on every attach (remotekit.md, "The home key").
        try channel.send(.homeKey(state.withLock { $0.homeKey }))
        channel.channel.maxLineLength = Lines.defaultMaxLength

        let end: EngineEnd
        if let resumed, let kept = engines.withLock({ $0[session] }) {
            end = kept
            end.resume(on: channel, from: resumed.1)
        } else {
            end = EngineEnd(session: session, mac: self)
            engines.withLock { $0[session] = end }
            await end.begin(on: channel)
        }
        // The phone's lines, to the engine, until the channel ends.
        while let line = try? await channel.nextLine() {
            if case .sessionEnd? = try? ControlLine.parse(line) {
                state.withLock { $0.sessionEnds += 1 }
                break
            }
            await end.request(line)
        }
        channel.close()
    }

    fileprivate func requested(_ method: String) {
        state.withLock { $0.requests.append(method) }
    }
}

/// The engine behind the test Mac for one session: the recorded session's events, then answers as the replay gives
/// them. Every line it sends is kept, so that a resume serves what the phone had not had.
final class EngineEnd: @unchecked Sendable {
    let session: SessionID
    private weak var mac: TestMac?
    /// The channel the session is on, and the lines sent in it: changed together, so that a resume's lines and new
    /// ones are sealed in order.
    private let state = Mutex<(channel: MacChannel?, lines: [Data])>((nil, []))
    @MainActor private var replay: ReplayTransport?

    init(session: SessionID, mac: TestMac) {
        self.session = session
        self.mac = mac
    }

    func begin(on channel: MacChannel) async {
        state.withLock { $0.channel = channel }
        await MainActor.run {
            let replay = ReplayTransport.recording()!
            self.replay = replay
            replay.start { [weak self] event in
                guard case let .received(data) = event else { return }
                for line in data.split(separator: 0x0A) where !line.isEmpty { self?.send(Data(line)) }
            }
        }
    }

    func resume(on channel: MacChannel, from received: UInt64) {
        state.withLock { state in
            state.channel = channel
            for line in state.lines.dropFirst(Int(received)) { try? channel.send(line: line) }
        }
    }

    var sentCount: Int { state.withLock { $0.lines.count } }

    func send(_ line: Data) {
        state.withLock { state in
            state.lines.append(line)
            try? state.channel?.send(line: line)
        }
    }

    func request(_ line: Data) async {
        if let method = (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["method"] as? String { mac?.requested(method) }
        await MainActor.run { replay?.send(line + Data([0x0A])) }
    }
}

/// The Mac's end of one channel: sealing and writing in order, through one writer, and reading lines.
final class MacChannel: Sendable {
    let channel: Channel
    let link: any MessageLink
    private let order = Mutex(())
    private let outgoing = Inbox<Data>()

    init(_ channel: Channel, _ link: any MessageLink) {
        self.channel = channel
        self.link = link
        let outgoing = outgoing
        // The relay closes an end past 100 messages a second with `busy` (relay/src/limits.ts), and each of the
        // engine's lines is a transport message of its own: through the relay this Mac keeps under 70 a second.
        let paced = link is MacRelayLink
        Task {
            while let message = await outgoing.next() {
                guard (try? await link.send(message)) != nil else { break }
                if paced { try? await Task.sleep(for: .milliseconds(15)) }
            }
            try? await Task.sleep(for: .milliseconds(100))
            link.close()
        }
    }

    func send(_ line: ControlLine) throws {
        try send(line: line.line)
    }

    func send(line: Data) throws {
        try order.withLock { _ in
            for message in try channel.seal(line: line) { outgoing.push(message) }
        }
    }

    /// The `pairRefused` line and `bye`, then the link closes.
    func refusePairing(_ why: PairRefusal.Why) throws {
        try order.withLock { _ in
            for message in try channel.sealPairRefusal(PairRefusal(why)) { outgoing.push(message) }
        }
        outgoing.finish()
    }

    /// The `refused` line and `bye`, then the link closes.
    func refuse(_ reason: Refusal.Reason) throws {
        try order.withLock { _ in
            for message in try channel.sealRefusal(Refusal(reason)) { outgoing.push(message) }
        }
        outgoing.finish()
    }

    func nextLine(within limit: Duration = .seconds(3600)) async throws -> Data? {
        while let message = try await link.inbox.next(within: limit) {
            switch try channel.open(message) {
            case let .line(line)?: return line
            case .bye?: return nil
            default: continue
            }
        }
        return nil
    }

    /// What is queued goes, then the link closes, with no `bye`.
    func finish() {
        outgoing.finish()
    }

    /// `bye`, then the link closes once it has gone.
    func close() {
        order.withLock { _ in
            if let bye = try? channel.sealBye() { outgoing.push(bye) }
        }
        outgoing.finish()
    }
}

/// The Mac's link to one device through the relay.
final class MacRelayLink: MessageLink {
    let inbox = Inbox<Data>()
    let target: Mutex<DeviceID>
    private let client: RelayClient

    init(client: RelayClient, to device: DeviceID) {
        self.client = client
        target = Mutex(device)
    }

    func send(_ message: Data) async throws {
        guard !inbox.isFinished else { throw LinkError.closed }
        try await client.send(message, to: target.withLock { $0 })
    }

    func close() { inbox.finish() }
}
