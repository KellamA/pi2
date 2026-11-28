
import CryptoKit
import Foundation
import RemoteKit
import Synchronization
@testable import pi2

// Stand-ins for the keys, App Attest and the store, for the pairing and connection tests (#680): software P-256 and
// Curve25519 keys, kept in memory. They live in the test target alone: the app has none, and shows "not paired"
// until `Keys/` and the store (#692) are wired.

struct SoftwareDeviceKey: DeviceKeySigning {
    let key = P256.Signing.PrivateKey()
    var publicKey: P256.Signing.PublicKey { key.publicKey }
    var publicKeyDER: Data { key.publicKey.derRepresentation }
    func sign(_ data: Data) throws -> Data { try key.signature(for: data).rawRepresentation }
}

/// A presence session the test opens and ends: closed, it throws `KeysError.sessionNotOpen`, as `PresenceSession`
/// does once the session's context is invalidated (4.3).
final class SoftwarePresenceKey: PresenceSigning, Sendable {
    let key = P256.Signing.PrivateKey()
    let open = Mutex(true)
    /// Every text it signed, in order.
    let signed = Mutex<[Data]>([])
    /// Whether the key waits to be accepted on the Mac, as one made after Face ID was set up again does (#891).
    let waiting = Mutex(false)
    /// Whether that mark cannot be read, as when the Keychain refuses.
    let waitingUnreadable = Mutex(false)
    /// How long a signature takes, as a Secure Enclave's does under Face ID (4.3): a check that needs a move's attach to
    /// be in flight for a while gives it one, so that the acks of the channel it moves from fall inside it.
    let signDelay = Mutex(Duration.zero)
    var publicKey: P256.Signing.PublicKey { key.publicKey }

    func presencePublicKeyDER() throws -> Data? { key.publicKey.derRepresentation }
    func presenceKeyWaits() throws -> Bool {
        if waitingUnreadable.withLock({ $0 }) { throw KeysError.keychain(-25308, "read the Face ID key") }
        return waiting.withLock { $0 }
    }
    func presenceKeyWasAccepted() throws { waiting.withLock { $0 = false } }

    func signPresence(_ data: Data) async throws -> Data {
        guard open.withLock({ $0 }) else { throw KeysError.sessionNotOpen }
        let delay = signDelay.withLock { $0 }
        if delay > .zero { try? await Task.sleep(for: delay) }
        signed.withLock { $0.append(data) }
        return try key.signature(for: data).rawRepresentation
    }
}

struct SoftwarePhoneKeys: Sendable {
    let device: SoftwareDeviceKey
    let softwarePresence = SoftwarePresenceKey()
    let channel = Curve25519.KeyAgreement.PrivateKey()
    let record = P256.KeyAgreement.PrivateKey()

    var paired: PairedKeys {
        PairedKeys(
            device: device, presence: softwarePresence, channel: channel,
            publicKeys: PairingPublicKeys(
                device: device.publicKeyDER, presence: softwarePresence.key.publicKey.derRepresentation,
                channel: channel.publicKey.rawRepresentation, record: record.publicKey.derRepresentation))
    }
}

final class MemoryKeyStore: PairingKeySource, Sendable {
    private let state = Mutex<(device: SoftwareDeviceKey?, keys: SoftwarePhoneKeys?)>((nil, nil))
    let deviceKeysMade = Mutex(0)
    let deletions = Mutex(0)

    func makeDeviceKey() throws -> any DeviceKeySigning {
        deviceKeysMade.withLock { $0 += 1 }
        let device = SoftwareDeviceKey()
        state.withLock { $0 = (device, nil) }
        return device
    }

    func makePairingKeys() throws -> PairingPublicKeys {
        let keys = try state.withLock { state in
            guard let device = state.device else { throw KeysError.missing("device key") }
            state.keys = SoftwarePhoneKeys(device: device)
            return state.keys!
        }
        return keys.paired.publicKeys
    }

    func pairedKeys() throws -> PairedKeys? { state.withLock { $0.keys?.paired } }
    var software: SoftwarePhoneKeys? { state.withLock { $0.keys } }
    /// The paired keys, for the tests' checks.
    func keys() -> PairedKeys? { state.withLock { $0.keys?.paired } }

    func wipe() throws {
        deletions.withLock { $0 += 1 }
        state.withLock { $0 = (nil, nil) }
    }
}

final class MemoryPairingStore: PairingStore, Sendable {
    private let record = Mutex<PairingRecord?>(nil)

    func load() throws -> PairingRecord? { record.withLock { $0 } }
    func save(_ record: PairingRecord) throws { self.record.withLock { $0 = record } }
    func delete() throws { record.withLock { $0 = nil } }
}

/// App Attest as the local relay's protocol stand-in takes it (`relay/test/protocol/worker.ts`): the client data hash it
/// was given, then the new key's id. Each call makes a new key, as App Attest must (3.2), and every hash is kept for
/// the test to check.
final class StandInAttester: AppAttesting, Sendable {
    let hashes = Mutex<[Data]>([])
    let keys = Mutex<[AttestKeyID]>([])

    func attestNewKey(clientDataHash: Data) async throws -> Attestation {
        let key = AttestKeyID(bytes: Bytes.random(32))!
        hashes.withLock { $0.append(clientDataHash) }
        keys.withLock { $0.append(key) }
        return .appAttest(keyID: key.text, object: clientDataHash + Data(base64Encoded: key.text)!)
    }

    func assertion(keyID: String, clientDataHash: Data) async throws -> Data { throw KeysError.appAttestUnavailable }
}

/// A build without App Attest, as the simulator is.
struct NoAttester: AppAttesting {
    func attestNewKey(clientDataHash: Data) async throws -> Attestation { .noneSimulator }
    func assertion(keyID: String, clientDataHash: Data) async throws -> Data { throw KeysError.appAttestUnavailable }
}

enum Wait {
    /// Polls `condition` until it holds, for at most `seconds`: nothing here may depend on how fast the Mac is.
    @MainActor
    static func until(_ seconds: Double = 60, _ condition: () -> Bool) async -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    static func untilAsync(_ seconds: Double = 60, _ condition: @Sendable () async -> Bool) async -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while await !condition() {
            if Date() > end { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

extension PhoneDescription {
    static let test = PhoneDescription(name: "Test iPhone", model: "iPhone18,1", system: "iOS 27.2", build: "1")
}
