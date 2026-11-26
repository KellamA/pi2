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

/// The Mac's identity, channel and record keys. Its relay keys are one for each relay address (`KeyVault.relayKey`): a
/// relay is not trusted, so no key it has seen proves this Mac to another, and a pairing registered at one relay is
/// never shown to another (#678's security read).
package struct MacKeys: Sendable {
	package let identity: SigningKey
	package let channel: Curve25519.KeyAgreement.PrivateKey
	package let record: RecordKey

	/// The public halves, as `remote.hello` gives them to the engine, with the relay key of the relay in use. Whether the
	/// keys that can be in the Secure Enclave are: the Devices page says so when they are not (3.2).
	package func report(relay: SigningKey) -> JSONValue {
		.object([
			("identity", .string(PublicKeys.text(identity.publicKey))),
			("channel", .string(PublicKeys.text(channel.publicKey))),
			("record", .string(PublicKeys.text(record.publicKey))),
			("relay", .string(PublicKeys.text(relay.publicKey))),
			("secureEnclave", .bool(identity.inEnclave && relay.inEnclave)),
		])
	}
}

/// One paired device, as pi² Remote keeps it in its own list: added only when the engine says it paired the device
/// (`paired`), never from what `start` lists (3.4, 5.5), and never on a relay's word: the device key and the App Attest
/// key id the relay's `addDevice` is given (#678) are these, the engine's verified claim's, never what a relay's
/// `joined` says. Nothing but the engine's `paired`, `revoke`, `start` and `presenceKey` changes the list: `paired` adds a
/// device, `revoke` drops one, `start` drops those it does not name and gives those it names their presence key, and
/// `presenceKey` gives one device the key the person accepted on the Mac (#891). The device, channel and record keys never
/// change once the device is added; a presence key comes from the engine alone, never from a phone's offer.
package struct ListedDevice: Sendable {
	package let id: DeviceID
	package let deviceKey: P256.Signing.PublicKey
	package let presenceKey: P256.Signing.PublicKey?
	package let channelKey: Curve25519.KeyAgreement.PublicKey
	package let recordKey: P256.KeyAgreement.PublicKey
	/// The App Attest key the engine checked at pairing (DCAppAttestService's id, base64), for the relay's `addDevice`.
	package let attestKeyId: String?

	package init(id: DeviceID, deviceKey: P256.Signing.PublicKey, presenceKey: P256.Signing.PublicKey?, channelKey: Curve25519.KeyAgreement.PublicKey, recordKey: P256.KeyAgreement.PublicKey, attestKeyId: String? = nil) {
		self.id = id
		self.deviceKey = deviceKey
		self.presenceKey = presenceKey
		self.channelKey = channelKey
		self.recordKey = recordKey
		self.attestKeyId = attestKeyId
	}

	/// The same device with another presence key, or none (#891).
	func withPresenceKey(_ key: P256.Signing.PublicKey?) -> ListedDevice {
		ListedDevice(id: id, deviceKey: deviceKey, presenceKey: key, channelKey: channelKey, recordKey: recordKey, attestKeyId: attestKeyId)
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
		var attestKeyId: String?
		if let given = json["attestKeyId"], !given.isNull {
			guard let text = given.stringValue, (1 ... 128).contains(text.utf8.count),
			      text.utf8.allSatisfy({ SessionID.idByte($0) || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "=") })
			else { return nil }
			attestKeyId = text
		}
		self.init(id: id, deviceKey: deviceKey, presenceKey: presenceKey, channelKey: channelKey, recordKey: recordKey, attestKeyId: attestKeyId)
	}

	package var json: JSONValue {
		.object([
			("id", .string(id.text)), ("deviceKey", .string(PublicKeys.text(deviceKey))),
			("presenceKey", presenceKey.map { .string(PublicKeys.text($0)) } ?? .null),
			("channelKey", .string(PublicKeys.text(channelKey))), ("recordKey", .string(PublicKeys.text(recordKey))),
			("attestKeyId", attestKeyId.map(JSONValue.string) ?? .null),
		])
	}
}

/// pi² Remote's own list of devices and the home key (#845), kept together in one item, written whole: the two are
/// saved together or not at all (#675's security read, S1). So no list can be on disk without the device a revocation
/// dropped while the key that device holds is still beside it: a revocation whose write fails leaves the list and the
/// key as they were, and the next `start`, which no longer names the device, drops it and makes a new key before
/// anything is advertised.
///
/// `{"v":1,"devices":[…],"home":<the home key's 32 bytes in base64url>,"relay":{"pairing":…,"address":…}}`, `home` left
/// out while there is no key, `relay` while pi² Remote registered no pairing at a relay: the pairing it registered and
/// the relay's address, to which alone the pairing's id is shown (#678).
package struct KeptDevices: Sendable {
	package var devices: [ListedDevice]
	package var homeKey: HomeKey?
	package var registration: RelayRegistration?

	package init(devices: [ListedDevice] = [], homeKey: HomeKey? = nil, registration: RelayRegistration? = nil) {
		self.devices = devices
		self.homeKey = homeKey
		self.registration = registration
	}

	package var data: Data {
		var members: [(String, JSONValue)] = [("v", .integer(1)), ("devices", .array(devices.map(\.json)))]
		if let homeKey { members.append(("home", .string(Base64URL.encode(homeKey.rawRepresentation)))) }
		if let registration { members.append(("relay", .object([("pairing", .string(registration.pairing.text)), ("address", .string(registration.relay))]))) }
		return JSON.write(.object(members))
	}

	package init(data: Data) throws {
		let value = try JSON.parse(data)
		guard value["v"]?.integerValue == 1, case let .array(items)? = value["devices"] else { throw Refused("the list of devices is not one pi² Remote wrote") }
		devices = try items.map { item in
			guard let device = ListedDevice(json: item) else { throw Refused("a device in the list is not one pi² Remote wrote") }
			return device
		}
		if let home = value["home"] {
			guard let text = home.stringValue, let raw = Base64URL.decode(text), let key = HomeKey(rawRepresentation: raw) else { throw Refused("the home key is not one pi² Remote wrote") }
			homeKey = key
		}
		if let relay = value["relay"] {
			guard let pairing = relay["pairing"]?.stringValue.flatMap(PairingID.init), let address = relay["address"]?.stringValue else {
				throw Refused("the relay's pairing is not one pi² Remote wrote")
			}
			registration = RelayRegistration(pairing: pairing, relay: address)
		}
	}
}

/// Where a build keeps the Mac's keys and its list of devices.
package protocol KeyVault: Sendable {
	/// What it is, for the log.
	var name: String { get }
	/// The Mac's keys, made the first time.
	func macKeys() throws -> MacKeys
	/// The relay key for the relay at `address`, made the first time that address is used: one key for each relay.
	func relayKey(for address: String) throws -> SigningKey
	/// pi² Remote's own list of devices and the home key (#845, remotekit.md "The home key"), empty and none before the
	/// first pairing.
	func kept() throws -> KeptDevices
	/// Keeps both, in one write, in place of what was kept before: both or neither.
	func keep(_ kept: KeptDevices) throws
}

package enum KeyVaults {
	/// The vault of a build of `kind` on `folder`. Each kind has only its own compiled in.
	package static func forBuild(_ kind: BuildKind, folder: URL) throws -> any KeyVault {
		switch kind {
		case .development:
			#if PI2_DEVELOPMENT
			return KeyFiles(folder: folder)
			#else
			throw Refused("a release build keeps no keys in files")
			#endif
		case .release:
			#if PI2_DEVELOPMENT
			throw Refused("a development build never uses the Keychain or the Secure Enclave")
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
	/// Adds the item, or replaces it (the list of devices).
	func write(_ account: String, _ data: Data) throws
	/// Adds the item if there is none: true if added, false if one was there (a key, which is never replaced).
	func add(_ account: String, _ data: Data) throws -> Bool
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
		MacKeys(identity: try signing("identity"), channel: try channel(), record: try record())
	}

	/// The relay key for `address`, in its own item, `relay <address>`.
	package func relayKey(for address: String) throws -> SigningKey { try signing("relay \(address)") }

	private func stored(_ account: String) throws -> (inEnclave: Bool, key: Data)? {
		guard let data = try items.read(account) else { return nil }
		guard let value = try? JSON.parse(data), let place = value["in"]?.stringValue, let text = value["key"]?.stringValue,
		      let key = Base64URL.decode(text), place == "enclave" || place == "software"
		else { throw Refused("the Keychain's \(account) key is not one pi² Remote wrote") }
		return (place == "enclave", key)
	}

	private func encoded(_ inEnclave: Bool, _ key: Data) -> Data {
		JSON.write(.object([("in", .string(inEnclave ? "enclave" : "software")), ("key", .string(Base64URL.encode(key)))]))
	}

	/// A key read, or made and added once, never written over: if another pi² Remote added one meanwhile (two started
	/// at once), its key is read back and the one made here dropped, so no helper goes on signing with a key whose item
	/// is gone (#675's security read A, S2).
	private func key<K>(_ account: String, load: (_ inEnclave: Bool, _ data: Data) throws -> K, make: () throws -> (key: K, inEnclave: Bool, data: Data)) throws -> K {
		if let (inEnclave, data) = try stored(account) { return try load(inEnclave, data) }
		let made = try make()
		if try items.add(account, encoded(made.inEnclave, made.data)) { return made.key }
		guard let (inEnclave, data) = try stored(account) else { throw Refused("the Keychain's \(account) key was added by another pi² Remote, and cannot be read") }
		return try load(inEnclave, data)
	}

	private func signing(_ account: String) throws -> SigningKey {
		try key(account, load: { inEnclave, data in
			inEnclave ? try enclave.signingKey(blob: data) : .software(try P256.Signing.PrivateKey(rawRepresentation: data))
		}, make: {
			if enclave.isAvailable {
				let (key, blob) = try enclave.makeSigningKey()
				return (key, true, blob)
			}
			let key = P256.Signing.PrivateKey()
			return (.software(key), false, key.rawRepresentation)
		})
	}

	private func record() throws -> RecordKey {
		try key("record", load: { inEnclave, data in
			inEnclave ? try enclave.agreementKey(blob: data) : .software(try P256.KeyAgreement.PrivateKey(rawRepresentation: data))
		}, make: {
			if enclave.isAvailable {
				let (key, blob) = try enclave.makeAgreementKey()
				return (key, true, blob)
			}
			let key = P256.KeyAgreement.PrivateKey()
			return (.software(key), false, key.rawRepresentation)
		})
	}

	private func channel() throws -> Curve25519.KeyAgreement.PrivateKey {
		try key("channel", load: { inEnclave, data in
			guard !inEnclave else { throw Refused("the Keychain's channel key is not one pi² Remote wrote") }
			return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
		}, make: {
			let key = Curve25519.KeyAgreement.PrivateKey()
			return (key, false, key.rawRepresentation)
		})
	}

	/// The list of devices and the home key, in one item, `devices`: in the Keychain, never the Secure Enclave, since the
	/// home key is a secret the phones share and its bytes are sent to them. One item is one write: both or neither.
	package func kept() throws -> KeptDevices {
		guard let data = try items.read("devices") else { return KeptDevices() }
		return try KeptDevices(data: data)
	}

	package func keep(_ kept: KeptDevices) throws {
		try items.write("devices", kept.data)
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
	/// The list of devices and the home key, in one file: written whole to a new file and moved into place, so both or
	/// neither.
	package var devicesFile: URL { folder.appendingPathComponent("remote-devices.json") }

	/// The file read: `{"v":1,"identity","channel","record","relays":{<address>:<key>}}`, each key's raw bytes in base64url.
	private func stored() throws -> [(String, JSONValue)]? {
		guard let data = try PrivateFile.read(keysFile) else { return nil }
		guard let value = try? JSON.parse(data), value["v"]?.integerValue == 1, case let .object(members) = value else {
			throw Refused("remote-keys.json is not one pi² Remote wrote")
		}
		return members
	}

	private static func raw(_ members: [(String, JSONValue)], _ name: String) throws -> Data {
		guard let text = JSONValue.object(members)[name]?.stringValue, let bytes = Base64URL.decode(text) else { throw Refused("remote-keys.json has no \(name) key") }
		return bytes
	}

	package func macKeys() throws -> MacKeys {
		if let members = try stored() {
			return MacKeys(
				identity: .software(try P256.Signing.PrivateKey(rawRepresentation: Self.raw(members, "identity"))),
				channel: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.raw(members, "channel")),
				record: .software(try P256.KeyAgreement.PrivateKey(rawRepresentation: Self.raw(members, "record"))))
		}
		let identity = P256.Signing.PrivateKey(), channel = Curve25519.KeyAgreement.PrivateKey(), record = P256.KeyAgreement.PrivateKey()
		// Made once: if another pi² Remote made the file meanwhile, its keys are the Mac's (S2).
		guard try PrivateFile.create(keysFile, JSON.write(.object([
			("v", .integer(1)), ("identity", .string(Base64URL.encode(identity.rawRepresentation))),
			("channel", .string(Base64URL.encode(channel.rawRepresentation))), ("record", .string(Base64URL.encode(record.rawRepresentation))),
			("relays", .object([])),
		])))
		else { return try macKeys() }
		return MacKeys(identity: .software(identity), channel: channel, record: .software(record))
	}

	package func relayKey(for address: String) throws -> SigningKey {
		guard var members = try stored() else { throw Refused("remote-keys.json does not exist yet") }
		var relays: [(String, JSONValue)] = []
		if case let .object(given)? = JSONValue.object(members)["relays"] { relays = given }
		if let text = relays.first(where: { $0.0.utf8.elementsEqual(address.utf8) })?.1.stringValue, let bytes = Base64URL.decode(text) {
			return .software(try P256.Signing.PrivateKey(rawRepresentation: bytes))
		}
		let key = P256.Signing.PrivateKey()
		relays.append((address, .string(Base64URL.encode(key.rawRepresentation))))
		members.removeAll { $0.0 == "relays" || $0.0 == "relay" }
		members.append(("relays", .object(relays)))
		try PrivateFile.write(keysFile, JSON.write(.object(members)))
		return .software(key)
	}

	package func kept() throws -> KeptDevices {
		guard let data = try PrivateFile.read(devicesFile) else { return KeptDevices() }
		return try KeptDevices(data: data)
	}

	package func keep(_ kept: KeptDevices) throws {
		try PrivateFile.write(devicesFile, kept.data)
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
			throw Refused("\(url.lastPathComponent) could not be opened (\(String(cString: strerror(errno))))")
		}
		defer { close(descriptor) }
		var info = stat()
		guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Refused("\(url.lastPathComponent) is not a file") }
		guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Refused("\(url.lastPathComponent) can be read by others, or is not this user's") }
		guard info.st_size <= 1_000_000 else { throw Refused("\(url.lastPathComponent) is too long") }
		var data = Data(count: Int(info.st_size))
		let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
		guard count == Int(info.st_size) else { throw Refused("\(url.lastPathComponent) could not be read") }
		return data
	}

	/// Writes `url` only if there is no such file: true if written, false if one was there.
	package static func create(_ url: URL, _ data: Data) throws -> Bool {
		let temporary = try written(beside: url, data)
		defer { unlink(temporary.path) }
		if link(temporary.path, url.path) == 0 { return true }
		if errno == EEXIST { return false }
		throw Refused("\(url.lastPathComponent) could not be written (\(String(cString: strerror(errno))))")
	}

	/// `data` in a new file beside `url`, 0600, synced.
	private static func written(beside url: URL, _ data: Data) throws -> URL {
		let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0 ... .max))")
		let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
		guard descriptor >= 0 else { throw Refused("\(url.lastPathComponent) could not be written (\(String(cString: strerror(errno))))") }
		let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
		let synced = fsync(descriptor) == 0
		close(descriptor)
		guard count == data.count, synced else {
			unlink(temporary.path)
			throw Refused("\(url.lastPathComponent) could not be written")
		}
		return temporary
	}

	package static func write(_ url: URL, _ data: Data) throws {
		let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0 ... .max))")
		let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
		guard descriptor >= 0 else { throw Refused("\(url.lastPathComponent) could not be written (\(String(cString: strerror(errno))))") }
		let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
		let synced = fsync(descriptor) == 0
		close(descriptor)
		guard written == data.count, synced, rename(temporary.path, url.path) == 0 else {
			unlink(temporary.path)
			throw Refused("\(url.lastPathComponent) could not be written")
		}
	}
}
