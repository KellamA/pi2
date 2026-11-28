import CryptoKit
import Foundation
import RemoteKit

/// What carries an Outbox item into the Mac's mailbox at the relay (docs/iphone.md 5.3), as a notification action's
/// answer goes while the Mac is away (#691, section 7 step 4): the request sealed for the Mac's record key with the
/// phone's, and signed inside by the phone's device key and by the presence key of the session the person's tap opened
/// (4.3) — the two signatures the engine takes a mailbox item on. The Mac takes it when it next connects and writes a
/// receipt either way; the Outbox's entry says where the answer stands (`inMailbox`), and how long the Mac may still
/// take it is the item's lifetime (an hour for one that widens reach, a day for any other, 4.3).
///
/// The Outbox's general relay courier is #692's; this one carries the answers of notification actions, through
/// `Outbox.send(through:)`, which marks what went. It keeps no state of its own.
struct PushMailbox: OutboxCourier {
    /// What one item needs, read as it is sent: the pairing's two ends and the three keys that write for them.
    struct Ends: Sendable {
        let pairing: PairingID
        let device: DeviceID
        /// The Mac's record key: what the item is sealed for.
        let macRecordKey: P256.KeyAgreement.PublicKey
        /// The phone's record key: what seals it, authenticated mode.
        let recordKey: P256.KeyAgreement.PrivateKey
        let deviceKey: any DeviceKeySigning
        /// The session's presence signatures (`PresenceSession`): throws `KeysError.sessionNotOpen` outside one.
        let presence: any PresenceSigning
    }

    private let ends: @MainActor () async -> Ends?
    private let put: @MainActor (_ item: Data, _ id: ItemID, _ presence: Bool) async throws -> Void

    init(
        ends: @escaping @MainActor () async -> Ends?,
        put: @escaping @MainActor (_ item: Data, _ id: ItemID, _ presence: Bool) async throws -> Void
    ) {
        self.ends = ends
        self.put = put
    }

    /// Why nothing went, in words the Outbox's stopped round keeps; the item stays, to go again.
    static let unreachable = "pi²'s relay can't be reached, so your answer waits on this iPhone for now."

    func deliver(_ item: OutboxItem) async -> OutboxDelivery {
        guard let ends = await ends() else { return .unreachable(Self.unreachable) }
        do {
            // The item's id is its nonce (OutboxItem.make made it once, 16 bytes base64url): the engine takes the
            // request once, however many times the item is put or handed over.
            guard let id = ItemID(item.id), let params = try? JSON.parse(Data(item.params.utf8)) else {
                return .unreachable(Self.unreachable)
            }
            // The presence signature is asked of the session, which signs asynchronously (4.3): the item is made
            // twice from the same fields, first with throwaway keys for the exact text, then with the device key's
            // signature and the session's (`PresenceSignatures.attach`'s way) — the same `at`, so that the two
            // statements are the same text.
            let at = Date()
            let throwaway = P256.Signing.PrivateKey()
            let draft = try RequestItem.make(
                method: item.method, params: params, pairing: ends.pairing, device: ends.device, id: id, at: at,
                deviceKey: throwaway, presenceKey: throwaway)
            let text = Data(draft.statement.text.utf8)
            let signature = try await ends.presence.signPresence(text)
            let signed = try RequestItem.make(
                method: item.method, params: params, pairing: ends.pairing, device: ends.device, id: id, at: at,
                deviceKey: DeviceStatementSigner(ends.deviceKey),
                presenceKey: Presigned(text: text, signature: signature, publicKey: try presenceKey(ends.presence)))
            // Sealed for the Mac's record key, authenticated by the phone's (5.3).
            let sealed = try SealedItem.seal(
                signed.plaintext, to: ItemAddress(pairing: ends.pairing, reader: .mac, id: id),
                readerKey: ends.macRecordKey, writerKey: ends.recordKey)
            try await put(sealed, id, item.widens)
            return .inMailbox
        } catch {
            return .unreachable(Self.unreachable)
        }
    }

    private func presenceKey(_ presence: any PresenceSigning) throws -> P256.Signing.PublicKey {
        guard let der = try presence.presencePublicKeyDER(),
              let key = PublicKeys.signingKey(fromBase64URL: Base64URL.encode(der)) else {
            throw KeysError.missing("Face ID key")
        }
        return key
    }
}

/// A presence signature made already, given for exactly the text it was made over, as `RequestItem.make` asks.
struct Presigned: StatementSigner {
    let text: Data
    let signature: Data
    let publicKey: P256.Signing.PublicKey

    func sign(_ data: Data) throws -> Data {
        guard data == text, let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              publicKey.isValidSignature(ecdsa, for: data) else {
            throw RemoteKitError("presence key", "the presence signature is not over this text by the presence key")
        }
        return signature
    }
}
