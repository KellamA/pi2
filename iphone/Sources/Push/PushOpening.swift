import Foundation

/// What a phone needs to open a push: its record key, and of its Mac the pairing, the record key that authenticated
/// the seal and the identity key that signed what is inside (docs/iphone.md 3.2, 5.3).
struct PushKeys: Sendable {
    /// The pairing's id and this device's id, as RemoteKit writes them.
    let pairing: String
    let device: String
    /// The phone's record key (P-256, key agreement): its raw private bytes, as `Keys/` keeps it.
    let recordKey: Data
    /// The Mac's record key and identity key: their public halves, SPKI DER.
    let macRecordKey: Data
    let macIdentityKey: Data
}

/// An item that opened and verified: sealed for this phone by its Mac's record key and signed inside by its identity
/// key, for this pairing, this device and this id (RemoteKit's `PushSealing.open`). Nothing gives one but an opener, so
/// nothing reads what a push says before it is verified.
struct OpenedPush: Equatable, Sendable {
    /// The Mac item's kind: `push` for a notification, `pushGone` for one to take away.
    let kind: String
    /// When the Mac signed it, milliseconds since 1970 by its clock.
    let at: Int64
    /// The item's id, base64url.
    let id: String
    /// The engine's body, as JSON text, without the sealer's padding.
    let body: Data
}

/// Opens and verifies a sealed push. The one implementation is RemoteKit's (docs/iphone.md 5.2: the cryptography is
/// implemented once); this is the seam by which the extension and the app reach it, and the tests give a stand-in.
protocol PushOpening: Sendable {
    func open(_ push: SealedPush, keys: PushKeys) throws -> OpenedPush
}

enum PushOpeners {
    /// RemoteKit's opener once RemoteKit is linked into this build; until then none, and every push shows the
    /// placeholder, since nothing unverified is ever shown (section 7). RemoteKit becomes a product of `app/Package.swift`
    /// and is linked into the app and the service extension by #680's hand (docs/iphone-app.md, "The extensions").
    static var standard: (any PushOpening)? {
        #if canImport(RemoteKit)
        RemoteKitPushOpener()
        #else
        nil
        #endif
    }
}
