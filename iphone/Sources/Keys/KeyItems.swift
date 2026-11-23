import Foundation
import LocalAuthentication
import Security

/// How a Keychain item of the phone is kept (docs/iphone.md 3.2). Every class is `ThisDeviceOnly`, so no item moves to
/// another device, by iCloud Keychain or by a backup restored there, and none is synchronised.
enum KeyProtection: Equatable, Sendable {
    /// `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`: readable only while the phone is unlocked, never backed up
    /// or moved, deleted by iOS when the passcode is turned off.
    case whenPasscodeSet
    /// As `whenPasscodeSet`, plus `biometryCurrentSet`: readable only under an authentication context Face ID itself
    /// evaluated, and gone for good once Face ID is enrolled again.
    case whenPasscodeSetUnderFaceID
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable once the phone has been unlocked after it started,
    /// so the notification service extension can open what arrives while it is locked.
    case afterFirstUnlock
}

/// The phone's Keychain items, by name. The Secure Enclave keys are kept as CryptoKit's wrapped blobs, which only this
/// phone's Secure Enclave can use; in the simulator, as the software keys' bytes (section 10).
enum KeyItem: String, CaseIterable, Sendable {
    /// The device key (P-256, signing): a Secure Enclave blob, made when a code is scanned.
    case deviceKey = "device-key"
    /// The presence key (P-256, signing): a Secure Enclave blob whose key is usable only under Face ID.
    case presenceKey = "presence-key"
    /// The presence key's public half, SPKI DER, so it can be given without Face ID (the pairing claim, a new key).
    case presencePublicKey = "presence-key-public"
    /// LocalAuthentication's hash of the enrolled faces when the presence key was made: a different one means Face ID
    /// was enrolled again and the key is gone (3.2).
    case presenceFaceIDState = "presence-key-face-id-state"
    /// Present while a presence key made after Face ID was enrolled again waits for the person to accept it on the Mac.
    case presenceKeyWaiting = "presence-key-waiting"
    /// The channel key (Curve25519): its 32 raw private bytes.
    case channelKey = "channel-key"
    /// The record key (P-256, key agreement): its raw private bytes.
    case recordKey = "record-key"
    /// The cache key (256 bits, symmetric), read only under the session's Face ID.
    case cacheKey = "cache-key"
    /// What the phone keeps of the Mac (its name, keys, the pairing's id, the relay, its addresses), as the bytes the
    /// pairing gives it to keep.
    case macRecord = "mac"

    var protection: KeyProtection {
        switch self {
        case .deviceKey, .presenceKey, .presencePublicKey, .presenceFaceIDState, .presenceKeyWaiting, .channelKey: .whenPasscodeSet
        case .cacheKey: .whenPasscodeSetUnderFaceID
        case .recordKey, .macRecord: .afterFirstUnlock
        }
    }

    /// Whether the item goes in the access group the notification service extension shares (3.2: the record key and
    /// what the phone keeps of the Mac).
    var shared: Bool { protection == .afterFirstUnlock }
}

/// Where the items are kept: the Keychain on a phone, a stand-in in tests and, where the Keychain refuses an unsigned
/// build, in the simulator. Bytes in, bytes out; nothing here interprets them.
protocol KeychainStore: Sendable {
    /// Keeps `data` as `item`, with the item's protection, in place of what it held.
    func write(_ data: Data, as item: KeyItem) throws
    /// The item's bytes, or nil if there is none. An item under Face ID is read with `context`, which must be one Face
    /// ID evaluated and which may show nothing more; without one it is refused.
    func read(_ item: KeyItem, context: LAContext?) throws -> Data?
    func delete(_ item: KeyItem) throws
    /// The name of every item this app can reach, whoever wrote it: for the wipe's check and the first launch.
    func names() throws -> [String]
    /// Removes every item this app can reach, ours or left by an earlier installation.
    func deleteEverything() throws
}

/// The data-protection Keychain, as a signed phone build has it.
struct SystemKeychain: KeychainStore {
    static let service = "dev.pi2.ios.keys"
    /// The access group shared with the notification service extension, for the items marked `shared`. Nil until the
    /// extension and its entitlement exist (#682): an unsigned build has no access group, and the items then go in the
    /// app's own.
    static let sharedAccessGroup: String? = nil

    private static var classes: [CFString] { [
        kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey, kSecClassCertificate, kSecClassIdentity,
    ] }

    private func query(_ item: KeyItem) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: item.rawValue,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
        if item.shared, let group = Self.sharedAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    func write(_ data: Data, as item: KeyItem) throws {
        try delete(item)
        var attributes = query(item)
        attributes[kSecValueData as String] = data
        switch item.protection {
        case .whenPasscodeSet:
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        case .afterFirstUnlock:
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenPasscodeSetUnderFaceID:
            attributes[kSecAttrAccessControl as String] = try KeyAccess.underFaceID(privateKey: false)
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeysError.keychain(status, "keep the \(item.what)") }
    }

    func read(_ item: KeyItem, context: LAContext?) throws -> Data? {
        var query = query(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if item.protection == .whenPasscodeSetUnderFaceID {
            guard let context else { throw KeysError.sessionNotOpen }
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw item.protection == .whenPasscodeSetUnderFaceID ? KeysError.needsFaceIDAgain : KeysError.phoneLocked
        default:
            throw KeysError.keychain(status, "read the \(item.what)")
        }
    }

    func delete(_ item: KeyItem) throws {
        let status = SecItemDelete(query(item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeysError.keychain(status, "delete the \(item.what)")
        }
    }

    func names() throws -> [String] {
        // Listing reads attributes only; a context that may show nothing keeps an item under Face ID from asking.
        let quiet = LAContext()
        quiet.interactionNotAllowed = true
        var names: [String] = []
        for itemClass in Self.classes {
            let query: [String: Any] = [
                kSecClass as String: itemClass,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecUseDataProtectionKeychain as String: true,
                kSecUseAuthenticationContext as String: quiet,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeysError.keychain(status, "list the Keychain")
            }
            for attributes in result as? [[String: Any]] ?? [] {
                let name = attributes[kSecAttrAccount as String] as? String
                    ?? attributes[kSecAttrLabel as String] as? String
                    ?? "an item with no name"
                names.append(name)
            }
        }
        return names.sorted()
    }

    func deleteEverything() throws {
        for itemClass in Self.classes {
            let query: [String: Any] = [
                kSecClass as String: itemClass,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecUseDataProtectionKeychain as String: true,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeysError.keychain(status, "empty the Keychain")
            }
        }
    }
}

/// The access controls of 3.2, made in one place so that the keys and the items cannot drift apart.
enum KeyAccess {
    /// The device key's: unlocked phone, this device only, usable to sign.
    static func deviceKey() throws -> SecAccessControl {
        try make([.privateKeyUsage])
    }

    /// The presence key's (`privateKey: true`) and the cache key's: as the device key's, plus the faces enrolled now.
    /// `biometryCurrentSet` alone, with no `.or(.devicePasscode)`: the passcode is what a thief who watched it has
    /// (4.5).
    static func underFaceID(privateKey: Bool) throws -> SecAccessControl {
        try make(privateKey ? [.privateKeyUsage, .biometryCurrentSet] : [.biometryCurrentSet])
    }

    private static func make(_ flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, flags, &error) else {
            _ = error?.takeRetainedValue()
            throw KeysError.noPasscode
        }
        return access
    }
}

extension KeyItem {
    /// What the item is, in words for an error.
    var what: String {
        switch self {
        case .deviceKey: "device key"
        case .presenceKey, .presencePublicKey, .presenceFaceIDState, .presenceKeyWaiting: "Face ID key"
        case .channelKey: "channel key"
        case .recordKey: "record key"
        case .cacheKey: "cache key"
        case .macRecord: "Mac's details"
        }
    }
}
