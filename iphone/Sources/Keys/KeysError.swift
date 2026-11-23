import Foundation
import Security

/// What can go wrong with the phone's keys, in words a person can act on. None carries a key, a blob or a signature.
enum KeysError: Error, Equatable, LocalizedError {
    /// No session is open: Face ID has not opened pi², or the session ended (docs/iphone.md 4.5).
    case sessionNotOpen
    /// Face ID was asked for a new connection and did not pass (the fallback of 4.3).
    case faceIDNotPassed
    /// A signature or item would have needed Face ID's interface again under a context that may show none: on a phone
    /// where one check does not sign many times (4.3). The session asks again in its place.
    case needsFaceIDAgain
    /// The phone is locked, and the item is readable only while it is unlocked.
    case phoneLocked
    /// The phone has no passcode, so no key of 3.2 can be kept.
    case noPasscode
    /// Face ID is not set up, or not allowed for pi²: the presence key cannot be made.
    case noFaceID
    /// A key that should be there is not: this phone is not paired, or its keys were deleted.
    case missing(String)
    /// Something stored could not be read back as a key.
    case unreadable(String)
    /// The relay's challenge was not exactly 32 bytes (3.3 step 2).
    case badChallenge
    /// A client data hash given to App Attest was not a SHA-256 hash.
    case badClientDataHash
    /// App Attest is not supported on this phone, or this build has none.
    case appAttestUnavailable
    /// App Attest refused or failed, with Apple's error code.
    case appAttest(Int)
    /// A Keychain call answered `status` while doing `what`.
    case keychain(OSStatus, String)
    /// The Secure Enclave or CryptoKit refused, while doing `what`.
    case crypto(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotOpen: "Open pi² with Face ID."
        case .faceIDNotPassed: "Face ID did not pass, so pi² did not connect to your Mac. Try again."
        case .needsFaceIDAgain: "pi² needs Face ID again."
        case .phoneLocked: "Unlock this iPhone first."
        case .noPasscode: "Set a passcode for this iPhone: pi² keeps its keys only on an iPhone with a passcode."
        case .noFaceID: "Set up Face ID on this iPhone and allow it for pi²: pi² opens only with Face ID."
        case .missing(let what): "This iPhone has no \(what). Pair it with your Mac again."
        case .unreadable(let what): "This iPhone's \(what) could not be read. Pair it with your Mac again."
        case .badChallenge: "The relay's challenge is not 32 bytes."
        case .badClientDataHash: "What App Attest was given to sign is not a SHA-256 hash."
        case .appAttestUnavailable: "This iPhone cannot prove it runs a genuine pi² (App Attest is not available)."
        case .appAttest(let code): "App Attest failed (DCError \(code)). Try again in a while."
        case .keychain(let status, let what): "Could not \(what): the Keychain answered \(status)."
        case .crypto(let what): "Could not \(what) with this iPhone's keys."
        }
    }
}
