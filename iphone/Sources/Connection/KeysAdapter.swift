
import CryptoKit
import Foundation
import RemoteKit

// Where `Keys/` meets pairing, the connection and RemoteKit (#680): `PhoneKeyring` as a `PairingKeySource`, the device
// key as RemoteKit's `StatementSigner`, the presence session's asynchronous signature in an attach, App Attest's
// `Attestation` as the relay's and the Mac's, and the Mac's record in the Keychain through `keepMacRecord`.
//
// Signatures need no conversion: Keys/ gives 64 raw bytes, r then s (IEEE P1363), which is what RemoteKit's
// `StatementSigner.sign` gives and its verifier reads; each is checked against the public key here before it is used,
// so that a key giving another encoding fails here and not at the Mac. Public keys: Keys/ gives SPKI DER, read back
// with RemoteKit's `PublicKeys`, which takes only the encoding CryptoKit writes.

extension PhoneKeyring: PairingKeySource {
    func makeDeviceKey() throws -> any DeviceKeySigning {
        try keys.makeDeviceKey()
    }

    func pairedKeys() throws -> PairedKeys? {
        guard let device = try keys.deviceKey(), let channel = try keys.channelKey(), let publicKeys = try keys.publicKeys() else { return nil }
        return PairedKeys(device: device, presence: session, channel: channel, publicKeys: publicKeys)
    }
}

/// The device key as RemoteKit signs with it: `pair`, `attach`, the relay's proofs.
struct DeviceStatementSigner: StatementSigner, Sendable {
    let key: any DeviceKeySigning
    let publicKey: P256.Signing.PublicKey

    init(_ key: any DeviceKeySigning) throws {
        guard let publicKey = PublicKeys.signingKey(fromBase64URL: Base64URL.encode(key.publicKeyDER)) else {
            throw RemoteKitError("device key", "not a P-256 key in SPKI DER")
        }
        self.key = key
        self.publicKey = publicKey
    }

    func sign(_ data: Data) throws -> Data {
        let signature = try key.sign(data)
        guard let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature), publicKey.isValidSignature(ecdsa, for: data) else {
            throw RemoteKitError("device key", "a signature that is not 64 raw bytes by this key")
        }
        return signature
    }

    var relaySigner: RelaySigner {
        let key = key
        return RelaySigner(publicKey: publicKey, sign: { try key.sign($0) })
    }
}

extension PairingPublicKeys {
    /// The claim's `device`, from the four public halves Keys/ made, each read back by RemoteKit.
    func description(of phone: PhoneDescription) throws -> DeviceDescription {
        guard let device = PublicKeys.signingKey(fromBase64URL: Base64URL.encode(self.device)),
              let presence = PublicKeys.signingKey(fromBase64URL: Base64URL.encode(self.presence)),
              let channel = PublicKeys.channelKey(fromBase64URL: Base64URL.encode(self.channel)),
              let record = PublicKeys.agreementKey(fromBase64URL: Base64URL.encode(self.record))
        else { throw RemoteKitError("pair", "a public key RemoteKit does not read") }
        return DeviceDescription(
            name: phone.name, model: phone.model, system: phone.system, build: phone.build, deviceKey: device, presenceKey: presence,
            channelKey: channel, recordKey: record)
    }
}

extension Attestation {
    /// For the relay's join: App Attest's, or nil for a build without it, which the relay's join does not take.
    var forRelay: RelayAttestation? {
        get throws {
            switch self {
            case let .appAttest(keyID, object):
                guard let id = AttestKeyID(keyID) else { throw KeysError.appAttest(-1) }
                return RelayAttestation(attestation: object, keyId: id)
            case .noneSimulator:
                return nil
            }
        }
    }

    /// For `pair`: the object and key id, or both null from a build without App Attest, which only a throwaway copy's
    /// engine takes (3.3 step 5).
    var forPair: (object: Data?, keyId: String?) {
        get throws {
            switch self {
            case let .appAttest(keyID, object):
                guard AttestKeyID(keyID) != nil else { throw KeysError.appAttest(-1) }
                return (object, keyID)
            case .noneSimulator:
                return (nil, nil)
            }
        }
    }
}

extension PresenceError {
    /// The presence session's refusal in the connection's terms; nil for any other error.
    init?(_ error: any Error) {
        switch error as? KeysError {
        case .sessionNotOpen?, .needsFaceIDAgain?: self = .sessionNotOpen
        case .faceIDNotPassed?: self = .faceIDNotPassed
        default: return nil
        }
    }
}

enum PresenceSignatures {
    /// An attach with both signatures, the presence one asked of the session, which signs asynchronously (it may
    /// show Face ID, 4.3's fallback) where RemoteKit's `AttachClaim.make` signs synchronously. So the claim is made
    /// twice from the same fields: once with throwaway keys, for the exact text RemoteKit writes, which the session
    /// then signs; then with the device key and that signature, which is used only if the text is the same.
    static func attach(
        pairing: PairingID, device: DeviceID, session: SessionID?, received: UInt64?, binding: Data, challenge: Data, build: String, at date: Date,
        deviceKey: any DeviceKeySigning, presence: any PresenceSigning
    ) async throws -> AttachClaim {
        let throwaway = P256.Signing.PrivateKey()
        let draft = try AttachClaim.make(
            pairing: pairing, device: device, session: session, received: received, binding: binding, challenge: challenge, build: build, at: date,
            deviceKey: throwaway, presenceKey: throwaway)
        let text = Data(draft.statement.text.utf8)
        let signature = try await presence.signPresence(text)
        guard let presenceKey = PublicKeys.signingKey(fromBase64URL: Base64URL.encode(try presence.presencePublicKeyDER() ?? Data())) else {
            throw KeysError.missing("Face ID key")
        }
        return try AttachClaim.make(
            pairing: pairing, device: device, session: session, received: received, binding: binding, challenge: challenge, build: build, at: date,
            deviceKey: try DeviceStatementSigner(deviceKey), presenceKey: Signed(text: text, signature: signature, publicKey: presenceKey))
    }

    /// The offer of the presence key that waits to be accepted on the Mac (3.2, #891), signed by the device key and by
    /// the offered key itself, asked of the session as an attach's presence signature is: under the context Face ID
    /// evaluated when this session opened, after the key was made. The text is RemoteKit's (`PresenceKeyOffer.signedText`),
    /// exactly what the engine reads, and is signed before the offer is made with that signature.
    static func offer(
        pairing: PairingID, device: DeviceID, binding: Data, challenge: Data, build: String, at date: Date, deviceKey: any DeviceKeySigning,
        presence: any PresenceSigning
    ) async throws -> PresenceKeyOffer {
        guard let offered = PublicKeys.signingKey(fromBase64URL: Base64URL.encode(try presence.presencePublicKeyDER() ?? Data())) else {
            throw KeysError.missing("Face ID key")
        }
        let text = Data(PresenceKeyOffer.signedText(pairing: pairing, device: device, binding: binding, challenge: challenge, presenceKey: offered, build: build, at: date).utf8)
        let signature = try await presence.signPresence(text)
        return try PresenceKeyOffer.make(
            pairing: pairing, device: device, binding: binding, challenge: challenge, build: build, at: date, deviceKey: try DeviceStatementSigner(deviceKey),
            offeredKey: Signed(text: text, signature: signature, publicKey: offered))
    }

    /// A signature made already, given for exactly the text it was made over.
    private struct Signed: StatementSigner {
        let text: Data
        let signature: Data
        let publicKey: P256.Signing.PublicKey

        func sign(_ data: Data) throws -> Data {
            guard data == text, let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature), publicKey.isValidSignature(ecdsa, for: data) else {
                throw RemoteKitError("presence key", "the presence signature is not over this text by the presence key")
            }
            return signature
        }
    }
}

/// The pairing record where Keys/ keeps what the phone keeps of the Mac (3.2): `keepMacRecord`, in the Keychain beside
/// the keys, `AfterFirstUnlockThisDeviceOnly`. One place, so that `PhoneKeyring.wipe()` (an unpairing, the Mac's signed
/// revocation, pairing again) removes the record with the keys, and no record outlives its keys or keys their record.
struct KeychainPairingStore: PairingStore {
    let keys: PhoneKeys

    func load() throws -> PairingRecord? {
        guard let data = try keys.macRecord() else { return nil }
        return try JSONDecoder().decode(PairingRecord.self, from: data)
    }

    func save(_ record: PairingRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try keys.keepMacRecord(try encoder.encode(record))
    }

    func delete() throws {
        try keys.keychain.delete(.macRecord)
    }
}
