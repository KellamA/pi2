import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The public halves of the keys made at pairing, in the encodings RemoteKit reads (docs/remotekit.md, "Everywhere"):
/// a P-256 key as its SPKI DER, 91 bytes, exactly as CryptoKit writes it; the channel key as its 32 raw Curve25519
/// bytes. These are what the `pair` claim's `device` holds (3.3 step 4).
struct PairingPublicKeys: Equatable, Sendable {
    var device: Data
    var presence: Data
    var channel: Data
    var record: Data
}

/// The device key (3.2): proves the device to the relay and, over the channel's handshake hash, to the Mac, and signs
/// every sealed item the phone writes. In the Secure Enclave on a phone; in software in the simulator (section 10).
struct DeviceKey: DeviceKeySigning {
    fileprivate enum Held: @unchecked Sendable {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    fileprivate let held: Held
    let publicKey: P256.Signing.PublicKey

    var publicKeyDER: Data { publicKey.derRepresentation }

    /// Whether the key is in the Secure Enclave, for the debug build's line saying where its keys are.
    var inSecureEnclave: Bool {
        if case .enclave = held { true } else { false }
    }

    func sign(_ data: Data) throws -> Data {
        do {
            switch held {
            case .enclave(let key): return try key.signature(for: data).rawRepresentation
            case .software(let key): return try key.signature(for: data).rawRepresentation
            }
        } catch {
            if KeyErrors.needsInteraction(error) { throw KeysError.phoneLocked }
            throw KeysError.crypto("sign with the device key")
        }
    }

    /// The client data hash of the App Attest attestation sent in `join`: SHA-256 of the relay's 32-byte challenge,
    /// then this device key's SPKI DER (3.3 step 2; the relay's `joinClientDataHash`). Worked out here from the key this
    /// phone holds, never from a key or a hash it was given (#680, the relay's security read).
    func joinClientDataHash(relayChallenge: Data) throws -> Data {
        guard relayChallenge.count == 32 else { throw KeysError.badChallenge }
        var hasher = SHA256()
        hasher.update(data: relayChallenge)
        hasher.update(data: publicKeyDER)
        return Data(hasher.finalize())
    }

    /// The client data hash of the attestation sent in `pair`: SHA-256 of the Mac's challenge, this device key's SPKI
    /// DER and the channel's handshake hash, one after the other (3.3 step 4; RemoteKit's
    /// `PairingSecrets.attestationClientDataHash`).
    func pairClientDataHash(macChallenge: Data, binding: Data) throws -> Data {
        guard macChallenge.count == 32, binding.count == 32 else { throw KeysError.badChallenge }
        var hasher = SHA256()
        hasher.update(data: macChallenge)
        hasher.update(data: publicKeyDER)
        hasher.update(data: binding)
        return Data(hasher.finalize())
    }
}

/// The phone's keys of docs/iphone.md 3.2, and what it keeps of the Mac, all in the Keychain (`KeyItem` says how each
/// is protected). The phone's store (its cache, its Outbox) is `Store/`'s; this holds keys and the Mac's details only.
///
/// When each is made: the device key when a code is scanned (`makeDeviceKey`), since the relay's join binds it; the
/// presence, channel, record and cache keys at step 4 of pairing (`makePairingKeys`), which needs Face ID enrolled but
/// asks for none; the Mac's details once paired (`keepMacRecord`). The App Attest keys are `DCAppAttestService`'s and
/// are never kept here (`AppAttest.swift`).
final class PhoneKeys: PresenceKeyHolding {
    let keychain: any KeychainStore
    /// Whether the keys go in the Secure Enclave. False in the simulator, which a debug build says on screen.
    let secureEnclave: Bool

    init(keychain: any KeychainStore, secureEnclave: Bool = KeyPlace.secureEnclave) {
        self.keychain = keychain
        self.secureEnclave = secureEnclave
    }

    /// The keys as this build keeps them: the Keychain on a phone; in the simulator the Keychain, or a file where an
    /// unsigned build is refused it (`SimulatorKeyFile`).
    static func live() -> PhoneKeys {
        #if targetEnvironment(simulator)
        PhoneKeys(keychain: SimulatorKeyFile.orKeychain())
        #else
        PhoneKeys(keychain: SystemKeychain())
        #endif
    }

    // MARK: The first launch

    /// The mark, in the app's preferences, that this installation has already cleared the Keychain. Preferences go
    /// with the app when it is deleted; Keychain items may not (3.2).
    static let installedMark = "pi2.keys.installed"

    /// At the first launch after the app is installed, deletes every Keychain item the app can reach (3.2: "a
    /// reinstall must not find old keys"). Answers whether it did. Call it before anything reads a key.
    ///
    /// It waits for `protectedDataAvailable`: iOS may launch an app before the phone's first unlock (prewarming), when
    /// the preferences cannot be read and would look like a new installation's, which would delete the keys of a
    /// paired phone.
    @discardableResult
    func removeLeftoversAtFirstLaunch(defaults: UserDefaults, protectedDataAvailable: Bool) throws -> Bool {
        guard protectedDataAvailable, !defaults.bool(forKey: Self.installedMark) else { return false }
        try keychain.deleteEverything()
        defaults.set(true, forKey: Self.installedMark)
        return true
    }

    // MARK: Making the keys

    /// Makes the device key, in place of any: when a code is scanned, before the relay's join (3.3 step 2).
    @discardableResult
    func makeDeviceKey() throws -> DeviceKey {
        let key: DeviceKey
        if secureEnclave {
            do {
                let made = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: KeyAccess.deviceKey())
                try keychain.write(made.dataRepresentation, as: .deviceKey)
                key = DeviceKey(held: .enclave(made), publicKey: made.publicKey)
            } catch let error as KeysError {
                throw error
            } catch {
                throw KeysError.crypto("make the device key")
            }
        } else {
            let made = P256.Signing.PrivateKey(compactRepresentable: false)
            try keychain.write(made.rawRepresentation, as: .deviceKey)
            key = DeviceKey(held: .software(made), publicKey: made.publicKey)
        }
        return key
    }

    /// Makes the presence, channel, record and cache keys, in place of any (3.3 step 4), and answers the four public
    /// halves for the claim. `faceIDState` is LocalAuthentication's hash of the faces enrolled now: Face ID must be
    /// enrolled, which the caller has checked (`PhoneKeyring.makePairingKeys` does).
    func makePairingKeys(faceIDState: Data?) throws -> PairingPublicKeys {
        guard let device = try deviceKey() else { throw KeysError.missing("device key") }
        do {
            let presence = try makePresenceKey(faceIDState: faceIDState)
            let channel = Curve25519.KeyAgreement.PrivateKey()
            try keychain.write(channel.rawRepresentation, as: .channelKey)
            let record = P256.KeyAgreement.PrivateKey(compactRepresentable: false)
            try keychain.write(record.rawRepresentation, as: .recordKey)
            try keychain.delete(.presenceKeyWaiting)
            return PairingPublicKeys(
                device: device.publicKeyDER, presence: presence,
                channel: channel.publicKey.rawRepresentation, record: record.publicKey.derRepresentation
            )
        } catch {
            for item in [KeyItem.presenceKey, .presencePublicKey, .presenceFaceIDState, .channelKey, .recordKey, .cacheKey] {
                try? keychain.delete(item)
            }
            throw error
        }
    }

    /// A new presence key and cache key, made for the faces enrolled now, the old ones being gone with the old
    /// enrolment (`biometryCurrentSet`). The new key waits until the person accepts it on the Mac (3.2,
    /// `devices.acceptPresenceKey`); `presenceKeyIsWaiting` says so until `presenceKeyAccepted()`. Answers its public
    /// half, SPKI DER, to send the Mac. What the old cache key sealed can no longer be opened: the store starts afresh.
    func replacePresenceKey(faceIDState: Data?) throws -> Data {
        let presence = try makePresenceKey(faceIDState: faceIDState)
        try keychain.write(Data([1]), as: .presenceKeyWaiting)
        return presence
    }

    private func makePresenceKey(faceIDState: Data?) throws -> Data {
        let publicKey: P256.Signing.PublicKey
        if secureEnclave {
            do {
                let made = try SecureEnclave.P256.Signing.PrivateKey(
                    compactRepresentable: false, accessControl: KeyAccess.underFaceID(privateKey: true)
                )
                try keychain.write(made.dataRepresentation, as: .presenceKey)
                publicKey = made.publicKey
            } catch let error as KeysError {
                throw error
            } catch {
                throw KeysError.crypto("make the Face ID key")
            }
        } else {
            let made = P256.Signing.PrivateKey(compactRepresentable: false)
            try keychain.write(made.rawRepresentation, as: .presenceKey)
            publicKey = made.publicKey
        }
        try keychain.write(publicKey.derRepresentation, as: .presencePublicKey)
        if let faceIDState {
            try keychain.write(faceIDState, as: .presenceFaceIDState)
        } else {
            try keychain.delete(.presenceFaceIDState)
        }
        try keychain.write(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, as: .cacheKey)
        return publicKey.derRepresentation
    }

    // MARK: Reading them

    func deviceKey() throws -> DeviceKey? {
        guard let stored = try keychain.read(.deviceKey, context: nil) else { return nil }
        do {
            if secureEnclave {
                let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored)
                return DeviceKey(held: .enclave(key), publicKey: key.publicKey)
            }
            let key = try P256.Signing.PrivateKey(rawRepresentation: stored)
            return DeviceKey(held: .software(key), publicKey: key.publicKey)
        } catch {
            throw KeysError.unreadable("device key")
        }
    }

    /// The channel key, the phone's static key in Noise (5.2).
    func channelKey() throws -> Curve25519.KeyAgreement.PrivateKey? {
        guard let stored = try keychain.read(.channelKey, context: nil) else { return nil }
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored) else {
            throw KeysError.unreadable("channel key")
        }
        return key
    }

    /// The record key, which opens what is sealed to the phone (5.3). In the Keychain, `AfterFirstUnlockThisDeviceOnly`,
    /// in the group the notification service extension shares once it exists. 3.2 allows the Secure Enclave if a
    /// Secure Enclave key opens items in the extension while the phone is locked, which only a phone can show (P21).
    func recordKey() throws -> P256.KeyAgreement.PrivateKey? {
        guard let stored = try keychain.read(.recordKey, context: nil) else { return nil }
        guard let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: stored) else {
            throw KeysError.unreadable("record key")
        }
        return key
    }

    /// The four public halves of the keys made at pairing, or nil if this phone has none.
    func publicKeys() throws -> PairingPublicKeys? {
        guard let device = try deviceKey(), let presence = try presencePublicKey(),
              let channel = try channelKey(), let record = try recordKey() else { return nil }
        return PairingPublicKeys(
            device: device.publicKeyDER, presence: presence,
            channel: channel.publicKey.rawRepresentation, record: record.publicKey.derRepresentation
        )
    }

    func presencePublicKey() throws -> Data? {
        try keychain.read(.presencePublicKey, context: nil)
    }

    func hasPresenceKey() throws -> Bool {
        try keychain.read(.presenceKey, context: nil) != nil
    }

    func presenceFaceIDState() throws -> Data? {
        try keychain.read(.presenceFaceIDState, context: nil)
    }

    /// Whether the presence key was made after Face ID was enrolled again and waits for the person to accept it on
    /// the Mac (3.2).
    func presenceKeyIsWaiting() throws -> Bool {
        try keychain.read(.presenceKeyWaiting, context: nil) != nil
    }

    /// The Mac accepted the new presence key (it answered an attach signed with it).
    func presenceKeyAccepted() throws {
        try keychain.delete(.presenceKeyWaiting)
    }

    /// The presence key's signature over `data`, 64 raw bytes, under `context`, the one Face ID evaluated for the session
    /// (4.3). The session calls this; everyone else asks the session (`PresenceSigning`).
    func signPresence(_ data: Data, context: LAContext?) throws -> Data {
        guard let stored = try keychain.read(.presenceKey, context: nil) else { throw KeysError.missing("Face ID key") }
        if secureEnclave {
            guard let context else { throw KeysError.sessionNotOpen }
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored, authenticationContext: context)
                return try key.signature(for: data).rawRepresentation
            } catch {
                if KeyErrors.needsInteraction(error) { throw KeysError.needsFaceIDAgain }
                if KeyErrors.contextEnded(error) { throw KeysError.sessionNotOpen }
                throw KeysError.crypto("sign under Face ID")
            }
        }
        // In software (the simulator, and tests) nothing but the session stands between a caller and the key: the
        // session signs only while it is open, under a Face ID the simulator passed.
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: stored) else { throw KeysError.unreadable("Face ID key") }
        do {
            return try key.signature(for: data).rawRepresentation
        } catch {
            throw KeysError.crypto("sign under Face ID")
        }
    }

    /// The cache key, read under the session's context: the cache opens only in an open session (3.2, 3.6).
    func cacheKey(context: LAContext?) throws -> SymmetricKey? {
        try keychain.read(.cacheKey, context: context).map { SymmetricKey(data: $0) }
    }

    // MARK: The Mac

    /// Keeps what the phone keeps of the Mac (3.2): the pairing's id, the Mac's name, channel, identity and record
    /// keys, the relay's address and the Mac's last addresses, as one encoded record the pairing gives. Bytes in,
    /// bytes out: its form is the pairing's.
    func keepMacRecord(_ record: Data) throws {
        try keychain.write(record, as: .macRecord)
    }

    func macRecord() throws -> Data? {
        try keychain.read(.macRecord, context: nil)
    }

    // MARK: Wiping

    /// Removes every key and the Mac's details: on unpairing (3.6), on a revocation the Mac signed, and before pairing
    /// again. The Secure Enclave keys go with their blobs, which are the only way to use them. Checks afterwards that
    /// nothing is left, and throws if anything is.
    func wipe() throws {
        try keychain.deleteEverything()
        let left = try keychain.names()
        guard left.isEmpty else { throw KeysError.keychain(errSecDuplicateItem, "delete \(left.count) item(s) left") }
    }

    /// The names of the items kept now, for the wipe's check and the debug build.
    func itemNames() throws -> [String] {
        try keychain.names()
    }
}

/// Reading what CryptoKit, the Security framework and LocalAuthentication say went wrong.
enum KeyErrors {
    /// Whether the operation needed Face ID's (or the passcode's) interface, which the context no longer allowed.
    static func needsInteraction(_ error: Error) -> Bool {
        if let crypto = error as? CryptoKitError, case .underlyingCoreCryptoError(let code) = crypto {
            return code == errSecInteractionNotAllowed
        }
        return chain(error).contains { ns in
            (ns.domain == LAErrorDomain && ns.code == LAError.Code.notInteractive.rawValue)
                || (ns.domain == NSOSStatusErrorDomain && ns.code == Int(errSecInteractionNotAllowed))
        }
    }

    /// Whether the context was invalidated or cancelled: the session ended under the signature.
    static func contextEnded(_ error: Error) -> Bool {
        chain(error).contains { ns in
            ns.domain == LAErrorDomain
                && [LAError.Code.invalidContext.rawValue, LAError.Code.appCancel.rawValue, LAError.Code.systemCancel.rawValue].contains(ns.code)
        }
    }

    private static func chain(_ error: Error) -> [NSError] {
        var errors: [NSError] = []
        var current: NSError? = error as NSError
        while let ns = current, errors.count < 8 {
            errors.append(ns)
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return errors
    }
}
