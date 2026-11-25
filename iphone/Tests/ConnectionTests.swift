
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
        let record = try await PairingTests.pairForSetup(mac, keys: keys, store: store)
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

    /// What is wrong with the presence key's signatures, if anything: each must be over an attach, one for each channel
    /// whose proof the Mac sent (its challenge, which the Mac keeps before sending), and every attach the Mac read must be
    /// among them. One signature for one attempt, and one more for each attempt the phone gave up and made again on a new
    /// channel (an answer later than 3.4's ten seconds, on a runner that stalls). An attach given up on may never reach
    /// the Mac (a reset under a stall loses it, #910), so the count is not the Mac's.
    static func presenceSignedOncePerChannel(_ paired: PairedPhone) throws -> String? {
        let signed = try #require(paired.keys.software).softwarePresence.signed.withLock { $0 }
        let (challenges, attaches) = paired.mac.state.withLock { state in
            (Set(state.challenges.map(Base64URL.encode)), state.attaches.map { Data($0.statement.text.utf8) })
        }
        var seen = Set<String>()
        for text in signed {
            guard let fields = try? JSONSerialization.jsonObject(with: text) as? [String: Any], fields["kind"] as? String == "attach",
                  let challenge = fields["challenge"] as? String else { return "signed what is not an attach" }
            guard challenges.contains(challenge) else { return "signed an attach for a challenge the Mac never sent" }
            guard seen.insert(challenge).inserted else { return "signed twice for one channel" }
        }
        guard attaches.allSatisfy(signed.contains) else { return "an attach the Mac read was not signed by the presence key" }
        return nil
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
        let presence = try P256.Signing.ECDSASignature(rawRepresentation: attach.presence)
        #expect(kept.softwarePresence.publicKey.isValidSignature(presence, for: Data(attach.statement.text.utf8)), "the presence key signed the attach")
        #expect(try Self.presenceSignedOncePerChannel(paired) == nil, "once, and nothing else")

        // A request goes over the channel and its answer comes back, as from the engine.
        let orchestrator = try #require(app.engine.projects.first { $0.name == "Demo project" }?.conversation)
        app.engine.openConversation(orchestrator)
        #expect(await Wait.until { app.engine.open[orchestrator]?.items.isEmpty == false })
        #expect(paired.mac.state.withLock { $0.requests.contains("conversation.open") })
    }

    @Test func anAttachMadeAgainIsSignedAgain() async throws {
        // The Mac reads the first attach and closes the channel unanswered, as the phone sees an answer later than its ten
        // seconds: it attaches afresh on a new channel, and the presence key signs that attach too, once.
        let paired = try await Self.paired(TestMac.Rules(unanswered: 1))
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { connection.connection == .connected(.direct, relayReachable: false) })
        let attaches = paired.mac.state.withLock { $0.attaches }
        // Two at least: a runner that stalls may make the phone give up another.
        #expect(attaches.count >= 2 && attaches.allSatisfy { $0.session == nil }, "no session was attached before, so each is fresh")
        #expect(attaches.first?.binding != attaches.last?.binding, "the next on a new channel")
        #expect(try Self.presenceSignedOncePerChannel(paired) == nil)
        #expect((paired.keys.software?.softwarePresence.signed.withLock { $0.count } ?? 0) >= 2, "the one made again is signed again")
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

    // MARK: - The phone's own lines across a drop (#939)

    /// A phone attached through `paired`'s Mac, its client reading the session: the app, the transport and the connection.
    static func attached(_ paired: PairedPhone) async throws -> (AppSession, ChannelTransport, RemoteConnection) {
        let connection = try Self.connection(paired)
        let app = AppSession()
        let transport = connection.transport()
        app.start(transport, as: .connecting)
        connection.start()
        #expect(await Wait.until { !app.engine.projects.isEmpty && app.engine.status == .connected })
        return (app, transport, connection)
    }

    /// What came of a message sent, once something has.
    @MainActor final class Outcome {
        var value: EngineSession<MessageField>.SubmitOutcome?
        func callAsFunction() -> EngineSession<MessageField>.SubmitOutcome? { value }
    }

    /// Sends `text` with `EngineSession.submit`, as the message field does, and gives back its outcome once it has one.
    static func submit(_ text: String, through app: AppSession) -> Outcome {
        let outcome = Outcome()
        Task { outcome.value = await app.engine.submit(text, to: 1, steer: false) }
        return outcome
    }

    @Test func aLineCutMidwayIsSentAgainOnTheResumedChannel() async throws {
        // The channel drops after the first part of a message too long for one transport message went: the Mac never had
        // it whole, and never counted it. The session resumes, and the message is sent again on the new channel.
        let paired = try await Self.paired(TestMac.Rules(cutLines: 1, takesMessages: true))
        defer { paired.mac.stop() }
        let (app, transport, connection) = try await Self.attached(paired)
        defer { connection.stop() }

        let outcome = Self.submit(String(repeating: "a long message ", count: 20_000), through: app)
        #expect(await Wait.until { outcome() != nil }, "the call is answered, not left waiting until the session ends")
        #expect(outcome() == .sent)
        let (cut, attached, submits) = paired.mac.state.withLock { ($0.cut, $0.attachedCount, $0.submits) }
        #expect(cut == 1, "the first copy was cut part way")
        #expect(attached == 2 && connection.transport() === transport, "and the session resumed, on the same transport")
        #expect(submits.count == 1, "the copy sent again is the one the Mac took")
        #expect(app.engine.lastError == nil)
    }

    @Test func aLineTakenWholeButNotCountedIsSentAgainAndTakenOnce() async throws {
        // The Mac took the message whole, then the channel dropped before its ack: the phone cannot know it arrived, so
        // it sends it again, with the same request id, and the engine gives it the submission it already has.
        let paired = try await Self.paired(TestMac.Rules(dropAfterTaking: 1, takesMessages: true))
        defer { paired.mac.stop() }
        let (app, transport, connection) = try await Self.attached(paired)
        defer { connection.stop() }

        let outcome = Self.submit("hello across a drop", through: app)
        #expect(await Wait.until { outcome() != nil })
        #expect(outcome() == .sent)
        let (submits, submissions) = paired.mac.state.withLock { ($0.submits, $0.submissions) }
        #expect(submits.count == 2 && Set(submits).count == 1, "sent twice, with one request id: \(submits)")
        #expect(submissions.count == 1, "and taken once")
        #expect(connection.transport() === transport)
    }

    @Test func aLineTheMacCountedIsNotSentAgain() async throws {
        // The Mac acknowledged the message before the channel dropped: its answer comes on the resumed channel, and the
        // message is not sent again.
        let paired = try await Self.paired(TestMac.Rules(dropAfterAcking: 1, takesMessages: true))
        defer { paired.mac.stop() }
        let (app, _, connection) = try await Self.attached(paired)
        defer { connection.stop() }

        let outcome = Self.submit("counted before the drop", through: app)
        #expect(await Wait.until { outcome() != nil })
        #expect(outcome() == .sent)
        #expect(paired.mac.state.withLock { ($0.submits.count, $0.attachedCount) } == (1, 2), "sent once, answered on the resumed channel")
    }

    @Test func aLineCutEveryTimeGoesBackToTheField() async throws {
        // A Mac that cuts the message every time (a line pi² Remote cuts for its budget, #908): the phone tries three
        // times, then gives up, and the message goes back to the field with why.
        let paired = try await Self.paired(TestMac.Rules(cutLines: 100, takesMessages: true))
        defer { paired.mac.stop() }
        let (app, transport, connection) = try await Self.attached(paired)
        defer { connection.stop() }

        let outcome = Self.submit(String(repeating: "too long for this Mac ", count: 20_000), through: app)
        #expect(await Wait.until { outcome() != nil })
        #expect(outcome() == .refused, "refused, so that the message field gives the text back")
        #expect(paired.mac.state.withLock { ($0.cut, $0.submits.count) } == (EngineSession<MessageField>.cutTries, 0))
        #expect(app.engine.lastError?.contains("dropped") == true, "\(app.engine.lastError ?? "no words")")
        #expect(connection.transport() === transport && app.engine.status == .connected, "the session goes on")
    }

    @Test func homeIsFoundByItsTagAlone() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        var routes = PairingTests.routes()
        routes.homeFinder = TagFinder(endpoint: paired.mac.endpoint, advertised: HomeTag.tag(key: paired.mac.homeKey, pairing: paired.mac.pairing, date: Date()))
        // No address kept, so only the finder can reach the Mac.
        var record = paired.record
        record.addresses = []
        let connection = try RemoteConnection(record: record, keys: try #require(try paired.keys.keys()), keyStore: paired.keys, store: paired.store, routes: routes)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { connection.connection == .connected(.home, relayReachable: false) })

        let mac = try record.mac()
        #expect(BonjourHomeFinder.recognises(version: "2", tag: HomeTag.tag(key: mac.homeKey, pairing: mac.pairing, date: Date()), homeKey: mac.homeKey, pairing: mac.pairing))
        #expect(!BonjourHomeFinder.recognises(version: "2", tag: HomeTag.tag(key: mac.homeKey, pairing: .random(), date: Date()), homeKey: mac.homeKey, pairing: mac.pairing), "another pairing's tag is another Mac")
        #expect(!BonjourHomeFinder.recognises(version: "2", tag: HomeTag.tag(key: .random(), pairing: mac.pairing, date: Date()), homeKey: mac.homeKey, pairing: mac.pairing), "a tag under another home key, as a revoked phone's, is not this Mac's")
        #expect(!BonjourHomeFinder.recognises(version: "1", tag: HomeTag.tag(key: mac.homeKey, pairing: mac.pairing, date: Date()), homeKey: mac.homeKey, pairing: mac.pairing))
        #expect(!BonjourHomeFinder.recognises(version: "2", tag: nil, homeKey: mac.homeKey, pairing: mac.pairing))
    }

    @Test func theMacsNewHomeKeyIsKeptAndNeverReachesTheEngine() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        #expect(paired.record.homeKey == Base64URL.encode(paired.mac.homeKey.rawRepresentation), "the home key from paired is kept")
        let connection = try Self.connection(paired)
        let app = AppSession()
        let transport = connection.transport()
        app.start(transport, as: .connecting)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { Int(transport.received) == paired.mac.sentInSession && transport.received > 0 })
        let had = transport.received
        let key = paired.mac.newHomeKey()
        #expect(await Wait.until { (try? paired.store.load())?.homeKey == Base64URL.encode(key.rawRepresentation) }, "a new key is kept in place of the old")
        #expect(transport.received == had, "and is no line of the engine's")

        // The next search on the network goes by the new key's tag.
        paired.mac.dropChannels()
        #expect(await Wait.until { paired.mac.state.withLock { $0.attachedCount } == 2 })
        let mac = try #require(try paired.store.load()).mac()
        #expect(BonjourHomeFinder.recognises(version: "2", tag: HomeTag.tag(key: key, pairing: mac.pairing, date: Date()), homeKey: mac.homeKey, pairing: mac.pairing))
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

    /// A new presence key that waits to be accepted on the Mac (#891): offered, never attached with. Told it waits, the
    /// phone stops and says to accept it on the Mac, offers it again only at the person's word, and attaches under it at
    /// once when the Mac answers it accepted.
    @Test func aKeyThatWaitsIsOfferedAndNeverAttachedWith() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        let software = try #require(paired.keys.software)
        software.softwarePresence.waiting.withLock { $0 = true }
        let connection = try Self.connection(paired)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { connection.problem == .presenceKeyWaits })
        try await Task.sleep(for: .seconds(1))
        let (offers, attaches) = paired.mac.state.withLock { ($0.offers, $0.attaches) }
        #expect(offers.count == 1 && attaches.isEmpty, "one offer, no attach, and no retry by itself: \(offers.count) offers, \(attaches.count) attaches")
        let offer = try #require(offers.first)
        #expect(offer.presenceKey.derRepresentation == software.softwarePresence.publicKey.derRepresentation, "it offers the presence key the session signs with")
        #expect(software.softwarePresence.signed.withLock { $0 } == [Data(offer.statement.text.utf8)], "signed by it, under the session, over the offer's text alone")

        // The person's word: offered again, and still not attached with.
        connection.tryAgain()
        #expect(await Wait.until { paired.mac.state.withLock { $0.offers.count } == 2 })
        #expect(await Wait.until { connection.problem == .presenceKeyWaits })
        #expect(paired.mac.state.withLock { $0.attaches.isEmpty }, "no attach while the key waits")

        // Accepted on the Mac: the next offer is answered so, and the phone attaches at once, under the new key.
        paired.mac.rules.withLock { $0.offers = .accepted }
        connection.tryAgain()
        #expect(await Wait.until { Self.isConnected(connection) })
        #expect(paired.mac.state.withLock { ($0.offers.count, $0.attaches.count) } == (3, 1))
        #expect(try software.softwarePresence.presenceKeyWaits() == false, "the key no longer waits")
    }

    @Test func anOfferEndedWithNoWordStopsTrying() async throws {
        // A refused offer counts towards suspending the device: one that ends with no word is not tried again by itself.
        let paired = try await Self.paired(TestMac.Rules(offers: .nothing))
        defer { paired.mac.stop() }
        try #require(paired.keys.software).softwarePresence.waiting.withLock { $0 = true }
        let connection = try Self.connection(paired)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { connection.problem == .presenceKeyNotTaken })
        try await Task.sleep(for: .seconds(1))
        #expect(paired.mac.state.withLock { ($0.offers.count, $0.attaches.count) } == (1, 0))
    }

    @Test func aKeyThatDoesNotWaitIsNeverOffered() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { Self.isConnected(connection) })
        #expect(paired.mac.state.withLock { ($0.offers.count, $0.attaches.count) } == (0, 1), "it attaches, and offers nothing")
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

    /// With a slow link, each of the phone's sends waits first, as its writer does on a loaded runner: `stop` returns,
    /// the session's loop ends, and the Mac's lines still coming fail to open on the channel ended with `bye`, all before
    /// `sessionEnd` has gone. None of it may close the link under it (#888).
    @Test(arguments: [false, true])
    func theSessionsEndIsSaid(slowLink: Bool) async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        var routes = PairingTests.routes()
        if slowLink { routes.dialer = SlowDialer() }
        let connection = try Self.connection(paired, routes: routes)
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

    // MARK: - Two paths: the first channel, not the first link (#898)

    /// A connection with both paths: the home path's dial through `dialer`, and a relay that is `relay`.
    static func connection(_ paired: PairedPhone, relay: any RelayConnector, dialer: any Dialer) throws -> RemoteConnection {
        var routes = PairingTests.routes()
        routes.relayConnector = relay
        routes.dialer = dialer
        var record = paired.record
        record.relay = "wss://relay.example.dev/v1"
        let connection = try RemoteConnection(record: record, keys: try #require(try paired.keys.keys()), keyStore: paired.keys, store: paired.store, routes: routes)
        connection.backoff = RelayBackoff(first: 100, longest: 400)
        return connection
    }

    /// The relay is ready before the dial to the Mac at home has connected, so its link comes first, at once, at every
    /// attempt; but no answer comes through it, the Mac not being connected to it or the relay saying nothing. The home
    /// path's channel is the first to come, and the phone attaches there, once.
    @Test(arguments: ["macAway", "silent"])
    func aRelayWithNoAnswerDoesNotKeepThePhoneFromHome(relay: String) async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        let connector: any RelayConnector = relay == "silent" ? LyingRelay(.readyThenSilent) : PassingRelay(.away)
        let connection = try Self.connection(paired, relay: connector, dialer: LateDialer())
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { connection.connection == .connected(.direct, relayReachable: true) }, "\(connection.connection)")
        #expect(try Self.presenceSignedOncePerChannel(paired) == nil)
        #expect(paired.mac.state.withLock { $0.attachedCount } == 1, "one session, on the home path: the relay passes nothing to the Mac")
    }

    /// The relay passes the Mac's answer, but late: the home path's channel comes first and is attached, and the relay's,
    /// once its answer comes, is dropped with nothing signed on it. With home out of reach, the relay's is attached
    /// once its answer comes.
    @Test(arguments: [true, false])
    func aRelayThatAnswersLate(homeReachable: Bool) async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        let late: Duration = .seconds(4)
        let relay = PassingRelay(.connected(paired.mac, late: late))
        let connection = try Self.connection(paired, relay: relay, dialer: homeReachable ? LateDialer() : UnansweredDialer())
        connection.start()
        defer { connection.stop() }
        let path: AppSession.Path = homeReachable ? .direct : .relay
        #expect(await Wait.until { connection.connection == .connected(path, relayReachable: true) }, "\(connection.connection)")
        if homeReachable {
            // The Mac's proof on the relay's channel, which comes after the home path's attach, is answered by nothing.
            // (No channel through the relay at all, if the home path's came before the relay was ready, is fine too.)
            _ = await Wait.until(15) { paired.mac.state.withLock { $0.challenges.count } == 2 }
            try await Task.sleep(for: .seconds(1))
        }
        #expect(connection.connection == .connected(path, relayReachable: true))
        #expect(try Self.presenceSignedOncePerChannel(paired) == nil)
        #expect(paired.mac.state.withLock { [$0.attachedCount, $0.sessionEnds] as [Int] } == [1, 0], "one session, and none ended")
        if homeReachable {
            #expect(relay.fromPhone.withLock { $0 }.allSatisfy { $0 == 1 }, "the relay's channel carried the handshake's first message alone: no attach, no bye")
        }
    }

    @Test func homeOutOfReachAndTheRelayGood() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        let connection = try Self.connection(paired, relay: PassingRelay(.connected(paired.mac)), dialer: UnansweredDialer())
        let app = AppSession()
        app.start(connection.transport(), as: .connecting)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { connection.connection == .connected(.relay, relayReachable: true) }, "\(connection.connection)")
        #expect(await Wait.until { !app.engine.projects.isEmpty }, "the engine's lines come through the relay")
        #expect(try Self.presenceSignedOncePerChannel(paired) == nil)
        #expect(paired.mac.state.withLock { $0.attachedCount } == 1)
    }

    /// Both paths reach the Mac: whichever channel comes first is attached, once, and the other is dropped, with no
    /// attach and nothing the Mac takes for the session's end.
    @Test func bothPathsGood() async throws {
        let paired = try await Self.paired()
        defer { paired.mac.stop() }
        let relay = PassingRelay(.connected(paired.mac))
        let connection = try Self.connection(paired, relay: relay, dialer: TCPDialer())
        let app = AppSession()
        app.start(connection.transport(), as: .connecting)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { if case .connected(_, relayReachable: true) = connection.connection { true } else { false } }, "\(connection.connection)")
        #expect(await Wait.until { !app.engine.projects.isEmpty })
        try await Task.sleep(for: .seconds(1))
        #expect(Self.isConnected(connection))
        #expect(try Self.presenceSignedOncePerChannel(paired) == nil)
        #expect(paired.mac.state.withLock { [$0.attachedCount, $0.sessionEnds] as [Int] } == [1, 0], "one session, and none ended")
        if case .connected(.direct, _) = connection.connection {
            #expect(relay.fromPhone.withLock { $0 }.allSatisfy { $0 == 1 }, "the relay's channel carried the handshake's first message alone: no attach, no bye")
        }
    }

    @Test func everyProblemHasWordsOfItsOwn() {
        let problems: [ConnectionProblem] = [
            .update, .suspended, .presence, .clock, .faceID(.sessionNotOpen), .faceID(.faceIDNotPassed), .macNotProved, .presenceKeyWaits, .presenceKeyNotTaken,
            .relaySaid("left"), .relaySaid("update-required"), .relaySaid("new-word"),
        ]
        let words = problems.map(\.words)
        #expect(Set(words).count == words.count)
        #expect(words.allSatisfy { $0.hasSuffix(".") })
    }
}

/// TCP links whose sends each wait first: a phone whose writer gets its turn late.
struct SlowDialer: Dialer {
    func dial(_ endpoint: NWEndpoint, within limit: Duration) async throws -> any MessageLink {
        SlowLink(try await TCPDialer().dial(endpoint, within: limit))
    }
}

final class SlowLink: MessageLink {
    let link: any MessageLink
    var inbox: Inbox<Data> { link.inbox }

    init(_ link: any MessageLink) {
        self.link = link
    }

    func send(_ message: Data) async throws {
        try? await Task.sleep(for: .milliseconds(300))
        try await link.send(message)
    }

    func close() { link.close() }
}

/// TCP links that connect late: a dial to the Mac at home that takes longer than the relay takes to be ready (#898).
struct LateDialer: Dialer {
    var by: Duration = .milliseconds(300)

    func dial(_ endpoint: NWEndpoint, within limit: Duration) async throws -> any MessageLink {
        try await Task.sleep(for: by)
        return try await TCPDialer().dial(endpoint, within: limit)
    }
}

/// A home path whose dial nothing answers: it waits its whole limit, as a network with no way to the Mac.
struct UnansweredDialer: Dialer {
    func dial(_ endpoint: NWEndpoint, within limit: Duration) async throws -> any MessageLink {
        try await Task.sleep(for: limit)
        throw LinkError.timedOut
    }
}

/// Bonjour as the test plays it: one service, with the TXT record pi² Remote would give it, found only if its tag is
/// this pairing's.
struct TagFinder: HomeFinder {
    let endpoint: NWEndpoint
    let advertised: String

    func find(homeKey: HomeKey, pairing: PairingID) -> Inbox<NWEndpoint> {
        let found = Inbox<NWEndpoint>()
        if BonjourHomeFinder.recognises(version: "2", tag: advertised, homeKey: homeKey, pairing: pairing) { found.push(endpoint) }
        return found
    }
}
