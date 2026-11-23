// RemoteKit's opener, built once RemoteKit is linked into the app and the service extension (#680's hand, docs/iphone-app.md
// "The extensions"); until then this file builds nothing and `PushOpeners.standard` is nil.
#if canImport(RemoteKit)
import CryptoKit
import RemoteKit

/// RemoteKit's `SealedItem.openMacItem`, which opens, reads and verifies in one call, so that nothing acts on an item
/// that is not verified (docs/remotekit.md "Sealed items").
struct RemoteKitPushOpener: PushOpening {
    func open(_ push: SealedPush, keys: PushKeys) throws -> OpenedPush {
        guard let pairing = PairingID(keys.pairing), let device = DeviceID(keys.device), let id = ItemID(push.idText),
              let reader = try? P256.KeyAgreement.PrivateKey(rawRepresentation: keys.recordKey),
              let writer = try? P256.KeyAgreement.PublicKey(derRepresentation: keys.macRecordKey),
              let identity = try? P256.Signing.PublicKey(derRepresentation: keys.macIdentityKey)
        else { throw PushRefusal.noKeys }
        let item: MacItem
        do {
            item = try SealedItem.openMacItem(
                push.item, at: ItemAddress(pairing: pairing, reader: .device(device), id: id),
                readerKey: reader, writerRecordKey: writer, identityKey: identity)
        } catch {
            throw PushRefusal.doesNotOpen
        }
        return OpenedPush(kind: item.kind, at: item.at, id: item.nonce.text, body: JSON.write(item.body))
    }
}
#endif
