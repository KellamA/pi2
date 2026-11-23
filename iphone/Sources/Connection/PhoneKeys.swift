
import CryptoKit
import Foundation
import RemoteKit

// What pairing and the connection need of the phone's keys, of App Attest and of the store, as protocols (docs/iphone.md
// 3.2, 3.3, 4.3). The keys themselves, in the Secure Enclave and the Keychain, and Face ID's session are `Keys/`'s
// (#680's keys), the store `Store/`'s (#692): each adapts its own types to these. This target holds no stand-in for any
// of them: the test target has software keys and stores in memory, and a build with none of them wired shows "not
// paired".

/// The device key (3.2): P-256, in the Secure Enclave, usable while the phone is unlocked. It proves the device to the
/// relay and, over each channel's handshake hash, to the Mac, in `pair` and every `attach`.
protocol DeviceKeySigner: StatementSigner, Sendable {}

/// Why the presence key did not sign.
enum PresenceError: Error, Equatable, Sendable {
    /// No session is open: Face ID has not opened one, or it ended (4.5), and the context it evaluated was invalidated.
    /// The phone asks Face ID again before any channel carries its requests.
    case sessionNotOpen
}

/// The presence key (3.2, 4.3): P-256, in the Secure Enclave with `biometryCurrentSet`, used only with the authentication
/// context of the open session's Face ID. Its `sign` throws `PresenceError.sessionNotOpen` when no session is open, and
/// never asks Face ID itself: opening a session is the app's, when it comes to the foreground.
protocol PresenceSigner: StatementSigner, Sendable {}

/// The keys of one pairing, once made.
protocol PhoneKeys: Sendable {
    var device: any DeviceKeySigner { get }
    var presence: any PresenceSigner { get }
    /// The channel key's private half: Curve25519 for Noise, so in the Keychain, not the Secure Enclave (3.2).
    func channelKey() throws -> Curve25519.KeyAgreement.PrivateKey
    /// The record key's public half, sent in `pair`; its private half opens sealed items (#692), not used here.
    var recordKey: P256.KeyAgreement.PublicKey { get }
}

/// Where the phone's keys are made and kept (3.2).
protocol PhoneKeyStore: Sendable {
    /// A new device key, made as a code is scanned, before the join, whose attestation binds it (3.3 step 2).
    func makeDeviceKey() throws -> any DeviceKeySigner
    /// The pairing's other keys (presence, channel, record) beside that device key, made and kept as the pairing's,
    /// in place of any kept before. Asks no Face ID (3.2: the presence key needs Face ID enrolled, nothing more).
    func makeKeys(device: any DeviceKeySigner) throws -> any PhoneKeys
    /// The keys kept, if a pairing made them.
    func keys() throws -> (any PhoneKeys)?
    /// Deletes every key: after a failed pairing, before pairing again, and on the Mac's signed revocation.
    func deleteAll() throws
}

/// What App Attest gives for one new key (3.3 steps 2 and 4).
enum Attestation: Sendable, Equatable {
    /// `attestKey`'s attestation object of a key made for this one use, and that key's id (standard base64).
    case appAttest(object: Data, keyId: AttestKeyID)
    /// A build without App Attest: the simulator (docs/iphone.md 10). The contract allows it in `pair` only, which a
    /// throwaway copy's engine alone takes (3.3 step 5, `attestation` and `keyId` null), and only the local relay started
    /// for tests takes a join without one: so a build that answers `none` pairs over the home path, and the relay's join
    /// is not tried.
    case none
}

/// App Attest (3.2, the orchestrator's note on #680): every call makes a **new** key and attests it once over
/// `clientDataHash`, since a key is attested only once and the relay's and the Mac's are two. It never reuses a key,
/// and backs off as Apple's limits ask when it is called again after a failure.
protocol Attester: Sendable {
    func attestNewKey(clientDataHash: Data) async throws -> Attestation
}

/// What the phone keeps of its Mac (3.2, "What the phone keeps of the Mac"), written once `paired` came, in texts as
/// the payload and the lines write them.
struct PairingRecord: Codable, Equatable, Sendable {
    var pairing: String
    /// This device's id at the engine and the relay, from `paired`.
    var device: String
    var macName: String
    var macChannelKey: String
    var macIdentityKey: String
    var macRecordKey: String
    var relay: String
    /// The Mac's last addresses, `a.b.c.d:port` or `[v6]:port`.
    var addresses: [String]
    var pairedAt: Date

    init(payload: PairingPayload, paired: Paired, at date: Date) {
        pairing = payload.pairing.text
        device = paired.device.text
        macName = paired.name
        macChannelKey = PublicKeys.text(payload.channelKey)
        macIdentityKey = PublicKeys.text(payload.identityKey)
        macRecordKey = PublicKeys.text(payload.recordKey)
        relay = payload.relay
        addresses = paired.addresses
        pairedAt = date
    }

    /// The record read back into keys and ids; a record that does not read is refused, never half used.
    func mac() throws -> PairedMac {
        guard let pairing = PairingID(pairing), let device = DeviceID(device),
              let channel = PublicKeys.channelKey(fromBase64URL: macChannelKey),
              let identity = PublicKeys.signingKey(fromBase64URL: macIdentityKey),
              let record = PublicKeys.agreementKey(fromBase64URL: macRecordKey),
              let relayURL = URL(string: relay), PairingPayload.isRelayAddress(relay)
        else { throw RemoteKitError("pairing record", "does not read") }
        return PairedMac(pairing: pairing, device: device, name: macName, channelKey: channel, identityKey: identity, recordKey: record, relay: relayURL, addresses: addresses)
    }
}

/// A pairing record, read.
struct PairedMac: Sendable {
    let pairing: PairingID
    let device: DeviceID
    let name: String
    let channelKey: Curve25519.KeyAgreement.PublicKey
    /// The key every channel's proof must be signed by: the `i` scanned at pairing, kept since (3.4).
    let identityKey: P256.Signing.PublicKey
    let recordKey: P256.KeyAgreement.PublicKey
    let relay: URL
    let addresses: [String]
}

/// Where the pairing record is kept (#692's store; the Keychain, `AfterFirstUnlockThisDeviceOnly`, 3.2).
protocol PairingStore: Sendable {
    func load() throws -> PairingRecord?
    func save(_ record: PairingRecord) throws
    func delete() throws
}

/// What the phone says of itself in `pair` (3.3 step 4), within what the engine takes (the orchestrator's note on #680):
/// a build of digits and dots, a model name of at most 64 bytes.
struct PhoneDescription: Sendable, Equatable {
    var name: String
    var model: String
    var system: String
    var build: String

    /// The build's own number, `CFBundleVersion`, if it is digits and dots, as the engine and the relay take it.
    static var bundleBuild: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return RelayBuild(build) == nil ? "1" : build
    }

    /// Cut to at most `bytes` UTF-8 bytes, whole characters only, and to a name that may be shown.
    static func fitting(_ text: String, bytes: Int, otherwise: String) -> String {
        var fitted = ""
        for character in text {
            guard fitted.utf8.count + String(character).utf8.count <= bytes else { break }
            fitted.append(character)
        }
        return fitted.isEmpty || !ShownText.isShowable(fitted) ? otherwise : fitted
    }
}
