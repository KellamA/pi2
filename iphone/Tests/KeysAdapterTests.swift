
import CryptoKit
import Foundation
import RemoteKit
import Testing
@testable import pi2

/// Keys/ as pairing and the connection use it (#680, `Connection/KeysAdapter.swift`): the real `PhoneKeys`, `DeviceKey`
/// and `PresenceSession`, in software and in memory (`MemoryKeychain`, `FakeFaceID` from KeysTests), checked against
/// RemoteKit's own verifiers, and a pairing and an attach with the test Mac over loopback TCP made with them.
@MainActor
@Suite(.serialized)
struct KeysAdapterTests {
    static func keyring(_ keychain: any KeychainStore = MemoryKeychain(), faceID: FakeFaceID = FakeFaceID()) -> PhoneKeyring {
        PhoneKeyring(keys: PhoneKeys(keychain: keychain, secureEnclave: false), faceID: faceID, attester: NoAttester())
    }

    @Test func theDeviceKeysRawSignaturesAreWhatRemoteKitVerifies() async throws {
        let keyring = Self.keyring()
        let signer = try DeviceStatementSigner(try await keyring.makeDeviceKey())
        let statement = try SignedStatement.make(.object([("v", .integer(2)), ("kind", .string("pair"))]), signer: signer)
        #expect(statement.signature.count == 64)
        #expect(statement.isSigned(by: signer.publicKey), "64 raw bytes, r then s, as RemoteKit's verifier reads them")
        #expect(!statement.isSigned(by: P256.Signing.PrivateKey().publicKey))
        #expect(signer.publicKey.derRepresentation == (try keyring.keys.deviceKey())?.publicKeyDER)
    }

    @Test func aDeviceKeyGivingAnotherEncodingIsRefusedHere() throws {
        struct DERSigner: DeviceKeySigning {
            let key = P256.Signing.PrivateKey()
            var publicKeyDER: Data { key.publicKey.derRepresentation }
            func sign(_ data: Data) throws -> Data { try key.signature(for: data).derRepresentation }
        }
        let signer = try DeviceStatementSigner(DERSigner())
        #expect(throws: RemoteKitError.self) { try signer.sign(Data("x".utf8)) }
    }

    @Test func anAttachCarriesThePresenceSessionsSignature() async throws {
        let keyring = Self.keyring()
        _ = try await keyring.makeDeviceKey()
        let publicKeys = try await keyring.makePairingKeys()
        let keys = try #require(try await keyring.pairedKeys())
        let pairing = PairingID.random(), device = DeviceID.random(), binding = Bytes.random(32), challenge = Bytes.random(32)
        func attach() async throws -> AttachClaim {
            try await PresenceSignatures.attach(
                pairing: pairing, device: device, session: nil, received: nil, binding: binding, challenge: challenge, build: "1", at: Date(),
                deviceKey: keys.device, presence: keys.presence)
        }

        // No session: the presence key does not sign, and the connection hears it in its own terms.
        do {
            _ = try await attach()
            Issue.record("signed with no session open")
        } catch {
            #expect(PresenceError(error) == .sessionNotOpen)
        }

        await keyring.session.open()
        #expect(keyring.session.state == .open)
        let claim = try await attach()
        let deviceKey = try #require(PublicKeys.signingKey(fromBase64URL: Base64URL.encode(publicKeys.device)))
        let presenceKey = try #require(PublicKeys.signingKey(fromBase64URL: Base64URL.encode(publicKeys.presence)))
        try claim.verify(deviceKey: deviceKey, presenceKey: presenceKey, pairing: pairing, device: device, binding: binding, challenge: challenge)

        keyring.session.end(.lockButton)
        await #expect(throws: KeysError.sessionNotOpen) { _ = try await attach() }
    }

    @Test func attestationsAsTheRelayAndTheMacTakeThem() throws {
        let key = AttestKeyID(bytes: Bytes.random(32))!
        let attested = Attestation.appAttest(keyID: key.text, object: Data([1, 2, 3]))
        let relay = try #require(try attested.forRelay)
        #expect(relay.attestation == Data([1, 2, 3]) && relay.keyId == key)
        #expect(try attested.forPair.keyId == key.text)
        #expect(try Attestation.noneSimulator.forRelay == nil, "the relay's join takes none")
        #expect(try Attestation.noneSimulator.forPair.object == nil)
        #expect(throws: KeysError.self) { _ = try Attestation.appAttest(keyID: "not a key id", object: Data()).forRelay }
    }

    @Test func theMacsRecordGoesWithTheKeys() async throws {
        let keyring = Self.keyring()
        let store = KeychainPairingStore(keys: keyring.keys)
        let mac = TestMac()
        let paired = try Paired(device: .random(), pairing: mac.pairing, name: mac.name, addresses: ["127.0.0.1:9"], homeKey: .random())
        let record = PairingRecord(payload: try mac.payload(relay: PairingTests.noRelay, addresses: []), paired: paired, at: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(record)
        #expect(try store.load() == record)
        try keyring.wipe()
        #expect(try store.load() == nil, "one wipe removes the record with the keys")
    }

    /// Pairing and an attach with the keyring itself, over loopback TCP with the test Mac.
    @Test func pairsAndAttachesWithTheRealKeys() async throws {
        try await Self.pairAndAttach(Self.keyring())
    }

    #if targetEnvironment(simulator)
    /// The same with the keys where this simulator build keeps them (`PhoneKeys.live()`: the Keychain, or the key file
    /// an unsigned build falls back to) and the simulator's own App Attest, which has none.
    @Test func pairsAndAttachesWithTheSimulatorsKeys() async throws {
        let keys = PhoneKeys.live()
        let keyring = PhoneKeyring(keys: keys, faceID: FakeFaceID(), attester: AppAttest.live())
        try keyring.wipe()
        defer { try? keyring.wipe() }
        try await Self.pairAndAttach(keyring)
    }
    #endif

    static func pairAndAttach(_ keyring: PhoneKeyring) async throws {
        let mac = TestMac()
        defer { mac.stop() }
        let address = try await mac.listen()
        let store = KeychainPairingStore(keys: keyring.keys)
        let flow = PairingFlow(needs: PairingFlow.Needs(keyStore: keyring, attester: keyring.attester, store: store, phone: .test, routes: PairingTests.routes()))
        flow.scanned(try mac.payload(relay: PairingTests.noRelay, addresses: [address]).text)
        #expect(await Wait.until { if case .digits = flow.step { true } else { false } })
        guard case let .digits(digits, _, _) = flow.step else { return }
        mac.typed.push(digits)
        #expect(await Wait.until { flow.step == .paired(mac: mac.name) })
        let claim = try #require(mac.state.withLock { $0.claims.first })
        #expect(claim.device.deviceKey.derRepresentation == (try keyring.keys.deviceKey())?.publicKeyDER)
        #expect(claim.attestation == nil, "the simulator's App Attest is none, and so is this keyring's")
        #expect(try store.load() != nil, "the record is kept with the keys")

        await keyring.session.open()
        let connection = try #require(await RemoteConnection.paired(keyStore: keyring, store: store, routes: PairingTests.routes()))
        let app = AppSession()
        app.start(connection.transport(), as: .connecting)
        connection.start()
        defer { connection.stop() }
        #expect(await Wait.until { connection.connection == .connected(.direct, relayReachable: false) })
        #expect(await Wait.until { app.engine.projects.count == 2 }, "the engine's lines over the channel the real keys made")
        #expect(mac.state.withLock { $0.attaches.count } == 1)
    }
}
