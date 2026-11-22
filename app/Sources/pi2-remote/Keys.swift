import CryptoKit
import Foundation
import RemoteKit

// The Mac's keys (docs/iphone.md 3.2) and pi² Remote's own list of the paired devices' keys (3.4, 5.5), and where each
// build keeps them:
//
// - a release build: the identity key and the relay key in the Secure Enclave where there is one (decision 30), the
//   record key there too when there is one (CryptoKit's HPKE takes it from macOS 14), the channel key, which is
//   Curve25519 and cannot be there, in the data-protection Keychain, and the list of devices there too
//   (`KeychainVault`); on a Mac without a Secure Enclave, every key in the Keychain;
// - a development build, and every throwaway copy: all of them in two files in its own data folder, readable by the
//   person alone (`KeyFiles`). It never calls the Keychain or the Secure Enclave: the code that does is not compiled
//   into it (Keychain.swift), and `pi2-remote-helper-check` checks its executable names none of their functions.

/// A P-256 key that signs: in software, or in the Secure Enclave.
package enum SigningKey: StatementSigner, @unchecked Sendable {
	case software(P256.Signing.PrivateKey)
	case enclave(SecureEnclave.P256.Signing.PrivateKey)

	package var publicKey: P256.Signing.PublicKey {
		switch self {
		case let .software(key): key.publicKey
		case let .enclave(key): key.publicKey
		}
	}

	package func sign(_ data: Data) throws -> Data {
		switch self {
		case let .software(key): try key.sign(data)
		case let .enclave(key): try key.sign(data)
		}
	}

	package var inEnclave: Bool { if case .enclave = self { true } else { false } }
}

/// The record key, which opens items sealed to the Mac (P10 seals and opens with it).
package enum RecordKey: @unchecked Sendable {
	case software(P256.KeyAgreement.PrivateKey)
	case enclave(SecureEnclave.P256.KeyAgreement.PrivateKey)

	package var publicKey: P256.KeyAgreement.PublicKey {
		switch self {
		case let .software(key): key.publicKey
		case let .enclave(key): key.publicKey
		}
	}

	package var inEnclave: Bool { if case .enclave = self { true } else { false } }
}

/// The Mac's four keys.
package struct MacKeys: Sendable {
	package let identity: SigningKey
	package let relay: SigningKey
	package let channel: Curve25519.KeyAgreement.PrivateKey
	package let record: RecordKey

	/// Whether the keys that can be in the Secure Enclave are: the Devices page says so when they are not (3.2).
	package var secureEnclave: Bool { identity.inEnclave && relay.inEnclave }

	/// The public halves, as `remote.hello` gives them to the engine.
	package var report: JSONValue {
		.object([
			("identity", .string(PublicKeys.text(identity.publicKey))),
			("channel", .string(PublicKeys.text(channel.publicKey))),
			("record", .string(PublicKeys.text(record.publicKey))),
			("relay", .string(PublicKeys.text(relay.publicKey))),
			("secureEnclave", .bool(secureEnclave)),
		])
	}
}

/// One paired device, as pi² Remote keeps it in its own list: added only when the engine says it paired the device
/// (`paired`), never from what `start` lists (3.4, 5.5).
package struct ListedDevice: Sendable {
	package let id: DeviceID
	package let deviceKey: P256.Signing.PublicKey
	package let presenceKey: P256.Signing.PublicKey?
	package let channelKey: Curve25519.KeyAgreement.PublicKey
	package let recordKey: P256.KeyAgreement.PublicKey

	package init(id: DeviceID, deviceKey: P256.Signing.PublicKey, presenceKey: P256.Signing.PublicKey?, channelKey: Curve25519.KeyAgreement.PublicKey, recordKey: P256.KeyAgreement.PublicKey) {
		self.id = id
		self.deviceKey = deviceKey
		self.presenceKey = presenceKey
		self.channelKey = channelKey
		self.recordKey = recordKey
	}

	/// From the engine's `paired` event's `device`, whose keys are written as RemoteKit writes them.
	package init?(json: JSONValue) {
		guard let idText = json["id"]?.stringValue, let id = DeviceID(idText),
		      let deviceText = json["deviceKey"]?.stringValue, let deviceKey = PublicKeys.signingKey(fromBase64URL: deviceText),
		      let channelText = json["channelKey"]?.stringValue, let channelKey = PublicKeys.channelKey(fromBase64URL: channelText),
		      let recordText = json["recordKey"]?.stringValue, let recordKey = PublicKeys.agreementKey(fromBase64URL: recordText)
		else { return nil }
		var presenceKey: P256.Signing.PublicKey?
		if let presence = json["presenceKey"], !presence.isNull {
			guard let text = presence.stringValue, let key = PublicKeys.signingKey(fromBase64URL: text) else { return nil }
			presenceKey = key
		}
		self.init(id: id, deviceKey: deviceKey, presenceKey: presenceKey, channelKey: channelKey, recordKey: recordKey)
	}

	package var json: JSONValue {
		.object([
			("id", .string(id.text)), ("deviceKey", .string(PublicKeys.text(deviceKey))),
			("presenceKey", presenceKey.map { .string(PublicKeys.text($0)) } ?? .null),
			("channelKey", .string(PublicKeys.text(channelKey))), ("recordKey", .string(PublicKeys.text(recordKey))),
		])
	}

	package static func list(_ devices: [ListedDevice]) -> Data {
		JSON.write(.object([("v", .integer(1)), ("devices", .array(devices.map(\.json)))]))
	}

	package static func read(list data: Data) throws -> [ListedDevice] {
		let value = try JSON.parse(data)
		guard value["v"]?.integerValue == 1, case let .array(items)? = value["devices"] else { throw Refusal("the list of devices is not one pi² Remote wrote") }
		return try items.map { item in
			guard let device = ListedDevice(json: item) else { throw Refusal("a device in the list is not one pi² Remote wrote") }
			return device
		}
	}
}

/// Where a build keeps the Mac's keys and its list of devices.
package protocol KeyVault: Sendable {
	/// What it is, for the log.
	var name: String { get }
	/// The Mac's keys, made the first time.
	func macKeys() throws -> MacKeys
	func devices() throws -> [ListedDevice]
	func saveDevices(_ devices: [ListedDevice]) throws
}

package enum KeyVaults {
	/// The vault of a build of `kind` on `folder`. Each kind has only its own compiled in.
	package static func forBuild(_ kind: BuildKind, folder: URL) throws -> any KeyVault {
		switch kind {
		case .development:
			#if PI2_DEVELOPMENT
			return KeyFiles(folder: folder)
			#else
			throw Refusal("a release build keeps no keys in files")
			#endif
		case .release:
			#if PI2_DEVELOPMENT
			throw Refusal("a development build never uses the Keychain or the Secure Enclave")
			#else
			return KeychainVault(items: KeychainItems(), enclave: SecureEnclaveKeys())
			#endif
		}
	}
}

// ---- A release build's: the Keychain and the Secure Enclave, behind two protocols so that the logic is checked with
// stand-ins (pi2-remote-helper-check); the real ones are in Keychain.swift, compiled only into a release build.

/// Items of the data-protection Keychain, by account.
package protocol SecretItems: Sendable {
	func read(_ account: String) throws -> Data?
	/// Adds the item, or replaces it.
	func write(_ account: String, _ data: Data) throws
}

/// The Secure Enclave, as far as pi² Remote uses it. A key in it is kept as CryptoKit's `dataRepresentation`, which is
/// sealed by the Secure Enclave and of use on this Mac alone.
package protocol Enclave: Sendable {
	var isAvailable: Bool { get }
	func makeSigningKey() throws -> (key: SigningKey, blob: Data)
	func signingKey(blob: Data) throws -> SigningKey
	func makeAgreementKey() throws -> (key: RecordKey, blob: Data)
	func agreementKey(blob: Data) throws -> RecordKey
}

/// A release build's keys: the identity, relay and record keys in the Secure Enclave where there is one, everything else
/// in the Keychain. Each item is `{"in":"enclave"|"software","key":<base64url>}`; an enclave key that cannot be used
/// (the Keychain was carried to another Mac) is a refusal, never a new key made in silence, which would unpair every
/// phone.
package struct KeychainVault: KeyVault {
	package let items: any SecretItems
	package let enclave: any Enclave
	package var name: String { "the Keychain\(enclave.isAvailable ? " and the Secure Enclave" : " (this Mac has no Secure Enclave)")" }

	package init(items: any SecretItems, enclave: any Enclave) {
		self.items = items
		self.enclave = enclave
	}

	package func macKeys() throws -> MacKeys {
		MacKeys(identity: try signing("identity"), relay: try signing("relay"), channel: try channel(), record: try record())
	}

	private func stored(_ account: String) throws -> (inEnclave: Bool, key: Data)? {
		guard let data = try items.read(account) else { return nil }
		guard let value = try? JSON.parse(data), let place = value["in"]?.stringValue, let text = value["key"]?.stringValue,
		      let key = Base64URL.decode(text), place == "enclave" || place == "software"
		else { throw Refusal("the Keychain's \(account) key is not one pi² Remote wrote") }
		return (place == "enclave", key)
	}

	private func store(_ account: String, inEnclave: Bool, _ key: Data) throws {
		try items.write(account, JSON.write(.object([("in", .string(inEnclave ? "enclave" : "software")), ("key", .string(Base64URL.encode(key)))])))
	}

	private func signing(_ account: String) throws -> SigningKey {
		if let (inEnclave, data) = try stored(account) {
			if inEnclave { return try enclave.signingKey(blob: data) }
			return .software(try P256.Signing.PrivateKey(rawRepresentation: data))
		}
		if enclave.isAvailable {
			let (key, blob) = try enclave.makeSigningKey()
			try store(account, inEnclave: true, blob)
			return key
		}
		let key = P256.Signing.PrivateKey()
		try store(account, inEnclave: false, key.rawRepresentation)
		return .software(key)
	}

	private func record() throws -> RecordKey {
		if let (inEnclave, data) = try stored("record") {
			if inEnclave { return try enclave.agreementKey(blob: data) }
			return .software(try P256.KeyAgreement.PrivateKey(rawRepresentation: data))
		}
		if enclave.isAvailable {
			let (key, blob) = try enclave.makeAgreementKey()
			try store("record", inEnclave: true, blob)
			return key
		}
		let key = P256.KeyAgreement.PrivateKey()
		try store("record", inEnclave: false, key.rawRepresentation)
		return .software(key)
	}

	private func channel() throws -> Curve25519.KeyAgreement.PrivateKey {
		if let (inEnclave, data) = try stored("channel") {
			guard !inEnclave else { throw Refusal("the Keychain's channel key is not one pi² Remote wrote") }
			return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
		}
		let key = Curve25519.KeyAgreement.PrivateKey()
		try store("channel", inEnclave: false, key.rawRepresentation)
		return key
	}

	package func devices() throws -> [ListedDevice] {
		guard let data = try items.read("devices") else { return [] }
		return try ListedDevice.read(list: data)
	}

	package func saveDevices(_ devices: [ListedDevice]) throws {
		try items.write("devices", ListedDevice.list(devices))
	}
}

#if PI2_DEVELOPMENT
/// A development build's keys and list of devices: `remote-keys.json` and `remote-devices.json` in its own data folder,
/// readable and writable by the person alone (0600), each written whole to a new file and moved into place. A file
/// another user owns, that others may read, or that is a link, is refused.
package struct KeyFiles: KeyVault {
	package let folder: URL
	package var name: String { "files in the data folder (a development build)" }

	package init(folder: URL) { self.folder = folder }

	package var keysFile: URL { folder.appendingPathComponent("remote-keys.json") }
	package var devicesFile: URL { folder.appendingPathComponent("remote-devices.json") }

	package func macKeys() throws -> MacKeys {
		if let data = try PrivateFile.read(keysFile) {
			guard let value = try? JSON.parse(data), value["v"]?.integerValue == 1 else { throw Refusal("remote-keys.json is not one pi² Remote wrote") }
			func raw(_ name: String) throws -> Data {
				guard let text = value[name]?.stringValue, let bytes = Base64URL.decode(text) else { throw Refusal("remote-keys.json has no \(name) key") }
				return bytes
			}
			return MacKeys(
				identity: .software(try P256.Signing.PrivateKey(rawRepresentation: raw("identity"))),
				relay: .software(try P256.Signing.PrivateKey(rawRepresentation: raw("relay"))),
				channel: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw("channel")),
				record: .software(try P256.KeyAgreement.PrivateKey(rawRepresentation: raw("record"))))
		}
		let identity = P256.Signing.PrivateKey(), relay = P256.Signing.PrivateKey()
		let channel = Curve25519.KeyAgreement.PrivateKey(), record = P256.KeyAgreement.PrivateKey()
		try PrivateFile.write(keysFile, JSON.write(.object([
			("v", .integer(1)), ("identity", .string(Base64URL.encode(identity.rawRepresentation))),
			("relay", .string(Base64URL.encode(relay.rawRepresentation))), ("channel", .string(Base64URL.encode(channel.rawRepresentation))),
			("record", .string(Base64URL.encode(record.rawRepresentation))),
		])))
		return MacKeys(identity: .software(identity), relay: .software(relay), channel: channel, record: .software(record))
	}

	package func devices() throws -> [ListedDevice] {
		guard let data = try PrivateFile.read(devicesFile) else { return [] }
		return try ListedDevice.read(list: data)
	}

	package func saveDevices(_ devices: [ListedDevice]) throws {
		try PrivateFile.write(devicesFile, ListedDevice.list(devices))
	}
}
#endif

/// A file only the person may read: read without following a link, refused unless it is this user's with no access for
/// anyone else; written whole to a new file, 0600, and moved over the old one.
package enum PrivateFile {
	package static func read(_ url: URL) throws -> Data? {
		let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
		if descriptor < 0 {
			if errno == ENOENT { return nil }
			throw Refusal("\(url.lastPathComponent) could not be opened (\(String(cString: strerror(errno))))")
		}
		defer { close(descriptor) }
		var info = stat()
		guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Refusal("\(url.lastPathComponent) is not a file") }
		guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Refusal("\(url.lastPathComponent) can be read by others, or is not this user's") }
		guard info.st_size <= 1_000_000 else { throw Refusal("\(url.lastPathComponent) is too long") }
		var data = Data(count: Int(info.st_size))
		let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
		guard count == Int(info.st_size) else { throw Refusal("\(url.lastPathComponent) could not be read") }
		return data
	}

	package static func write(_ url: URL, _ data: Data) throws {
		let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0 ... .max))")
		let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
		guard descriptor >= 0 else { throw Refusal("\(url.lastPathComponent) could not be written (\(String(cString: strerror(errno))))") }
		let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
		let synced = fsync(descriptor) == 0
		close(descriptor)
		guard written == data.count, synced, rename(temporary.path, url.path) == 0 else {
			unlink(temporary.path)
			throw Refusal("\(url.lastPathComponent) could not be written")
		}
	}
}
