
import CryptoKit
import Foundation
import RemoteKit
import Synchronization
@testable import pi2

// Stand-ins for the keys, App Attest and the store, for the pairing and connection tests (#680): software P-256 and
// Curve25519 keys, kept in memory. They live in the test target alone: the app has none, and shows "not paired"
// until `Keys/` and the store (#692) are wired.

struct SoftwareDeviceKey: DeviceKeySigner {
    let key = P256.Signing.PrivateKey()
    var publicKey: P256.Signing.PublicKey { key.publicKey }
    func sign(_ data: Data) throws -> Data { try key.signature(for: data).rawRepresentation }
}

/// A presence key whose session the test opens and ends: closed, it throws `sessionNotOpen`, as the real one does once
/// the session's context is invalidated (4.3).
final class SoftwarePresenceKey: PresenceSigner, Sendable {
    let key = P256.Signing.PrivateKey()
    let open = Mutex(true)
    let signatures = Mutex(0)
    var publicKey: P256.Signing.PublicKey { key.publicKey }

    func sign(_ data: Data) throws -> Data {
        guard open.withLock({ $0 }) else { throw PresenceError.sessionNotOpen }
        signatures.withLock { $0 += 1 }
        return try key.signature(for: data).rawRepresentation
    }
}

struct SoftwarePhoneKeys: PhoneKeys {
    let device: any DeviceKeySigner
    let softwarePresence = SoftwarePresenceKey()
    let channel = Curve25519.KeyAgreement.PrivateKey()
    let record = P256.KeyAgreement.PrivateKey()

    var presence: any PresenceSigner { softwarePresence }
    func channelKey() throws -> Curve25519.KeyAgreement.PrivateKey { channel }
    var recordKey: P256.KeyAgreement.PublicKey { record.publicKey }
}

final class MemoryKeyStore: PhoneKeyStore, Sendable {
    private let kept = Mutex<SoftwarePhoneKeys?>(nil)
    let deviceKeysMade = Mutex(0)
    let deletions = Mutex(0)

    func makeDeviceKey() throws -> any DeviceKeySigner {
        deviceKeysMade.withLock { $0 += 1 }
        return SoftwareDeviceKey()
    }

    func makeKeys(device: any DeviceKeySigner) throws -> any PhoneKeys {
        let keys = SoftwarePhoneKeys(device: device)
        kept.withLock { $0 = keys }
        return keys
    }

    func keys() throws -> (any PhoneKeys)? { kept.withLock { $0 } }
    var software: SoftwarePhoneKeys? { kept.withLock { $0 } }

    func deleteAll() throws {
        deletions.withLock { $0 += 1 }
        kept.withLock { $0 = nil }
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
final class StandInAttester: Attester, Sendable {
    let hashes = Mutex<[Data]>([])
    let keys = Mutex<[AttestKeyID]>([])

    func attestNewKey(clientDataHash: Data) async throws -> Attestation {
        let key = AttestKeyID(bytes: Bytes.random(32))!
        hashes.withLock { $0.append(clientDataHash) }
        keys.withLock { $0.append(key) }
        return .appAttest(object: clientDataHash + Data(base64Encoded: key.text)!, keyId: key)
    }
}

/// A build without App Attest, as the simulator is.
struct NoAttester: Attester {
    func attestNewKey(clientDataHash: Data) async throws -> Attestation { .none }
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
