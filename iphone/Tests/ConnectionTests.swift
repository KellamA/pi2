
import CryptoKit
import EngineKit
import Foundation
import Network
import RemoteKit
import Testing
@testable import pi2

/// The connection after pairing (docs/iphone.md 3.4, 4.3, 5.8; #680), between the phone's `RemoteConnection` and a Mac
/// made of real RemoteKit over loopback TCP: attach with both signatures, the Mac's identity checked against what pairing
/// kept, the engine's lines carried to EngineKit's client from the recorded session, a resume on a new channel, and
/// each refusal as the contract says, the relay's words among them.
@MainActor
@Suite(.serialized)
struct ConnectionTests {
    struct PairedPhone {
        let mac: TestMac
        let keys: MemoryKeyStore
        let store: MemoryPairingStore
        let record: PairingRecord
    }

    static func paired(_ rules: TestMac.Rules = TestMac.Rules()) async throws -> PairedPhone {
        let mac = TestMac()
        let keys = MemoryKeyStore(), store = MemoryPairingStore()
        let record = try await PairingTests.pair(mac, keys: keys, store: store)
        mac.rules.withLock { $0 = rules }
        return PairedPhone(mac: mac, keys: keys, store: store, record: record)
    }

    static func connection(_ paired: PairedPhone, routes: Routes = PairingTests.routes()) throws -> RemoteConnection {
        let connection = try RemoteConnection(record: paired.record, keys: try #require(try paired.keys.keys()), keyStore: paired.keys, store: paired.store, routes: routes)
        connection.backoff = RelayBackoff(first: 100, longest: 400)
        return connection
    }

    static func isConnected(_ connection: RemoteConnection) -> Bool {
        if case .connected = connection.connection { true } else { false }
    }

    @Test func attachesAndCarriesTheEngine() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired)
        let app = AppSession()
        app.start(connection.transport(), as: .connecting)
        #expect(connection.connection == .connecting)
        connection.start()
        defer { connection.stop() }

        #expect(await Wait.until { connection.connection == .connected(.direct, relayReachable: false) }, "connected straight to the Mac's address; the relay is not reachable here")
        #expect(await Wait.until { !app.engine.projects.isEmpty }, "the client reads the recorded session's greeting over the channel")
        #expect(app.engine.status == .connected)
        #expect(await Wait.until { app.engine.projects.count == 2 })
        #expect(app.engine.projects.map(\.name).sorted() == ["Demo project", "Demo project 2"], "\(app.engine.projects.map(\.name))")

        // The attach the Mac checked: both signatures, this channel, its challenge, a fresh session.
        let attach = try #require(paired.mac.state.withLock { $0.attaches.first })
        #expect(attach.session == nil && attach.received == nil)
        let kept = try #require(paired.keys.software)
        #expect(kept.softwarePresence.signatures.withLock { $0 } == 1, "the presence key signed the attach")

        // A request goes over the channel and its answer comes back, as from the engine.
        let orchestrator = try #require(app.engine.projects.first { $0.name == "Demo project" }?.conversation)
        app.engine.openConversation(orchestrator)
        #expect(await Wait.until { app.engine.open[orchestrator]?.items.isEmpty == false })
        #expect(paired.mac.state.withLock { $0.requests.contains("conversation.open") })
    }

    @Test func resumesTheSessionOnANewChannel() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired)
        let app = AppSession()
        let transport = connection.transport()
        app.start(transport, as: .connecting)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { !app.engine.projects.isEmpty })
        // Every line the Mac sent has come, so that the count the resume names is the whole of it.
        #expect(await Wait.until { transport.received > 0 && Int(transport.received) == paired.mac.sentInSession })
        let had = transport.received

        paired.mac.dropChannels()
        #expect(await Wait.until { paired.mac.state.withLock { $0.attachedCount } == 2 }, "the phone attaches again on a new channel")
        let resume = try #require(paired.mac.state.withLock { $0.attaches.last })
        let first = try #require(paired.mac.state.withLock { $0.attaches.first })
        #expect(resume.session != nil, "with the session to resume")
        #expect(resume.received == had, "and the count of lines it had")
        #expect(resume.binding != first.binding && resume.challenge != first.challenge, "a new signature, over this channel and this challenge")
        #expect(await Wait.until { Self.isConnected(connection) })
        #expect(connection.transport() === transport, "the same session, so the same transport: no new greeting")
        #expect(app.engine.status == .connected)

        paired.mac.sendEvent(#"{"event":"pi2-test","n":1}"#)
        #expect(await Wait.until { transport.received == had + 1 }, "lines go on in the resumed session")
    }

    @Test func aSessionTheMacCannotResumeStartsAfresh() async throws {
        let paired = try await Self.paired(TestMac.Rules(resumes: false))
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired)
        let first = connection.transport()
        let app = AppSession()
        app.start(first, as: .connecting)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { !app.engine.projects.isEmpty })
        paired.mac.dropChannels()
        #expect(await Wait.until { first.ended != nil }, "resume: false ends the session's transport, as an engine that restarted")
        let next = connection.transport()
        #expect(next !== first)
        app.start(next, as: .connecting)
        #expect(await Wait.until { next.received > 0 && app.engine.status == .connected }, "the next session's greeting comes on its own transport")
    }

    @Test func homeIsFoundByItsTagAlone() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        var routes = PairingTests.routes()
        routes.homeFinder = TagFinder(endpoint: paired.mac.endpoint, advertised: HomeTag.tag(macChannelKey: paired.mac.channelKey.publicKey, pairing: paired.mac.pairing, date: Date()))
        // No address kept, so only the finder can reach the Mac.
        var record = paired.record
        record.addresses = []
        let connection = try RemoteConnection(record: record, keys: try #require(try paired.keys.keys()), keyStore: paired.keys, store: paired.store, routes: routes)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { connection.connection == .connected(.home, relayReachable: false) })

        let mac = try record.mac()
        #expect(BonjourHomeFinder.recognises(version: "2", tag: HomeTag.tag(macChannelKey: mac.channelKey, pairing: mac.pairing, date: Date()), macChannelKey: mac.channelKey, pairing: mac.pairing))
        #expect(!BonjourHomeFinder.recognises(version: "2", tag: HomeTag.tag(macChannelKey: mac.channelKey, pairing: .random(), date: Date()), macChannelKey: mac.channelKey, pairing: mac.pairing), "another pairing's tag is another Mac")
        #expect(!BonjourHomeFinder.recognises(version: "1", tag: HomeTag.tag(macChannelKey: mac.channelKey, pairing: mac.pairing, date: Date()), macChannelKey: mac.channelKey, pairing: mac.pairing))
        #expect(!BonjourHomeFinder.recognises(version: "2", tag: nil, macChannelKey: mac.channelKey, pairing: mac.pairing))
    }

    @Test func aMacWithAnotherIdentityGetsNoAttach() async throws {
        let paired = try await Self.paired(TestMac.Rules(proofKey: P256.Signing.PrivateKey()))
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { connection.problem == .macNotProved })
        #expect(!Self.isConnected(connection))
        #expect(paired.mac.state.withLock { $0.attaches.isEmpty }, "nothing signed is sent to it")
        #expect(try paired.store.load() != nil, "and nothing is forgotten")
    }

    @Test func aReplayedAttachIsRefused() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired)
        connection.start()
        #expect(await Wait.until { Self.isConnected(connection) })
        connection.stop()
        let captured = try #require(paired.mac.state.withLock { $0.attachLines.first })

        // Whoever holds the phone's channel key (in the Keychain, not the Secure Enclave) makes a new channel and sends
        // the attach it saw before: it names another channel's binding and challenge.
        let keys = try #require(paired.keys.software)
        let mac = try paired.record.mac()
        let link = try await TCPLink.connect(to: paired.mac.endpoint, within: .seconds(10))
        let handshake = try ChannelHandshake.connection(initiator: true, pairing: mac.pairing, device: mac.device, channelKey: keys.channel, remoteChannelKey: mac.channelKey)
        let channel = try await OpenChannel.open(handshake, over: link, path: .direct)
        _ = try await channel.nextLine(within: .seconds(10))
        let refusedBefore = paired.mac.state.withLock { $0.refusedAttaches }
        try channel.send(line: captured)
        #expect(try await channel.nextLine(within: .seconds(10)) == nil, "no attached: the channel closes")
        #expect(paired.mac.state.withLock { $0.refusedAttaches } == refusedBefore + 1)
        #expect(paired.mac.state.withLock { $0.attachedCount } == 1)
    }

    @Test func aRevokedDeviceReadsNothingAndForgetsNothing() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { Self.isConnected(connection) })
        paired.mac.revoke(try #require(DeviceID(paired.record.device)))
        paired.mac.dropChannels()
        #expect(await Wait.until { if case .outOfReach = connection.connection { true } else { false } }, "its handshake fails: out of reach")
        try await Task.sleep(for: .seconds(1))
        #expect(paired.mac.state.withLock { $0.attachedCount } == 1, "never attached again")
        #expect(try paired.store.load() != nil && (try paired.keys.keys()) != nil, "a revocation not signed by the Mac is no revocation: nothing is forgotten")
    }

    @Test func theMacsSignedRevocationUnpairs() async throws {
        let paired = try await Self.paired(TestMac.Rules(revokeWithLine: true))
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired)
        connection.start()
        #expect(await Wait.until { connection.connection == .notPaired })
        #expect(connection.unpaired)
        #expect(try paired.store.load() == nil, "the record is deleted")
        #expect(try paired.keys.keys() == nil, "and the keys")
    }

    @Test func aRevocationSignedByAnotherKeyIsNotBelieved() async throws {
        let paired = try await Self.paired(TestMac.Rules(revokeWithLine: true, revocationKey: P256.Signing.PrivateKey()))
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { paired.mac.state.withLock { $0.attaches.count } >= 2 }, "it tries again, as after any channel that misbehaved")
        #expect(connection.connection != .notPaired)
        #expect(try paired.store.load() != nil && (try paired.keys.keys()) != nil)
    }

    @Test(arguments: [Refusal.Reason.update, .suspended, .presence])
    func aRefusalThatTryingAgainCannotHelpStopsIt(reason: Refusal.Reason) async throws {
        let paired = try await Self.paired(TestMac.Rules(refuse: reason))
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { connection.problem == ConnectionProblem(reason) })
        try await Task.sleep(for: .seconds(1))
        #expect(paired.mac.state.withLock { $0.attaches.count } == 1, "and it does not try again by itself")
        #expect(try paired.store.load() != nil)

        // The person's word: it tries again.
        paired.mac.rules.withLock { $0.refuse = nil }
        connection.tryAgain()
        #expect(await Wait.until { Self.isConnected(connection) })
    }

    @Test func theClockRule() async throws {
        // The Mac's clock three minutes ahead: the attach's `at`, by the phone's clock, is outside the two minutes.
        let paired = try await Self.paired(TestMac.Rules(clockAhead: 180))
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { connection.problem == .clock })
        try await Task.sleep(for: .seconds(1))
        #expect(paired.mac.state.withLock { $0.attaches.count } == 1, "each refusal counts towards a suspension: no retry by itself")

        // Within the two minutes, it attaches.
        paired.mac.rules.withLock { $0.clockAhead = 90 }
        connection.tryAgain()
        #expect(await Wait.until { Self.isConnected(connection) })
    }

    @Test func noSessionNoAttach() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        try #require(paired.keys.software).softwarePresence.open.withLock { $0 = false }
        let connection = try Self.connection(paired)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { connection.problem == .faceID(.sessionNotOpen) })
        #expect(paired.mac.state.withLock { $0.attaches.isEmpty }, "no attach without the presence signature")
    }

    @Test func theSessionsEndIsSaid() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired)
        connection.start()
        #expect(await Wait.until { Self.isConnected(connection) })
        connection.stop()
        #expect(await Wait.untilAsync { paired.mac.state.withLock { $0.sessionEnds } == 1 }, "sessionEnd on the channel (4.5)")
        #expect({ if case .outOfReach = connection.connection { true } else { false } }())
    }

    // MARK: - A relay that lies

    @Test(arguments: ["left", "removed", "not-listed", "deleted", "unknown-pairing"])
    func aRelaysStopIsShownAndNothingIsForgotten(word: String) async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        var routes = PairingTests.routes()
        let relay = LyingRelay(.refuse(word))
        routes.relayConnector = relay
        var record = paired.record
        record.relay = "wss://relay.example.dev/v1"
        let connection = try RemoteConnection(record: record, keys: try #require(try paired.keys.keys()), keyStore: paired.keys, store: paired.store, routes: routes)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { connection.problem == .relaySaid(word) }, "the relay's word is shown")
        #expect(await Wait.until { connection.connection == .connected(.direct, relayReachable: false) }, "and the home path still reaches the Mac")
        #expect(try paired.store.load() != nil && (try paired.keys.keys()) != nil, "nothing is forgotten, wiped or paired again on the relay's word")
        #expect(relay.connections.withLock { $0 } == 1, "the relay is not asked again until the next start")
    }

    @Test(arguments: [#"{"anotherMac":{}}"#, #"{"held":{"device":"dev_AQEBAQEBAQEBAQEBAQEBAQ","until":1800000001000}}"#, #"{"left":{"device":"dev_AQEBAQEBAQEBAQEBAQEBAQ"}}"#])
    func aMacsNoticeSentToThePhoneIsNotBelieved(lie: String) async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        var routes = PairingTests.routes()
        var options = RelayOptions()
        options.backoff = RelayBackoff(first: 50, longest: 100)
        routes.relayOptions = options
        let relay = LyingRelay(.readyThenSay(lie))
        routes.relayConnector = relay
        var record = paired.record
        record.relay = "wss://relay.example.dev/v1"
        let connection = try RemoteConnection(record: record, keys: try #require(try paired.keys.keys()), keyStore: paired.keys, store: paired.store, routes: routes)
        connection.start()
        defer { connection.stop() }
        // A notice no relay sends a phone: the client takes the relay for broken and connects again, no more.
        #expect(await Wait.untilAsync { relay.connections.withLock { $0 } >= 3 })
        #expect(await Wait.until { Self.isConnected(connection) })
        #expect(connection.problem == nil)
        #expect(try paired.store.load() != nil && (try paired.keys.keys()) != nil)
    }

    @Test func unpairingDoesNotWaitForTheRelaysAnswer() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        var routes = PairingTests.routes()
        routes.relayConnector = LyingRelay(.readyThenSilent)
        var record = paired.record
        record.relay = "wss://relay.example.dev/v1"
        let connection = try RemoteConnection(record: record, keys: try #require(try paired.keys.keys()), keyStore: paired.keys, store: paired.store, routes: routes)
        connection.start()
        #expect(await Wait.until { connection.connection == .connected(.direct, relayReachable: true) }, "the relay says it is ready")
        let started = ContinuousClock.now
        await connection.unpairHere()
        #expect(ContinuousClock.now - started < .seconds(2), "a leave the relay never answers holds nothing up")
        #expect(connection.connection == .notPaired)
        #expect(try paired.store.load() == nil && (try paired.keys.keys()) == nil)
    }

    @Test func everyProblemHasWordsOfItsOwn() {
        let problems: [ConnectionProblem] = [.update, .suspended, .presence, .clock, .faceID(.sessionNotOpen), .faceID(.faceIDNotPassed), .macNotProved, .relaySaid("left"), .relaySaid("update-required"), .relaySaid("new-word")]
        let words = problems.map(\.words)
        #expect(Set(words).count == words.count)
        #expect(words.allSatisfy { $0.hasSuffix(".") })
    }
}

/// Bonjour as the test plays it: one service, with the TXT record pi² Remote would give it, found only if its tag is
/// this pairing's.
struct TagFinder: HomeFinder {
    let endpoint: NWEndpoint
    let advertised: String

    func find(macChannelKey: Curve25519.KeyAgreement.PublicKey, pairing: PairingID) -> Inbox<NWEndpoint> {
        let found = Inbox<NWEndpoint>()
        if BonjourHomeFinder.recognises(version: "2", tag: advertised, macChannelKey: macChannelKey, pairing: pairing) { found.push(endpoint) }
        return found
    }
}
