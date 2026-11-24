
import CryptoKit
import Foundation
import RemoteKit
import UIKit

// What pairing and the connection need of the phone's keys, its App Attest and its store (docs/iphone.md 3.2, 3.3,
// 4.3). The keys are `Keys/`'s: its `DeviceKeySigning`, `PresenceSigning`, `AppAttesting` and `Attestation` are used
// as they are, and `PhoneKeyring` is adapted to `PairingKeySource` in `KeysAdapter.swift`, where the raw signatures
// meet RemoteKit's `StatementSigner`. The test target has software stand-ins; the app has none.

/// What pairing makes and the connection reads of the phone's keys. `PhoneKeyring` conforms (`KeysAdapter.swift`).
protocol PairingKeySource: Sendable {
    /// A new device key, made as a code is scanned, before the join, whose attestation binds it (3.3 step 2).
    func makeDeviceKey() async throws -> any DeviceKeySigning
    /// The presence, channel, record and cache keys of step 4, beside that device key; their public halves. Asks no
    /// Face ID, but needs it set up (`KeysError.noFaceID`, `.noPasscode`).
    func makePairingKeys() async throws -> PairingPublicKeys
    /// The keys a pairing made, if it made them.
    func pairedKeys() async throws -> PairedKeys?
    /// Deletes every key (and the Mac's record with them): after a failed pairing, before pairing again, and on the
    /// Mac's signed revocation. Ends the session.
    func wipe() async throws
}

/// The keys of one pairing, as the connection uses them.
struct PairedKeys: Sendable {
    let device: any DeviceKeySigning
    /// The open session's presence signatures (`PresenceSession`): `KeysError.sessionNotOpen` outside one.
    let presence: any PresenceSigning
    /// The channel key's private half: Curve25519 for Noise, so in the Keychain, not the Secure Enclave (3.2).
    let channel: Curve25519.KeyAgreement.PrivateKey
    /// The four public halves, as the `pair` claim gave them.
    let publicKeys: PairingPublicKeys
}

/// Why the presence key did not sign, in the connection's terms (`KeysError.sessionNotOpen`, `.faceIDNotPassed`).
enum PresenceError: Error, Equatable, Sendable {
    /// No session is open: Face ID has not opened one, or it ended (4.5). The phone asks Face ID again before any
    /// channel carries its requests.
    case sessionNotOpen
    /// Face ID was asked again for this connection (4.3's fallback) and did not pass.
    case faceIDNotPassed
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
    /// The home tag's key (remotekit.md, "The home key"): from `paired`, and in place of it the last a `homeKey` line
    /// gave. A secret: kept only here, with the keys.
    var homeKey: String
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
        homeKey = Base64URL.encode(paired.homeKey.rawRepresentation)
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
              let homeBytes = Base64URL.decode(homeKey, count: HomeKey.length), let home = HomeKey(rawRepresentation: homeBytes),
              let relayURL = URL(string: relay), PairingPayload.isRelayAddress(relay)
        else { throw RemoteKitError("pairing record", "does not read") }
        return PairedMac(pairing: pairing, device: device, name: macName, channelKey: channel, identityKey: identity, recordKey: record, homeKey: home, relay: relayURL, addresses: addresses)
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
    /// The key the Mac's Bonjour tag is made from (5.4).
    let homeKey: HomeKey
    let relay: URL
    let addresses: [String]
}

/// Where the pairing record is kept. In the app, `KeychainPairingStore`: Keys/'s `keepMacRecord`, in the Keychain
/// beside the keys (`AfterFirstUnlockThisDeviceOnly`, 3.2), so that the one wipe that removes the keys removes it too.
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

    /// This phone: its name and system as iOS gives them, its model identifier (such as `iPhone18,1`), and this build.
    @MainActor
    static func current() -> PhoneDescription {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        let device = UIDevice.current
        return PhoneDescription(
            name: fitting(device.name, bytes: 128, otherwise: "iPhone"), model: fitting(model, bytes: 64, otherwise: "iPhone"),
            system: fitting("\(device.systemName) \(device.systemVersion)", bytes: 128, otherwise: "iOS"), build: bundleBuild)
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
