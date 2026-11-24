import Foundation
import Security

/// Reads the keys a push is opened with from the Keychain items `Keys/` writes in the access group the app shares with
/// the service extension (docs/iphone.md 3.2: the record key, and what the phone keeps of the Mac, both
/// `AfterFirstUnlockThisDeviceOnly`, so a push that comes while the phone is locked still opens). The extension cannot
/// build `Keys/`, so the items' names are repeated here and must stay as `KeyItem` and `SystemKeychain` name them
/// (`PushTests` checks it).
///
/// An unsigned build has no Keychain at all (`errSecMissingEntitlement`, docs/iphone-app.md "The extensions"), so in the
/// simulator this finds nothing and every push shows the placeholder.
struct PushKeychain: Sendable {
    static let service = "dev.pi2.ios.keys"
    static let recordKeyItem = "record-key"
    static let macRecordItem = "mac"
    /// The access group shared with the app: `SystemKeychain.sharedAccessGroup`, nil until #682 gives the two the
    /// Keychain Sharing entitlement, and the items are then in the app's own group, which the extension cannot read.
    static let accessGroup: String? = nil

    /// The keys, or nil if the phone has none (not paired, or the items cannot be read).
    func keys() throws -> PushKeys? {
        guard let record = try read(Self.recordKeyItem), let mac = try read(Self.macRecordItem) else { return nil }
        return try PushMacRecord.keys(recordKey: record, macRecord: mac)
    }

    private func read(_ account: String) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let group = Self.accessGroup { query[kSecAttrAccessGroup as String] = group }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw PushRefusal.noKeys
        }
    }
}

/// What the phone keeps of its Mac (`KeyItem.macRecord`), as far as a push needs it. Its form is the pairing's (#680's
/// pairing, not built yet: "bytes in, bytes out"); this reads it as #690 assumes the pairing will keep it, a JSON
/// object holding at least `pairing`, `device` (this phone's id, which `paired` gives), `identityKey` and `recordKey`
/// (the Mac's, SPKI DER in base64url, as the pairing payload's `i` and `r`). The pairing either keeps it so or changes
/// this reading with it.
enum PushMacRecord {
    static func keys(recordKey: Data, macRecord: Data) throws -> PushKeys {
        guard let record = try? JSONSerialization.jsonObject(with: macRecord) as? [String: Any],
              let pairing = record["pairing"] as? String, let device = record["device"] as? String,
              let identity = (record["identityKey"] as? String).flatMap(PushBase64URL.decode),
              let macRecord = (record["recordKey"] as? String).flatMap(PushBase64URL.decode)
        else { throw PushRefusal.noKeys }
        return PushKeys(pairing: pairing, device: device, recordKey: recordKey, macRecordKey: macRecord, macIdentityKey: identity)
    }
}
