
import CryptoKit
import Foundation

// A phone's leave, as the Mac can believe it (iphone.md 3.6; remotekit.md, "The leave notice"; #813). The relay is not
// trusted, so its word that a device left is a hint. What the Mac believes is the phone's own notice, signed with its
// device key over a text the relay cannot check and cannot make: the leave text for the Mac. The phone sends it in
// `leave` beside the relay's own signature; the relay passes it on in `left`, now or at the Mac's next `ready`.
//
// The leave text is the JSON text `{"v":2,"kind":"leave","pairing":…,"device":…,"mac":…,"at":…}`, written compactly as
// every signed text of RemoteKit's, with `mac` the Mac's identity key (SPKI DER, base64url) and `at` the phone's time in
// ms. The Mac writes it itself, from its own pairing's id, the device's id, its own identity key and `at`, and checks
// the notice over it; it never reads a text the relay gives. What binds it:
// - to the pairing and the device: their ids, and the device key, which is made at each scan and taken by the engine
//   only if no record holds it (3.3 step 5), so a leave from an earlier pairing verifies against no key the Mac holds;
// - to the Mac: its identity key, which the relay never sees, so a notice cannot be moved to another Mac;
// - to a time: `at`, taken at any time up to 10 minutes after the Mac's clock (a phone's clock that is fast). There is
//   no oldest (#929): the relay keeps a `left` for a Mac that is away until its next `ready`, and a pairing lives while
//   any of its ends, a phone too, connects within 60 days, so nothing bounds how old a genuine leave is when the Mac
//   hears it; and its age adds no safety, since the device key signs a notice only as the phone unpairs and deletes the
//   key, and the engine takes a device key only once (3.3 step 5). A bound behind would only leave a phone that did
//   unpair on the Mac's list. Once its device is revoked, the same notice again does nothing;
// - to its kind: `leave`, which no other text the device key signs has. The device key signs the relay's
//   `pi2-relay-v1` texts (a proof and a leave), which are not JSON, and JSON objects of kind `pair`, `attach`,
//   `request` and `leave`, each read with exactly its members; no Mac item may have any of those kinds (`MacItem`).

/// A device the relay says left (3.6), with what its phone signed for the Mac. **The relay's word until `verified` has
/// checked it**: a relay can name any device, make up a time, and give a notice that does not verify. Only a
/// `RelayVerifiedLeave` is a device having left; anything else is shown as "the relay says this device left", and
/// revokes, forgets and wipes nothing.
public struct RelayLeft: Equatable, Sendable {
	public let device: DeviceID
	/// When the phone says it left, in ms since 1970 by its clock.
	public let at: Int64
	/// The device key's signature over the leave text, 64 bytes.
	public let notice: Data

	public init(device: DeviceID, at: Int64, notice: Data) {
		self.device = device
		self.at = at
		self.notice = notice
	}

	/// The leave, if the device key the caller holds for `device` signed this notice over the leave text for this pairing
	/// and this Mac's identity key, at a time no more than `RelayLeaveNotice.aheadAtMost` after `now` (ms since 1970, the Mac's clock); nil otherwise.
	/// `deviceKey` is the caller's own, from the engine's verified claim, never what a relay said.
	public func verified(pairing: PairingID, identityKey: P256.Signing.PublicKey, deviceKey: P256.Signing.PublicKey, now: Int64) -> RelayVerifiedLeave? {
		// Both times first held to what a time is, so that the window's sums cannot overflow whatever a relay or a clock says.
		guard at > 0, at <= RelayLimits.maxTime, now > 0, now <= RelayLimits.maxTime else { return nil }
		guard at <= now + RelayLeaveNotice.aheadAtMost else { return nil }
		guard notice.count == SignedStatement.signatureLength,
			let text = try? RelayLeaveNotice.text(pairing: pairing, device: device, identityKey: identityKey, at: at),
			SignedStatement.verify(notice, over: text, by: deviceKey)
		else { return nil }
		return RelayVerifiedLeave(device: device, at: at, notice: notice)
	}
}

/// A leave the device's own key signed for this Mac and this pairing: the device has left, as if it had asked
/// `devices.forgetSelf` (3.6). Made only by `RelayLeft.verified`. `notice` is carried for the engine, which checks it
/// again against the device key in its own record (`remote.left`, #929).
public struct RelayVerifiedLeave: Equatable, Sendable {
	public let device: DeviceID
	public let at: Int64
	public let notice: Data

	fileprivate init(device: DeviceID, at: Int64, notice: Data) {
		self.device = device
		self.at = at
		self.notice = notice
	}
}

/// The leave text for the Mac, and how far ahead of the Mac's clock its time may be.
public enum RelayLeaveNotice {
	/// How far ahead of the Mac's clock a leave may be: 10 minutes, for a phone's clock that is fast.
	public static let aheadAtMost: Int64 = 10 * 60_000

	/// `{"v":2,"kind":"leave","pairing":…,"device":…,"mac":…,"at":…}`, as its UTF-8 bytes. Throws for a time that is not
	/// one (at most the year 2286, as the relay's messages carry it).
	public static func text(pairing: PairingID, device: DeviceID, identityKey: P256.Signing.PublicKey, at: Int64) throws -> Data {
		guard at > 0, at <= RelayLimits.maxTime else { throw RemoteKitError("relay leave", "at is not a time") }
		let value = JSONValue.object([
			("v", .integer(2)), ("kind", .string("leave")), ("pairing", .string(pairing.text)), ("device", .string(device.text)),
			("mac", .string(PublicKeys.text(identityKey))), ("at", .integer(at)),
		])
		return Data(JSON.text(value).utf8)
	}
}
