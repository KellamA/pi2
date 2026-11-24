
import CryptoKit
import Foundation
import RemoteKit
import Testing
@testable import pi2

/// The proof through the local relay (#680; docs/iphone.md 10): the relay's own code on this computer, started only by
/// `relay/`'s scripts on 127.0.0.1 (scripts/relay-protocol-test's way, with App Attest's stand-in that takes exactly the
/// join's client data hash), a Mac made of real RemoteKit registered there, and the phone's code pairing through the
/// join and then attaching as itself, the engine's lines from the recorded session. Run only when `PI2_RELAY` names the
/// relay (`TEST_RUNNER_PI2_RELAY=ws://127.0.0.1:<port>/v1` for xcodebuild).
@MainActor
@Suite(.serialized, .enabled(if: TestPlaces.relay != nil, "PI2_RELAY names no local relay"))
struct RelayPairingTests {
    static var relay: URL? { TestPlaces.relay }

    static func routes() -> Routes {
        var routes = Routes()
        routes.homeFinder = nil
        var options = RelayOptions()
        options.backoff = RelayBackoff(first: 200, longest: 2_000)
        options.answerWithin = 20_000
        routes.relayOptions = options
        return routes
    }

    @Test func pairsAndAttachesThroughTheLocalRelay() async throws {
        let url = try #require(Self.relay)
        let mac = TestMac()
        defer { mac.stop() }
        try await mac.joinRelay(url)
        let keys = MemoryKeyStore(), store = MemoryPairingStore(), attester = StandInAttester()
        // No address: the relay is the only path.
        let payload = try mac.payload(relay: url.absoluteString, addresses: [])
        let typed = mac.typed
        let paths = PathsSeen()
        let record = try await PairingExchange(payload: payload, keyStore: keys, attester: attester, store: store, phone: .test, routes: Self.routes())
            .run(showDigits: { typed.push($0) }, reaching: { await paths.add($0) })
        #expect(await paths.all == [.relay])
        #expect(try store.load() == record)

        // Two App Attest keys, one for the relay's join and one for the Mac, never the same; the relay's stand-in took
        // the join's hash, which RemoteKit made from this phone's own device key.
        let attested = attester.keys.withLock { $0 }
        #expect(attested.count == 2 && attested[0] != attested[1])
        let notice = try #require(mac.state.withLock { $0.joined.first })
        let claim = try #require(mac.state.withLock { $0.claims.first })
        let kept = try #require(keys.software)
        #expect(notice.deviceKey.derRepresentation == kept.device.publicKey.derRepresentation, "the device key that joined is the phone's own")
        #expect(claim.device.deviceKey.derRepresentation == kept.device.publicKey.derRepresentation, "and the one in pair")
        #expect(notice.keyId == attested[0] && claim.keyId == attested[1].text)

        // Connected as itself through the relay, and the engine's lines over it.
        let connection = try RemoteConnection(record: record, keys: try #require(try keys.keys()), keyStore: keys, store: store, routes: Self.routes())
        connection.backoff = RelayBackoff(first: 100, longest: 500)
        let app = AppSession()
        let transport = connection.transport()
        app.start(transport, as: .connecting)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until(90) { connection.connection == .connected(.relay, relayReachable: true) })
        #expect(await Wait.until(60) { app.engine.projects.count == 2 })
        #expect(app.engine.projects.map(\.name).sorted() == ["Demo project", "Demo project 2"], "\(app.engine.projects.map(\.name))")

        // A drop, and the session resumed through the relay on a new channel, once every line the Mac sent has come.
        #expect(await Wait.until(60) { transport.received > 0 && Int(transport.received) == mac.sentInSession })
        let had = transport.received
        mac.dropChannels()
        #expect(await Wait.until(90) { mac.state.withLock { $0.attachedCount } == 2 })
        let attaches = mac.state.withLock { $0.attaches.map { "\($0.session?.text ?? "-") \($0.received.map(String.init) ?? "-")" } }
        #expect(mac.state.withLock { $0.attaches.last?.received } == had, "had \(had), attaches \(attaches)")
        #expect(await Wait.until(60) { Self.connected(connection) })
        #expect(connection.transport() === transport)
    }

    @Test func aCodeWithAnotherSecretIsRefusedAtTheJoin() async throws {
        let url = try #require(Self.relay)
        let mac = TestMac()
        defer { mac.stop() }
        try await mac.joinRelay(url)
        let real = try mac.payload(relay: url.absoluteString, addresses: [])
        let forged = try PairingPayload(
            pairing: real.pairing, macName: real.macName, channelKey: real.channelKey, identityKey: real.identityKey, recordKey: real.recordKey,
            secret: Bytes.random(32), relay: real.relay, addresses: [], expires: real.expires)
        let keys = MemoryKeyStore(), store = MemoryPairingStore()
        await #expect(throws: PairingExchange.Failure.relayRefused(RelayWord(word: "token"))) {
            _ = try await PairingExchange(payload: forged, keyStore: keys, attester: StandInAttester(), store: store, phone: .test, routes: Self.routes()).run(showDigits: { _ in })
        }
        #expect(try store.load() == nil && (try keys.keys()) == nil)
    }

    @Test func wrongDigitsThroughTheRelayPairNothing() async throws {
        let url = try #require(Self.relay)
        let mac = TestMac(rules: TestMac.Rules(type: { $0 == "123456" ? "654321" : "123456" }))
        defer { mac.stop() }
        try await mac.joinRelay(url)
        let keys = MemoryKeyStore(), store = MemoryPairingStore()
        let typed = mac.typed
        await #expect(throws: PairingExchange.Failure.macDidNotPair) {
            _ = try await PairingExchange(payload: try mac.payload(relay: url.absoluteString, addresses: []), keyStore: keys, attester: StandInAttester(), store: store, phone: .test, routes: Self.routes())
                .run(showDigits: { typed.push($0) })
        }
        #expect(try store.load() == nil)
    }

    static func connected(_ connection: RemoteConnection) -> Bool {
        if case .connected = connection.connection { true } else { false }
    }
}

actor PathsSeen {
    var all: [AppSession.Path] = []
    func add(_ path: AppSession.Path) { all.append(path) }
}
