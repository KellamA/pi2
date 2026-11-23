import DeviceCheck
import Foundation

/// What a claim carries to prove it comes from a genuine pi² for iPhone (docs/iphone.md 3.3 steps 2 and 4).
enum Attestation: Equatable, Sendable {
    /// App Attest's attestation object, and its key's id in standard base64 with padding, as `DCAppAttestService` gives
    /// it (the relay's and the engine's `keyId`).
    case appAttest(keyID: String, object: Data)
    /// No attestation at all: the simulator has no App Attest (section 10). Only the local relay started for tests and a
    /// throwaway copy's engine take a claim without one; pi²'s relays and a release engine refuse it. Never a made-up
    /// attestation in its place.
    case noneSimulator
}

/// App Attest, as pairing uses it. Each call makes a new key and attests it once: App Attest attests a key only once
/// (`DCError.invalidKey` after), so the relay's join and the Mac's `pair` each get a key of their own, and every join
/// attempt a new one (3.2).
protocol AppAttesting: Sendable {
    /// Makes a new App Attest key and attests it with `clientDataHash` (32 bytes, SHA-256): for the join,
    /// `DeviceKey.joinClientDataHash(relayChallenge:)`; for `pair`, `DeviceKey.pairClientDataHash(macChallenge:binding:)`.
    /// Apple limits how often a phone may attest: a caller that retries backs off.
    func attestNewKey(clientDataHash: Data) async throws -> Attestation
    /// An assertion by an attested key over `clientDataHash`, for a request a server checks against that key.
    func assertion(keyID: String, clientDataHash: Data) async throws -> Data
}

enum AppAttest {
    /// The attester this build has: App Attest on a phone, none in the simulator.
    static func live() -> any AppAttesting {
        #if targetEnvironment(simulator)
        SimulatorAttester()
        #else
        DeviceAttester()
        #endif
    }
}

/// `DCAppAttestService`, on a phone.
struct DeviceAttester: AppAttesting {
    func attestNewKey(clientDataHash: Data) async throws -> Attestation {
        guard clientDataHash.count == 32 else { throw KeysError.badClientDataHash }
        let service = DCAppAttestService.shared
        guard service.isSupported else { throw KeysError.appAttestUnavailable }
        do {
            let keyID = try await service.generateKey()
            let object = try await service.attestKey(keyID, clientDataHash: clientDataHash)
            return .appAttest(keyID: keyID, object: object)
        } catch {
            throw Self.failure(error)
        }
    }

    func assertion(keyID: String, clientDataHash: Data) async throws -> Data {
        guard clientDataHash.count == 32 else { throw KeysError.badClientDataHash }
        let service = DCAppAttestService.shared
        guard service.isSupported else { throw KeysError.appAttestUnavailable }
        do {
            return try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
        } catch {
            throw Self.failure(error)
        }
    }

    private static func failure(_ error: Error) -> KeysError {
        let ns = error as NSError
        if ns.domain == DCErrorDomain, ns.code == DCError.Code.featureUnsupported.rawValue { return .appAttestUnavailable }
        return .appAttest(ns.domain == DCErrorDomain ? ns.code : -1)
    }
}

#if targetEnvironment(simulator)
/// The simulator's: it has no App Attest, and says so with `.noneSimulator` rather than an attestation of its own.
struct SimulatorAttester: AppAttesting {
    func attestNewKey(clientDataHash: Data) async throws -> Attestation {
        guard clientDataHash.count == 32 else { throw KeysError.badClientDataHash }
        return .noneSimulator
    }

    func assertion(keyID: String, clientDataHash: Data) async throws -> Data {
        throw KeysError.appAttestUnavailable
    }
}
#endif
