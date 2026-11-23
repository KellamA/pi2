
import CryptoKit
import Foundation

/// The tag in the home path's Bonjour TXT record (iphone.md 5.4), `t=<tag>` beside `v=2`: a paired phone recognises its
/// Mac by it on any network, and nobody else learns the pairing's id from it, which would follow the Mac from network to
/// network and name it at the relay.
///
/// The key is SHA-256 of `pi2-tag`, a zero byte, the Mac's channel key (its 32 raw public bytes), a zero byte and the
/// pairing's id as text; the tag is HMAC-SHA256 under that key of the UTC day, `YYYY-MM-DD`, its first 8 bytes written as
/// 16 lower-case hexadecimal digits. The phone has the channel key and the pairing's id from the pairing payload; the
/// relay, which knows the pairing's id, never sees the channel key. It is a mark to recognise, not a proof: a phone that
/// finds it still makes the KK handshake, which only the Mac's channel key answers (remotekit.md, "The home tag").
public enum HomeTag {
	/// A tag's length in hexadecimal digits: 8 bytes.
	public static let length = 16

	/// The tag pi² Remote advertises on `date`'s UTC day.
	public static func tag(macChannelKey: Curve25519.KeyAgreement.PublicKey, pairing: PairingID, date: Date) -> String {
		tag(key: key(macChannelKey: macChannelKey, pairing: pairing), day: day(date))
	}

	/// The phone's check of the tag in a TXT record: whether it is its Mac's for the UTC day before `now`, the day of
	/// `now` or the day after, so that clocks up to a day apart still meet. All three are compared, each in a time that
	/// depends on the lengths alone.
	public static func recognises(
		_ advertised: String, macChannelKey: Curve25519.KeyAgreement.PublicKey, pairing: PairingID, now: Date = Date()
	) -> Bool {
		let key = key(macChannelKey: macChannelKey, pairing: pairing)
		let given = Array(advertised.utf8)
		var found = false
		for offset in [-1.0, 0, 1] {
			let expected = tag(key: key, day: day(now.addingTimeInterval(offset * 86_400)))
			found = Bytes.constantTimeEqual(given, Array(expected.utf8)) || found
		}
		return found
	}

	/// The day `date` falls on in UTC, as `YYYY-MM-DD`; a date outside the years 0000 to 9999 is taken as the nearest of them.
	@_spi(Vectors) public static func day(_ date: Date) -> String {
		let seconds = date.timeIntervalSince1970
		// The first and last days of the years 0000 and 9999, counted from 1970-01-01.
		let first: Int64 = -719_528
		let last: Int64 = 2_932_896
		let days: Int64
		if seconds.isNaN {
			days = 0
		} else {
			let whole = (seconds / 86_400).rounded(.down)
			days = whole < Double(first) ? first : whole > Double(last) ? last : Int64(whole)
		}
		// Days to a civil date in the proleptic Gregorian calendar (Howard Hinnant's `civil_from_days`).
		let z = days + 719_468
		let era = (z >= 0 ? z : z - 146_096) / 146_097
		let dayOfEra = z - era * 146_097
		let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
		let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
		let monthIndex = (5 * dayOfYear + 2) / 153
		let dayOfMonth = dayOfYear - (153 * monthIndex + 2) / 5 + 1
		let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
		let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
		return digits(year, 4) + "-" + digits(month, 2) + "-" + digits(dayOfMonth, 2)
	}

	private static func digits(_ value: Int64, _ count: Int) -> String {
		let text = String(value)
		return String(repeating: "0", count: max(0, count - text.count)) + text
	}

	private static func key(macChannelKey: Curve25519.KeyAgreement.PublicKey, pairing: PairingID) -> SymmetricKey {
		var material = Data("pi2-tag".utf8)
		material.append(0)
		material.append(macChannelKey.rawRepresentation)
		material.append(0)
		material.append(contentsOf: pairing.text.utf8)
		return SymmetricKey(data: SHA256.hash(data: material))
	}

	private static let hexDigits = Array("0123456789abcdef".utf8)

	private static func tag(key: SymmetricKey, day: String) -> String {
		let code = HMAC<SHA256>.authenticationCode(for: Data(day.utf8), using: key)
		var out = [UInt8]()
		for byte in Data(code).prefix(length / 2) {
			out.append(hexDigits[Int(byte >> 4)])
			out.append(hexDigits[Int(byte & 0x0f)])
		}
		return String(decoding: out, as: UTF8.self)
	}
}
