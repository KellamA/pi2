import Foundation
import Observation
import UIKit

/// The phone's keys, its App Attest and its Face ID session, as one object for `App/` to make at launch and hand to
/// pairing, the connection and the store. Everything they call is a protocol of `KeysInterfaces.swift`:
///
/// - `keys.makeDeviceKey()` when a code is scanned, then `keys.deviceKey()` (`DeviceKeySigning`), with its
///   `joinClientDataHash(relayChallenge:)` and `pairClientDataHash(macChallenge:binding:)`;
/// - `makePairingKeys()` at step 4 of pairing, which answers the four public halves for the claim;
/// - `attester` (`AppAttesting`), a new key for each attestation;
/// - `session` (`PresenceSigning`) for every presence signature, and `session.onEnd` for `remote.sessionEnd`;
/// - `keys.channelKey()`, `keys.recordKey()`, `keys.keepMacRecord(_:)` and `keys.macRecord()`;
/// - `wipe()` (`KeyWiping`) on unpairing and on a revocation the Mac signed.
@MainActor
@Observable
final class PhoneKeyring: KeyWiping {
    let keys: PhoneKeys
    let session: PresenceSession
    let attester: any AppAttesting
    @ObservationIgnored private let faceID: any FaceIDGate

    init(keys: PhoneKeys, faceID: any FaceIDGate, attester: any AppAttesting, mode: PresenceSession.Mode = .chosen) {
        self.keys = keys
        self.faceID = faceID
        self.attester = attester
        session = PresenceSession(keys: keys, faceID: faceID, mode: mode)
    }

    /// The keyring as this build has it, after the first launch's clearing of the Keychain (3.2). Make it once, at
    /// launch, before anything reads a key.
    static func live() -> PhoneKeyring {
        let keys = PhoneKeys.live()
        do {
            try keys.removeLeftoversAtFirstLaunch(
                defaults: .standard, protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable
            )
        } catch {
            // Tried again at the next launch: the mark is set only once the Keychain was emptied.
        }
        return PhoneKeyring(keys: keys, faceID: LocalFaceID(), attester: AppAttest.live())
    }

    /// Makes the keys of step 4 of pairing (3.3) and answers their public halves. Face ID must be set up and allowed
    /// for pi², since a phone without it cannot be paired (4.5); nothing is asked.
    func makePairingKeys() throws -> PairingPublicKeys {
        switch faceID.availability() {
        case .success(let state):
            return try keys.makePairingKeys(faceIDState: state)
        case .failure(.noPasscode):
            throw KeysError.noPasscode
        case .failure:
            throw KeysError.noFaceID
        }
    }

    /// Ends the session and removes every key and the Mac's details, then checks that nothing is left.
    func wipe() throws {
        session.end(.revoked)
        try keys.wipe()
    }
}
