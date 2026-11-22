import CryptoKit
import Foundation
@_spi(Vectors) import RemoteKit

/// The published test vectors, from the fixtures extract.mjs made; each fixture names its sources and their SHA-256.
enum Vectors {
	static func folder() -> URL {
		if let index = CommandLine.arguments.firstIndex(of: "--vectors"), index + 1 < CommandLine.arguments.count {
			return URL(fileURLWithPath: CommandLine.arguments[index + 1])
		}
		return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("vectors")
	}

	static func load(_ name: String) throws -> [String: Any] {
		let data = try Data(contentsOf: folder().appendingPathComponent(name))
		guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RemoteKitError("fixture", "not an object") }
		return object
	}

	// MARK: Noise

	/// One vector, in whichever of the sources' two forms it was published.
	struct NoiseVector {
		let source: String
		let pattern: NoisePattern
		var initPrologue: Data
		var respPrologue: Data
		let initStatic: Data
		let respStatic: Data
		let initEphemeral: Data
		let respEphemeral: Data
		let initRemoteStatic: Data?
		let respRemoteStatic: Data?
		var initPSK: Data?
		var respPSK: Data?
		let handshakeHash: Data?
		var messages: [(payload: Data, ciphertext: Data)]

		init(source: String, _ v: [String: Any]) throws {
			func hex(_ key: String) -> Data? { (v[key] as? String).flatMap { Data(hex: $0) } }
			func required(_ key: String...) throws -> Data {
				for name in key { if let value = hex(name) { return value } }
				throw RemoteKitError("fixture", "a vector has no \(key[0])")
			}
			self.source = source
			let name = (v["protocol_name"] ?? v["name"] ?? v["handshake"]) as? String
			guard let pattern = NoisePattern.allCases.first(where: { $0.protocolName == name }) else { throw RemoteKitError("fixture", "an unknown protocol") }
			self.pattern = pattern
			// flynn/noise writes one prologue for both sides, and none when it is empty.
			initPrologue = hex("init_prologue") ?? hex("prologue") ?? Data()
			respPrologue = hex("resp_prologue") ?? hex("prologue") ?? Data()
			initStatic = try required("init_static")
			respStatic = try required("resp_static")
			initEphemeral = try required("init_ephemeral", "gen_init_ephemeral")
			respEphemeral = try required("resp_ephemeral", "gen_resp_ephemeral")
			initRemoteStatic = hex("init_remote_static")
			respRemoteStatic = hex("resp_remote_static")
			initPSK = (v["init_psks"] as? [String])?.first.flatMap { Data(hex: $0) } ?? hex("preshared_key")
			respPSK = (v["resp_psks"] as? [String])?.first.flatMap { Data(hex: $0) } ?? hex("preshared_key")
			handshakeHash = hex("handshake_hash")
			if let list = v["messages"] as? [[String: String]] {
				messages = try list.map {
					guard let payload = Data(hex: $0["payload"] ?? ""), let ciphertext = Data(hex: $0["ciphertext"] ?? "") else {
						throw RemoteKitError("fixture", "a message is not hex")
					}
					return (payload, ciphertext)
				}
			} else {
				var list: [(Data, Data)] = []
				while let ciphertext = hex("msg_\(list.count)_ciphertext") {
					list.append((hex("msg_\(list.count)_payload") ?? Data(), ciphertext))
				}
				messages = list
			}
		}
	}

	static func noise() {
		Check.section("Noise: the published test vectors")
		let fixture: [String: Any]
		do {
			fixture = try load("noise.json")
		} catch {
			Check.that(false, "noise.json reads")
			return
		}
		let sources = (fixture["sources"] as? [[String: Any]]) ?? []
		for source in sources {
			print("   from \(source["name"] ?? "?") at \(source["commit"] ?? "?"), SHA-256 \(source["sha256"] ?? "?")")
		}
		var counts: [String: (vectors: Int, messages: Int)] = [:]
		var total = 0
		var changes = 0
		var changesRefused = 0
		for entry in (fixture["vectors"] as? [[String: Any]]) ?? [] {
			let source = entry["source"] as? String ?? "?"
			do {
				let vector = try NoiseVector(source: source, entry["vector"] as? [String: Any] ?? [:])
				let checked = try run(vector)
				let key = "\(vector.pattern.protocolName) from \(source)"
				counts[key, default: (0, 0)].vectors += 1
				counts[key, default: (0, 0)].messages += checked
				total += 1
				Check.that(true, key)
				// And the check itself: one bit changed in any message, a prologue or a pre-shared key, and it fails.
				for changed in oneBitChanges(vector) {
					changes += 1
					if (try? run(changed)) == nil { changesRefused += 1 }
				}
			} catch {
				Check.that(false, "a vector from \(source): \(error)")
			}
		}
		Check.that(total == 12, "exactly the 12 published vectors the fixture holds (7 KK, 5 IKpsk2), none lost")
		Check.that(changes > 0 && changesRefused == changes, "each of \(changes) one-bit changes to a vector's messages, prologues and pre-shared keys fails")
		for (key, count) in counts.sorted(by: { $0.key < $1.key }) {
			print("ok   \(key): \(count.vectors) vector\(count.vectors == 1 ? "" : "s"), \(count.messages) messages")
		}
		for pattern in NoisePattern.allCases {
			Check.that(counts.keys.contains { $0.hasPrefix(pattern.protocolName + " ") }, "a published vector for \(pattern.protocolName)")
		}
	}

	/// The vector with one bit changed: in each message's published ciphertext in turn, in each side's prologue, and in
	/// each side's pre-shared key.
	static func oneBitChanges(_ vector: NoiseVector) -> [NoiseVector] {
		func flipped(_ data: Data) -> Data {
			var data = data
			if data.isEmpty { return Data([1]) }
			data[data.startIndex + data.count / 2] ^= 0x10
			return data
		}
		var changes: [NoiseVector] = []
		for index in vector.messages.indices {
			var changed = vector
			changed.messages[index].ciphertext = flipped(changed.messages[index].ciphertext)
			changes.append(changed)
		}
		var prologue = vector
		prologue.initPrologue = flipped(prologue.initPrologue)
		changes.append(prologue)
		prologue = vector
		prologue.respPrologue = flipped(prologue.respPrologue)
		changes.append(prologue)
		if vector.pattern.usesPSK, let psk = vector.initPSK {
			var changed = vector
			changed.initPSK = flipped(psk)
			changes.append(changed)
		}
		if vector.pattern.usesPSK, let psk = vector.respPSK {
			var changed = vector
			changed.respPSK = flipped(psk)
			changes.append(changed)
		}
		return changes
	}

	/// Runs both sides of one vector, each from its own keys, and checks every message against the published one.
	static func run(_ v: NoiseVector) throws -> Int {
		let initiatorKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.initStatic)
		let responderKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.respStatic)
		// Both patterns have the responder's static key known to the initiator; only KK has the initiator's known too.
		let needsInitiatorKey = v.pattern == .kk
		// Where the vector gives the other side's public key, it must be the one its private key makes.
		if let given = v.initRemoteStatic, !Bytes.constantTimeEqual(given, responderKey.publicKey.rawRepresentation) {
			throw RemoteKitError("vector", "init_remote_static is not the responder's key")
		}
		if let given = v.respRemoteStatic, !Bytes.constantTimeEqual(given, initiatorKey.publicKey.rawRepresentation) {
			throw RemoteKitError("vector", "resp_remote_static is not the initiator's key")
		}
		let initiator = try NoiseHandshake(
			pattern: v.pattern, initiator: true, prologue: v.initPrologue, localStatic: initiatorKey,
			remoteStatic: responderKey.publicKey.rawRepresentation, psk: v.pattern.usesPSK ? v.initPSK : nil,
			ephemeral: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.initEphemeral))
		let responder = try NoiseHandshake(
			pattern: v.pattern, initiator: false, prologue: v.respPrologue, localStatic: responderKey,
			remoteStatic: needsInitiatorKey ? initiatorKey.publicKey.rawRepresentation : nil, psk: v.pattern.usesPSK ? v.respPSK : nil,
			ephemeral: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.respEphemeral))
		var initiatorTransport: NoiseTransport?
		var responderTransport: NoiseTransport?
		for (index, message) in v.messages.enumerated() {
			let fromInitiator = index % 2 == 0
			let written: Data
			let read: Data
			if !initiator.isComplete {
				if fromInitiator {
					written = try initiator.writeMessage(payload: message.payload)
					read = try responder.readMessage(written)
				} else {
					written = try responder.writeMessage(payload: message.payload)
					read = try initiator.readMessage(written)
				}
				if initiator.isComplete {
					guard responder.isComplete else { throw RemoteKitError("vector", "one side finished first") }
					guard Bytes.constantTimeEqual(initiator.handshakeHash, responder.handshakeHash) else { throw RemoteKitError("vector", "the two handshake hashes differ") }
					if let expected = v.handshakeHash, !Bytes.constantTimeEqual(expected, initiator.handshakeHash) {
						throw RemoteKitError("vector", "the handshake hash is not the published one")
					}
					initiatorTransport = try initiator.split()
					responderTransport = try responder.split()
				}
			} else if fromInitiator {
				written = try initiatorTransport!.encrypt(message.payload)
				read = try responderTransport!.decrypt(written)
			} else {
				written = try responderTransport!.encrypt(message.payload)
				read = try initiatorTransport!.decrypt(written)
			}
			guard Bytes.constantTimeEqual(written, message.ciphertext) else { throw RemoteKitError("vector", "message \(index) is not the published ciphertext") }
			guard Bytes.constantTimeEqual(read, message.payload) else { throw RemoteKitError("vector", "message \(index) did not read back as its payload") }
		}
		guard initiator.isComplete else { throw RemoteKitError("vector", "the handshake did not complete") }
		return v.messages.count
	}

	// MARK: HPKE

	static func hpke() {
		Check.section("HPKE: RFC 9180's published test vectors")
		let fixture: [String: Any]
		do {
			fixture = try load("hpke.json")
		} catch {
			Check.that(false, "hpke.json reads")
			return
		}
		for source in (fixture["sources"] as? [[String: Any]]) ?? [] {
			print("   from \(source["name"] ?? "?") at \(source["commit"] ?? "?"), SHA-256 \(source["sha256"] ?? "?")")
		}
		var vectors = 0
		var encryptions = 0
		var exports = 0
		for entry in (fixture["vectors"] as? [[String: Any]]) ?? [] {
			guard let v = entry["vector"] as? [String: Any] else { continue }
			do {
				let counts = try runHPKE(v)
				vectors += 1
				encryptions += counts.0
				exports += counts.1
			} catch {
				Check.that(false, "an HPKE vector: \(error)")
			}
		}
		Check.that(vectors == 1, "the one published vector for mode_auth, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM")
		// And the check itself: one bit changed in a ciphertext, the encapsulated key, the info or an export, and it fails.
		if let v = ((fixture["vectors"] as? [[String: Any]])?.first?["vector"]) as? [String: Any] {
			var changes = 0
			var refused = 0
			for change in hpkeOneBitChanges(v) {
				changes += 1
				if (try? runHPKE(change)) == nil { refused += 1 }
			}
			Check.that(changes == 4 && refused == changes, "each of 4 one-bit changes to the HPKE vector fails")
		}
		print("ok   HPKE mode_auth P-256/SHA-256/AES-256-GCM: \(vectors) vector, \(encryptions) encryptions opened, \(exports) exports")
	}

	static func hpkeOneBitChanges(_ v: [String: Any]) -> [[String: Any]] {
		func flip(_ hex: String) -> String {
			guard var data = Data(hex: hex), !data.isEmpty else { return hex }
			data[data.startIndex + data.count / 2] ^= 0x01
			return data.hex
		}
		var changes: [[String: Any]] = []
		if var encryptions = v["encryptions"] as? [[String: String]], encryptions.count > 3 {
			var changed = v
			encryptions[3]["ct"] = flip(encryptions[3]["ct"] ?? "")
			changed["encryptions"] = encryptions
			changes.append(changed)
		}
		for key in ["enc", "info"] {
			var changed = v
			changed[key] = flip(v[key] as? String ?? "")
			changes.append(changed)
		}
		if var exports = v["exports"] as? [[String: Any]], !exports.isEmpty {
			var changed = v
			exports[0]["exported_value"] = flip(exports[0]["exported_value"] as? String ?? "")
			changed["exports"] = exports
			changes.append(changed)
		}
		return changes
	}

	static func runHPKE(_ v: [String: Any]) throws -> (Int, Int) {
		func hex(_ key: String) throws -> Data {
			guard let text = v[key] as? String, let data = Data(hex: text) else { throw RemoteKitError("vector", "no \(key)") }
			return data
		}
		guard v["mode"] as? Int == 2, v["kem_id"] as? Int == 16, v["kdf_id"] as? Int == 1, v["aead_id"] as? Int == 2 else {
			throw RemoteKitError("vector", "not the suite pi² uses")
		}
		let recipientKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: try hex("skRm"))
		guard Bytes.constantTimeEqual(recipientKey.publicKey.x963Representation, try hex("pkRm")) else { throw RemoteKitError("vector", "pkRm is not skRm's") }
		let senderKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: try hex("skSm"))
		let senderPublic = try P256.KeyAgreement.PublicKey(x963Representation: try hex("pkSm"))
		guard Bytes.constantTimeEqual(senderKey.publicKey.x963Representation, senderPublic.x963Representation) else { throw RemoteKitError("vector", "pkSm is not skSm's") }
		let info = try hex("info")
		var recipient = try HPKE.Recipient(
			privateKey: recipientKey, ciphersuite: SealedItem.ciphersuite, info: info, encapsulatedKey: try hex("enc"), authenticatedBy: senderPublic)
		var opened = 0
		for encryption in (v["encryptions"] as? [[String: String]]) ?? [] {
			guard let aad = Data(hex: encryption["aad"] ?? ""), let ct = Data(hex: encryption["ct"] ?? ""), let pt = Data(hex: encryption["pt"] ?? "") else {
				throw RemoteKitError("vector", "an encryption is not hex")
			}
			let plaintext = try recipient.open(ct, authenticating: aad)
			guard Bytes.constantTimeEqual(plaintext, pt) else { throw RemoteKitError("vector", "encryption \(opened) did not open to its plaintext") }
			opened += 1
		}
		var exported = 0
		for export in (v["exports"] as? [[String: Any]]) ?? [] {
			guard let context = Data(hex: export["exporter_context"] as? String ?? "x"), let length = export["L"] as? Int,
				let value = Data(hex: export["exported_value"] as? String ?? "x")
			else { throw RemoteKitError("vector", "an export is not as expected") }
			let secret = try recipient.exportSecret(context: context, outputByteCount: length).withUnsafeBytes { Data($0) }
			guard Bytes.constantTimeEqual(secret, value) else { throw RemoteKitError("vector", "export \(exported) is not the published value") }
			exported += 1
		}
		// The sender's side cannot be checked against the vector, since CryptoKit makes the ephemeral key itself; it is
		// checked against the vector's recipient instead: what the vector's sender key seals, the vector's recipient opens.
		var sender = try HPKE.Sender(recipientKey: recipientKey.publicKey, ciphersuite: SealedItem.ciphersuite, info: info, authenticatedBy: senderKey)
		let sealed = try sender.seal(Data("pi2".utf8))
		var again = try HPKE.Recipient(
			privateKey: recipientKey, ciphersuite: SealedItem.ciphersuite, info: info, encapsulatedKey: sender.encapsulatedKey, authenticatedBy: senderPublic)
		guard try again.open(sealed) == Data("pi2".utf8) else { throw RemoteKitError("vector", "a seal by the vector's sender did not open") }
		return (opened, exported)
	}
}
