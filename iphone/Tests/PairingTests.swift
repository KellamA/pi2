
import CryptoKit
import Foundation
import RemoteKit
import Testing
@testable import pi2

/// Pairing (docs/iphone.md 3.1, 3.3; #680) between the phone's code and a Mac made of real RemoteKit, over loopback TCP:
/// the payload read by RemoteKit's reader, the IKpsk2 exchange, the Mac's proof, `pair` with the attestation bound to
/// the device key, the digits typed on the Mac, `paired`; and every refusal, with nothing kept after one.
@MainActor
@Suite(.serialized)
struct PairingTests {
    /// Nothing listens on port 9 of this computer: the relay's join fails at once, and the home path is the one taken.
    static let noRelay = "ws://127.0.0.1:9/v1"

    static func routes() -> Routes {
        var routes = Routes()
        routes.homeFinder = nil
        routes.dialWithin = .seconds(10)
        routes.relayWithin = .seconds(3)
        return routes
    }

    static func exchange(_ mac: TestMac, payload: PairingPayload, keys: MemoryKeyStore, store: MemoryPairingStore, attester: any Attester = NoAttester()) -> PairingExchange {
        PairingExchange(payload: payload, keyStore: keys, attester: attester, store: store, phone: .test, routes: routes())
    }

    /// Pairs the phone with `mac` over loopback TCP, the person typing what the phone shows.
    static func pair(_ mac: TestMac, keys: MemoryKeyStore, store: MemoryPairingStore, attester: any Attester = NoAttester()) async throws -> PairingRecord {
        let address = try await mac.listen()
        let typed = mac.typed
        return try await exchange(mac, payload: try mac.payload(relay: noRelay, addresses: [address]), keys: keys, store: store, attester: attester)
            .run(showDigits: { typed.push($0) })
    }

    @Test func pairsOverLoopbackTCP() async throws {
        let mac = TestMac()
        defer { mac.stop() }
        let keys = MemoryKeyStore(), store = MemoryPairingStore()
        let record = try await Self.pair(mac, keys: keys, store: store)

        #expect(try store.load() == record, "the record is kept once paired")
        #expect(record.macName == mac.name)
        #expect(record.pairing == mac.pairing.text)
        #expect(record.macIdentityKey == PublicKeys.text(mac.identity.publicKey), "the Mac's identity key from the code is kept for every channel after")
        #expect(record.macChannelKey == PublicKeys.text(mac.channelKey.publicKey))
        let device = try #require(mac.state.withLock { $0.paired.first })
        #expect(record.device == device.text, "the device's id is the one `paired` gave")
        #expect(record.addresses == ["127.0.0.1:\(mac.port)"])

        let claim = try #require(mac.state.withLock { $0.claims.first })
        let kept = try #require(keys.software)
        #expect(claim.device.deviceKey.derRepresentation == kept.device.publicKey.derRepresentation, "pair names the device key made on scanning")
        #expect(claim.device.channelKey.rawRepresentation == kept.channel.publicKey.rawRepresentation)
        #expect(claim.device.presenceKey.derRepresentation == kept.presence.publicKey.derRepresentation)
        #expect(claim.attestation == nil && claim.keyId == nil, "a build without App Attest sends none, which only a throwaway copy's engine takes")
        #expect(claim.device.build.allSatisfy { $0.isNumber || $0 == "." }, "the build is digits and dots")
        #expect(claim.device.model.utf8.count <= 64)
        #expect(keys.deviceKeysMade.withLock { $0 } == 1)
    }

    @Test func theAttestationIsBoundToTheDeviceKeyAndThisChannel() async throws {
        let mac = TestMac()
        defer { mac.stop() }
        let keys = MemoryKeyStore(), store = MemoryPairingStore(), attester = StandInAttester()
        // The test Mac closes the channel unless the attestation is over SHA-256 of its challenge, the device key it was
        // given and the handshake hash (RemoteKit's attestationClientDataHash), so pairing at all shows the binding.
        _ = try await Self.pair(mac, keys: keys, store: store, attester: attester)
        let claim = try #require(mac.state.withLock { $0.claims.first })
        #expect(claim.keyId == attester.keys.withLock { $0.last?.text }, "the key attested is the one named")
        #expect(attester.hashes.withLock { $0.count } == 1, "one new App Attest key for the Mac; the relay's join was never reached")
    }

    @Test func wrongDigitsPairNothing() async throws {
        let mac = TestMac(rules: TestMac.Rules(type: { shown in shown == "000000" ? "000001" : "000000" }))
        defer { mac.stop() }
        let keys = MemoryKeyStore(), store = MemoryPairingStore()
        await #expect(throws: PairingExchange.Failure.macDidNotPair) {
            _ = try await Self.pair(mac, keys: keys, store: store)
        }
        #expect(try store.load() == nil, "nothing kept")
        #expect(try keys.keys() == nil, "the keys made for it are deleted")
        #expect(mac.state.withLock { $0.paired.isEmpty })
    }

    @Test func aMacThatCannotProveItselfGetsNothing() async throws {
        let mac = TestMac(rules: TestMac.Rules(proofKey: P256.Signing.PrivateKey()))
        defer { mac.stop() }
        let keys = MemoryKeyStore(), store = MemoryPairingStore()
        await #expect(throws: PairingExchange.Failure.macNotProved) {
            _ = try await Self.pair(mac, keys: keys, store: store)
        }
        #expect(mac.state.withLock { $0.claims.isEmpty }, "no claim is sent to a Mac whose proof is not the scanned identity key's")
        #expect(try store.load() == nil)
        #expect(try keys.keys() == nil)
    }

    @Test func aCodeOfAnotherSecretPairsNothing() async throws {
        let mac = TestMac()
        defer { mac.stop() }
        let address = try await mac.listen()
        let real = try mac.payload(relay: Self.noRelay, addresses: [address])
        // The Mac's channel key and pairing, but not its secret: the handshake fails on the pre-shared key.
        let forged = try PairingPayload(
            pairing: real.pairing, macName: real.macName, channelKey: real.channelKey, identityKey: real.identityKey, recordKey: real.recordKey,
            secret: Bytes.random(32), relay: real.relay, addresses: real.addresses, expires: real.expires)
        let keys = MemoryKeyStore(), store = MemoryPairingStore()
        await #expect(throws: PairingExchange.Failure.macDidNotPair) {
            _ = try await Self.exchange(mac, payload: forged, keys: keys, store: store).run(showDigits: { _ in })
        }
        #expect(try store.load() == nil)
    }

    @Test func nothingAnswersAndNothingIsKept() async throws {
        let mac = TestMac()
        let keys = MemoryKeyStore(), store = MemoryPairingStore()
        // An address where nothing listens, and a relay where nothing listens.
        let payload = try mac.payload(relay: Self.noRelay, addresses: ["127.0.0.1:9"])
        await #expect(throws: PairingExchange.Failure.unreachable) {
            _ = try await Self.exchange(mac, payload: payload, keys: keys, store: store).run(showDigits: { _ in })
        }
        #expect(try keys.keys() == nil)
    }

    @Test func noAppAttestMeansNoJoin() async throws {
        let mac = TestMac()
        let keys = MemoryKeyStore(), store = MemoryPairingStore()
        // A relay that answers the join's first messages, and no home path: a build without App Attest stops at the
        // attestation and says to pair at home.
        var routes = Self.routes()
        routes.relayConnector = ChallengingRelay()
        let payload = try mac.payload(relay: "wss://relay.example.dev/v1", addresses: [])
        await #expect(throws: PairingExchange.Failure.noAppAttest) {
            _ = try await PairingExchange(payload: payload, keyStore: keys, attester: NoAttester(), store: store, phone: .test, routes: routes).run(showDigits: { _ in })
        }
    }

    // MARK: - The flow the screens draw

    static func needs(_ keys: MemoryKeyStore, _ store: MemoryPairingStore, unpaired: @escaping @MainActor @Sendable () async -> Void = {}) -> PairingFlow.Needs {
        var needs = PairingFlow.Needs(keyStore: keys, attester: NoAttester(), store: store, phone: .test, routes: routes())
        needs.unpair = unpaired
        return needs
    }

    @Test func onlyRemoteKitsReaderDecidesWhatACodeIs() {
        let flow = PairingFlow(needs: Self.needs(MemoryKeyStore(), MemoryPairingStore()))
        flow.scanned("https://example.com/pair?v=2")
        #expect(flow.step == .failed(.notACode))
        flow.scanAgain()
        #expect(flow.step == .scanning)
        flow.scanned("pi2://pair?v=2&p=x")
        #expect(flow.step == .failed(.notACode))
    }

    @Test func anExpiredCodeIsSaidSo() throws {
        let flow = PairingFlow(needs: Self.needs(MemoryKeyStore(), MemoryPairingStore()))
        let mac = TestMac()
        flow.scanned(try mac.payload(relay: Self.noRelay, addresses: [], expires: Int64(Date().timeIntervalSince1970) - 1).text)
        #expect(flow.step == .failed(.expired))
    }

    @Test func theFlowShowsTheDigitsThenPaired() async throws {
        let mac = TestMac()
        defer { mac.stop() }
        let address = try await mac.listen()
        let keys = MemoryKeyStore(), store = MemoryPairingStore()
        let flow = PairingFlow(needs: Self.needs(keys, store))
        flow.scanned(try mac.payload(relay: Self.noRelay, addresses: [address]).text)
        #expect(await Wait.until { if case .digits = flow.step { true } else { false } })
        guard case let .digits(digits, name, path) = flow.step else { return }
        #expect(digits.count == 6 && digits.allSatisfy(\.isNumber))
        #expect(name == mac.name)
        #expect(path == .direct)
        mac.typed.push(digits)
        #expect(await Wait.until { flow.step == .paired(mac: mac.name) })
        #expect(flow.record != nil)
    }

    @Test func pairingAgainAsksAndUnpairsFirst() async throws {
        let keys = MemoryKeyStore(), store = MemoryPairingStore()
        let first = TestMac()
        defer { first.stop() }
        _ = try await Self.pair(first, keys: keys, store: store)
        let second = TestMac()
        defer { second.stop() }
        let address = try await second.listen()
        let unpaired = UnpairCount()
        let flow = PairingFlow(needs: Self.needs(keys, store, unpaired: { unpaired.count += 1 }))
        flow.scanned(try second.payload(relay: Self.noRelay, addresses: [address]).text)
        #expect(flow.step == .replace(current: first.name, new: second.name), "a paired phone asks before replacing its pairing")
        #expect(try store.load()?.pairing == first.pairing.text, "nothing changes until the person says yes")

        flow.replace()
        #expect(await Wait.until { if case .digits = flow.step { true } else { false } })
        #expect(unpaired.count == 1, "it unpairs itself first")
        guard case let .digits(digits, _, _) = flow.step else { return }
        second.typed.push(digits)
        #expect(await Wait.until { flow.step == .paired(mac: second.name) })
        #expect(try store.load()?.pairing == second.pairing.text)
    }

    @Test func keepingThePairingChangesNothing() async throws {
        let keys = MemoryKeyStore(), store = MemoryPairingStore()
        let first = TestMac()
        defer { first.stop() }
        let record = try await Self.pair(first, keys: keys, store: store)
        let flow = PairingFlow(needs: Self.needs(keys, store))
        flow.scanned(try TestMac().payload(relay: Self.noRelay, addresses: []).text)
        flow.scanAgain()
        #expect(try store.load() == record)
        #expect(try keys.keys() != nil)
    }

    @Test func everyFailureHasWordsOfItsOwn() {
        let failures: [PairingFailure] = [
            .notACode, .expired, .unreachable, .relayRefused("token"), .relayRefused("attestation"), .relayRefused("update-required"),
            .relayRefused("busy"), .relayRefused("something-new"), .noAppAttest, .macNotProved, .macDidNotPair, .attestation, .keys,
        ]
        let words = failures.map(\.words)
        #expect(Set(words).count == words.count)
        #expect(words.allSatisfy { !$0.isEmpty && $0.hasSuffix(".") })
    }
}

@MainActor
final class UnpairCount {
    var count = 0
}

/// A relay that answers a join's hello with a challenge and nothing more, for the attestation to be asked for.
final class ChallengingRelay: RelayConnector {
    func connect(to url: URL, pairing: PairingID?) async throws -> any RelaySocket { ChallengingSocket() }
}

final class ChallengingSocket: RelaySocket {
    private let frames = Inbox<RelayFrame>()

    func send(_ frame: RelayFrame) async throws {
        if case let .text(text) = frame, text.hasPrefix(#"{"hello""#) {
            frames.push(.text(JSON.text(.object([("challenge", .string(Base64URL.encode(Bytes.random(32))))]))))
        }
    }

    func receive() async throws -> RelayFrame {
        if let frame = await frames.next() { return frame }
        throw RelaySocketClosed()
    }

    func close() { frames.finish() }
}
