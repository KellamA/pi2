// RemoteKit's opener, built once RemoteKit is linked into the app and the service extension (#680's hand, docs/iphone-app.md
// "The extensions"); until then this file builds nothing and `PushOpeners.standard` is nil.
#if canImport(RemoteKit)
import CryptoKit
import RemoteKit

/// RemoteKit's `PushSealing.open`, the other side of what pi² Remote seals (#689): it opens, reads and verifies in one
/// call (`SealedItem.openMacItem` within), so that nothing acts on a push that is not verified, and gives the engine's
/// body as it wrote it (docs/remotekit.md "Sealed pushes").
struct RemoteKitPushOpener: PushOpening {
    func open(_ push: SealedPush, keys: PushKeys) throws -> OpenedPush {
        guard let pairing = PairingID(keys.pairing), let device = DeviceID(keys.device),
              let reader = try? P256.KeyAgreement.PrivateKey(rawRepresentation: keys.recordKey),
              let writer = try? P256.KeyAgreement.PublicKey(derRepresentation: keys.macRecordKey),
              let identity = try? P256.Signing.PublicKey(derRepresentation: keys.macIdentityKey)
        else { throw PushRefusal.noKeys }
        let opened: PushSealing.Opened
        do {
            opened = try PushSealing.open(push.bytes, pairing: pairing, device: device, recordKey: reader, macRecordKey: writer, identityKey: identity)
        } catch {
            throw PushRefusal.doesNotOpen
        }
        return OpenedPush(kind: opened.kind.itemKind, at: opened.at, id: opened.id.text, body: JSON.write(opened.body))
    }
}
#endif
