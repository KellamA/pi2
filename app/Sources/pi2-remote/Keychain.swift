#if !PI2_DEVELOPMENT
import CryptoKit
import Foundation
import Security

// The calls to the Keychain and the Secure Enclave, compiled only into a release build: a development build, and so
// every throwaway copy, has none of them in its executable, and cannot ask macOS for a Keychain item or make a Secure
// Enclave key, whatever it is told (CONTRIBUTING.md, "Testing safely"). The logic that uses them is `KeychainVault`
// (Keys.swift), checked with stand-ins by pi2-remote-helper-check. These two are never run on a Mac where pi² is in
// real use by an agent; the owner runs them first on a release build signed with pi²'s Developer ID (#675).

/// The data-protection Keychain, service `dev.pi2.remote`, this device only, after the first unlock (pi² Remote runs
/// at login, before the person may have unlocked anything). Its access group is the one the signed helper's
/// entitlements give it (P14, #686, adds `keychain-access-groups`): without that entitlement every call fails, and
/// pi² Remote stops rather than keep its keys anywhere else.
struct KeychainItems: SecretItems {
	static let service = "dev.pi2.remote"

	private func base(_ account: String) -> [CFString: Any] {
		[
			kSecClass: kSecClassGenericPassword,
			kSecAttrService: Self.service,
			kSecAttrAccount: account,
			kSecUseDataProtectionKeychain: true,
		]
	}

	func read(_ account: String) throws -> Data? {
		var query = base(account)
		query[kSecReturnData] = true
		query[kSecMatchLimit] = kSecMatchLimitOne
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess, let data = result as? Data else { throw Refusal("the Keychain's \(account) item could not be read (status \(status))") }
		return data
	}

	func add(_ account: String, _ data: Data) throws -> Bool {
		var item = base(account)
		item[kSecValueData] = data
		item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		let added = SecItemAdd(item as CFDictionary, nil)
		if added == errSecDuplicateItem { return false }
		guard added == errSecSuccess else { throw Refusal("the Keychain's \(account) item could not be added (status \(added))") }
		return true
	}

	func write(_ account: String, _ data: Data) throws {
		let update = SecItemUpdate(base(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
		if update == errSecSuccess { return }
		guard update == errSecItemNotFound else { throw Refusal("the Keychain's \(account) item could not be written (status \(update))") }
		var item = base(account)
		item[kSecValueData] = data
		item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		let added = SecItemAdd(item as CFDictionary, nil)
		guard added == errSecSuccess else { throw Refusal("the Keychain's \(account) item could not be added (status \(added))") }
	}
}

/// The Mac's Secure Enclave (Apple silicon, or an Intel Mac with a T2 chip). Its keys are usable after the first unlock,
/// on this Mac alone, and ask for nothing when used: no Touch ID, no password (they sign at every connection, with
/// nobody at the Mac).
struct SecureEnclaveKeys: Enclave {
	var isAvailable: Bool { SecureEnclave.isAvailable }

	private func access() throws -> SecAccessControl {
		var error: Unmanaged<CFError>?
		guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error) else {
			throw Refusal("the Secure Enclave's access could not be set")
		}
		return control
	}

	func makeSigningKey() throws -> (key: SigningKey, blob: Data) {
		let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access())
		return (.enclave(key), key.dataRepresentation)
	}

	func signingKey(blob: Data) throws -> SigningKey {
		do {
			return .enclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob))
		} catch {
			throw Refusal("a key in the Secure Enclave cannot be used on this Mac")
		}
	}

	func makeAgreementKey() throws -> (key: RecordKey, blob: Data) {
		let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access())
		return (.enclave(key), key.dataRepresentation)
	}

	func agreementKey(blob: Data) throws -> RecordKey {
		do {
			return .enclave(try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob))
		} catch {
			throw Refusal("a key in the Secure Enclave cannot be used on this Mac")
		}
	}
}
#endif
