import CryptoKit
import Foundation
import RemoteKit

/// Sealed pushes (#689, docs/remotekit.md "Sealed pushes"): sealed and opened by RemoteKit's two ends, each size, the
/// bytes' layout, what an opener refuses, the collapse id, and a Live Activity's numbers.
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
			Check.that(sealed.count == 696 && sealed.first == 0x04, "the smallest size, a sealed item's first byte first")
			Check.that(Base64URL.encode(sealed.suffix(16)) == id.text, "and the item's id last")
			let opened = try open(sealed)
			Check.that(opened.kind == .alert && opened.id == id && opened.body == body("Forge needs approval"), "it opens to its kind, its id and the body as given")
		}
		Check.runs("a background push sealed and opened") {
			let gone = try JSON.parse(#"{"v":1,"type":"gone","needs":["n1"],"at":1}"#)
			Check.that(try open(try seal(gone, kind: .background)).kind == .background, "as a background push")
		}
		Check.runs("each size") {
			for (characters, size) in [(10, 696), (400, 1_464), (900, 3_000)] {
				Check.that(try seal(body(String(repeating: "é", count: characters))).count == size, "a title of \(characters) characters makes \(size) bytes")
			}
		}
		Check.refuses("a body too large for the largest push, never cut") { _ = try seal(body(String(repeating: "é", count: 1_600))) }
		let sealed = try! seal(body("Forge needs approval"))
		Check.refuses("another device's record key") { _ = try open(sealed, record: P256.KeyAgreement.PrivateKey()) }
		Check.refuses("another Mac's signature") { _ = try open(sealed, signer: P256.Signing.PrivateKey().publicKey) }
		Check.refuses("a push sealed for another device") { _ = try open(try seal(body("x"), for: DeviceID.random())) }
		Check.refuses("another id after the item") { _ = try open(sealed.prefix(680) + Bytes.random(16)) }
		Check.refuses("a byte changed") {
			var changed = sealed
			changed[200] ^= 1
			_ = try open(changed)
		}
		Check.refuses("a cut push") { _ = try open(sealed.prefix(695)) }
		Check.refuses("a push of another size") { _ = try open(sealed + Data([0])) }
		// A receipt padded to a push's size, as a relay that kept one could try: not a push's kind.
		func receipt(pad: Int) throws -> MacItem {
			try MacItem.make(
				kind: "receipt", body: .object([("body", .object([])), ("pad", .string(String(repeating: "0", count: pad)))]), pairing: pairing, device: device, id: id,
				at: Date(timeIntervalSince1970: 1_800_000_000), identity: identity)
		}
		Check.refuses("a Mac item of another kind") {
			let bare = try receipt(pad: 0).plaintext.count
			let plain = try receipt(pad: 696 - PushSealing.overhead - bare).plaintext
			let inner = try SealedItem.seal(plain, to: ItemAddress(pairing: pairing, reader: .device(device), id: id), readerKey: phoneRecord.publicKey, writerKey: macRecord)
			Check.that(inner.count + 16 == 696, "a receipt padded to a push's size")
			_ = try open(inner + Base64URL.decode(id.text)!)
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
