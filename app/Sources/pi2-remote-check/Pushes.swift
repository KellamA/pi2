import CryptoKit
import Foundation
@_spi(Vectors) import RemoteKit

/// Sealed pushes (#689, docs/remotekit.md "Sealed pushes"): sealed and opened by RemoteKit's two ends, each size, the
/// bytes' layout, what an opener refuses, a push and a mailbox item kept apart by their labels (#937), the collapse id,
/// and a Live Activity's numbers.
enum Pushes {
	static func run() {
		Check.section("Sealed pushes")
		let pairing = PairingID.random()
		let device = DeviceID.random()
		let phoneRecord = P256.KeyAgreement.PrivateKey()
		let macRecord = P256.KeyAgreement.PrivateKey()
		let identity = P256.Signing.PrivateKey()
		let id = ItemID.random()
		func body(_ title: String) -> JSONValue {
			try! JSON.parse(#"{"v":1,"type":"need","category":"pi2.approval","title":"\#(title)","body":"bash: npm test","whole":true,"at":1}"#)
		}
		func seal(_ value: JSONValue, kind: PushSealing.Kind = .alert, for target: DeviceID = device) throws -> Data {
			try PushSealing.seal(value, kind: kind, pairing: pairing, device: target, deviceRecordKey: phoneRecord.publicKey, recordKey: macRecord, identity: identity, id: id)
		}
		func open(_ sealed: Data, record: P256.KeyAgreement.PrivateKey? = nil, signer: P256.Signing.PublicKey? = nil) throws -> PushSealing.Opened {
			try PushSealing.open(
				sealed, pairing: pairing, device: device, recordKey: record ?? phoneRecord, macRecordKey: macRecord.publicKey, identityKey: signer ?? identity.publicKey)
		}

		Check.runs("an alert sealed and opened") {
			let sealed = try seal(body("Forge needs approval"))
			Check.that(sealed.count == 1_464 && sealed.first == 0x04, "an alert's smallest size, the middle one, a sealed item's first byte first")
			Check.that(Base64URL.encode(sealed.suffix(16)) == id.text, "and the item's id last")
			let opened = try open(sealed)
			Check.that(opened.kind == .alert && opened.id == id && opened.body == body("Forge needs approval"), "it opens to its kind, its id and the body as given")
		}
		Check.runs("a background push sealed and opened") {
			let gone = try JSON.parse(#"{"v":1,"type":"gone","needs":["n1"],"at":1}"#)
			let sealed = try seal(gone, kind: .background)
			let kind = try open(sealed).kind
			Check.that(sealed.count == 696 && kind == .background, "as a background push, of the smallest size")
		}
		Check.runs("each size") {
			for (characters, size) in [(10, 1_464), (400, 1_464), (900, 3_000)] {
				Check.that(try seal(body(String(repeating: "é", count: characters))).count == size, "a title of \(characters) characters makes \(size) bytes")
			}
			let gone = try JSON.parse(#"{"v":1,"type":"gone","needs":["\#(String(repeating: "n", count: 400))"],"at":1}"#)
			Check.that(try seal(gone, kind: .background).count == 1_464, "a background push too long for the smallest makes the middle size")
		}
		Check.refuses("a body too large for the largest push, never cut") { _ = try seal(body(String(repeating: "é", count: 1_600))) }
		let sealed = try! seal(body("Forge needs approval"))
		Check.refuses("another device's record key") { _ = try open(sealed, record: P256.KeyAgreement.PrivateKey()) }
		Check.refuses("another Mac's signature") { _ = try open(sealed, signer: P256.Signing.PrivateKey().publicKey) }
		Check.refuses("a push sealed for another device") { _ = try open(try seal(body("x"), for: DeviceID.random())) }
		Check.refuses("another id after the item") { _ = try open(sealed.dropLast(16) + Bytes.random(16)) }
		Check.refuses("a byte changed") {
			var changed = sealed
			changed[200] ^= 1
			_ = try open(changed)
		}
		Check.refuses("a cut push") { _ = try open(sealed.prefix(695)) }
		Check.refuses("a push of another size") { _ = try open(sealed + Data([0])) }
		// A Mac item of `kind` padded to a push's smallest size, its body shaped as a push's, as a relay that kept one could
		// try; sealed under `label`, and the id after it as a push carries it.
		let address = ItemAddress(pairing: pairing, reader: .device(device), id: id)
		func padded(_ kind: String, label: SealLabel) throws -> Data {
			func item(pad: Int) throws -> MacItem {
				try MacItem.make(
					kind: kind, number: kind == "state" ? 7 : nil, body: .object([("body", .object([])), ("pad", .string(String(repeating: "0", count: pad)))]),
					pairing: pairing, device: device, id: id, at: Date(timeIntervalSince1970: 1_800_000_000), identity: identity)
			}
			let plain = try item(pad: 696 - PushSealing.overhead - (try item(pad: 0).plaintext.count)).plaintext
			let inner = try SealedItem.seal(plain, to: address, label: label, readerKey: phoneRecord.publicKey, writerKey: macRecord)
			guard inner.count + 16 == 696 else { throw RemoteKitError("check", "not padded to a push's size") }
			return inner + Base64URL.decode(id.text)!
		}
		// Under the push's label, so that only its kind keeps it out.
		Check.refuses("a Mac item of another kind") { _ = try open(try padded("receipt", label: .push)) }

		// A push and a mailbox item apart (#937): the push's label, `pi2-push-v1`, in place of the mailbox's `pi2-item-v2`.
		func openAsMailbox(_ inner: Data) throws -> MacItem {
			// As the phone's mailbox reader opens a Mac item.
			try SealedItem.openMacItem(inner, at: address, readerKey: phoneRecord, writerRecordKey: macRecord.publicKey, identityKey: identity.publicKey)
		}
		for kind in PushSealing.Kind.allCases {
			let push = try! seal(kind == .alert ? body("Forge needs approval") : try! JSON.parse(#"{"v":1,"type":"gone","needs":["n1"],"at":1}"#), kind: kind)
			let inner = push.dropLast(16)
			Check.refuses("a sealed \(kind) push, as a mailbox item (openMacItem)") { _ = try openAsMailbox(inner) }
			Check.refuses("a sealed \(kind) push, opened under the mailbox's label: the label alone keeps it out") {
				_ = try SealedItem.open(inner, at: address, readerKey: phoneRecord, writerKey: macRecord.publicKey)
			}
			Check.runs("and under the push's label it opens") {
				_ = try MacItem.read(try SealedItem.open(inner, at: address, label: .push, readerKey: phoneRecord, writerKey: macRecord.publicKey))
			}
		}
		for kind in ["receipt", "state", "revoked"] {
			Check.refuses("a Mac item of kind \(kind) under the push's label, as a mailbox item: the label alone keeps it out") {
				_ = try openAsMailbox(try padded(kind, label: .push).dropLast(16))
			}
			Check.runs("and under the mailbox's label, as one") { _ = try openAsMailbox(try padded(kind, label: .item).dropLast(16)) }
		}
		for kind in ["push", "pushGone", "receipt", "state", "revoked"] {
			Check.refuses("a mailbox item of kind \(kind), padded to a push's size, as a push") { _ = try open(try padded(kind, label: .item)) }
		}
		for kind in ["push", "pushGone"] {
			Check.refuses("a mailbox item of a push's kind, \(kind), as a mailbox item: the second line, by kind") {
				_ = try openAsMailbox(try padded(kind, label: .item).dropLast(16))
			}
		}
		// The two labels as docs/remotekit.md writes them, worked out apart: a mailbox item's bytes are what they were
		// before #937, and a push's are under its own.
		Check.runs("each label, worked out apart with CryptoKit") {
			func written(_ label: String) -> Data {
				var info = Data(label.utf8)
				for part in [pairing.text, device.text, id.text] { info += Data([0]) + Data(part.utf8) }
				return info
			}
			Check.that(address.info(.item) == written("pi2-item-v2") && address.info(.push) == written("pi2-push-v1"), "info is the label, then the pairing, the reader and the id, each after a zero byte")
			func opens(_ item: Data, _ label: String) -> Bool {
				guard var recipient = try? HPKE.Recipient(
					privateKey: phoneRecord, ciphersuite: .P256_SHA256_AES_GCM_256, info: written(label), encapsulatedKey: item.prefix(65), authenticatedBy: macRecord.publicKey)
				else { return false }
				return (try? recipient.open(item.dropFirst(65))) != nil
			}
			let receipt = try MacItem.make(kind: "receipt", body: .object([]), pairing: pairing, device: device, id: id, identity: identity)
			let mailbox = try SealedItem.seal(receipt.plaintext, to: address, readerKey: phoneRecord.publicKey, writerKey: macRecord)
			Check.that(opens(mailbox, "pi2-item-v2") && !opens(mailbox, "pi2-push-v1"), "a mailbox item, sealed by SealedItem.seal, opens under pi2-item-v2 alone")
			let push = try seal(body("Forge needs approval")).dropLast(16)
			Check.that(opens(push, "pi2-push-v1") && !opens(push, "pi2-item-v2"), "a sealed push, by PushSealing.seal, under pi2-push-v1 alone")
		}

		Check.runs("the collapse id") {
			let mac = try PushSealing.collapse("need:n12", pairing: pairing, device: device, recordKey: macRecord, deviceRecordKey: phoneRecord.publicKey)
			let phone = try PushSealing.collapse("need:n12", pairing: pairing, device: device, recordKey: phoneRecord, deviceRecordKey: macRecord.publicKey)
			Check.that(mac.count == 32 && mac == phone, "32 bytes, the same from either end's record key")
			Check.that(try PushSealing.collapse("need:n13", pairing: pairing, device: device, recordKey: macRecord, deviceRecordKey: phoneRecord.publicKey) != mac, "another item, another id")
			Check.that(try PushSealing.collapse("need:n12", pairing: pairing, device: DeviceID.random(), recordKey: macRecord, deviceRecordKey: phoneRecord.publicKey) != mac, "another device, another id")
			Check.that(try PushSealing.collapse("need:n12", pairing: PairingID.random(), device: device, recordKey: macRecord, deviceRecordKey: phoneRecord.publicKey) != mac, "another pairing, another id")
		}
		Check.refuses("an empty item id for a collapse id") {
			_ = try PushSealing.collapse("", pairing: pairing, device: device, recordKey: macRecord, deviceRecordKey: phoneRecord.publicKey)
		}

		Check.that(ActivityNumbers(working: 0, needs: 99_999, finished: 0, at: 1) != nil, "a Live Activity's counts up to 99,999")
		Check.that(ActivityNumbers(working: 100_000, needs: 0, finished: 0, at: 1) == nil && ActivityNumbers(working: -1, needs: 0, finished: 0, at: 1) == nil, "and no further, nor below 0")
		Check.that(ActivityNumbers(json: try! JSON.parse(#"{"working":1,"needs":2,"finished":3,"at":4}"#)) != nil, "exactly four numbers read")
		Check.that(ActivityNumbers(json: try! JSON.parse(#"{"working":1,"needs":2,"finished":3,"at":4,"name":"x"}"#)) == nil, "and a fifth member refused")
	}
}
