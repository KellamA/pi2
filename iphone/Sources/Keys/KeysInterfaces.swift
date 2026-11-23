import CryptoKit
import Foundation
import LocalAuthentication

// What the other pieces of the phone call (pairing, the connection, the store), kept plain: bytes in, bytes out, every
// public key in the encoding RemoteKit reads (docs/remotekit.md, "Everywhere"), every signature as RemoteKit's
// `StatementSigner` gives it. Each is a protocol here with the real type conforming, so a piece can be tested against a
// stand-in of its own.

/// The device key (docs/iphone.md 3.2), which `PhoneKeys.deviceKey()` gives once a code was scanned.
protocol DeviceKeySigning: Sendable {
    /// The public half: SPKI DER, 91 bytes, as CryptoKit writes it (RemoteKit's `PublicKeys` takes only that).
    var publicKeyDER: Data { get }
    /// ECDSA P-256 over SHA-256 of `data`: 64 raw bytes, r then s (IEEE P1363), as RemoteKit's `StatementSigner.sign`.
    /// Works only while the phone is unlocked.
    func sign(_ data: Data) throws -> Data
}

/// The presence key, used only in a session Face ID opened (4.3). `PresenceSession` is the one that conforms.
protocol PresenceSigning: Sendable {
    /// The public half, SPKI DER, 91 bytes; nil if the phone has no presence key (not paired).
    func presencePublicKeyDER() throws -> Data?
    /// The presence key's signature over `data`, 64 raw bytes as the device key's. Throws `KeysError.sessionNotOpen`
    /// if no session is open, and, where each new connection asks Face ID again (4.3's fallback), shows Face ID and
    /// throws `KeysError.faceIDNotPassed` if it does not pass.
    func signPresence(_ data: Data) async throws -> Data
}

/// Removing every key: on unpairing (3.6), on a revocation the Mac signed, before pairing with another Mac.
/// `PhoneKeyring` conforms: it ends the session, then deletes every Keychain item and checks that none is left.
@MainActor
protocol KeyWiping: AnyObject {
    func wipe() throws
}

/// What the session asks of the presence key. `PhoneKeys` conforms; tests give a stand-in.
protocol PresenceKeyHolding: Sendable {
    func hasPresenceKey() throws -> Bool
    func presencePublicKey() throws -> Data?
    /// LocalAuthentication's hash of the faces enrolled when the presence key was made.
    func presenceFaceIDState() throws -> Data?
    /// Signs under `context`; throws `KeysError.needsFaceIDAgain` when the context would have to show Face ID again.
    func signPresence(_ data: Data, context: LAContext?) throws -> Data
    /// Makes a new presence key (and cache key) for the faces enrolled now, and answers its public half.
    func replacePresenceKey(faceIDState: Data?) throws -> Data
    func cacheKey(context: LAContext?) throws -> SymmetricKey?
}
