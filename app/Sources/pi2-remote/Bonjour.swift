import CryptoKit
import Foundation
import RemoteKit

/// The tag in the home path's Bonjour TXT record (docs/iphone.md 5.4): HMAC-SHA256, keyed with a key of the pairing, of
/// the day's date, cut to 8 bytes, so that a paired phone recognises its Mac and nobody else learns the pairing's id,
/// which would follow the Mac from network to network and name it at the relay.
///
/// The key is SHA-256 of `pi2-tag`, a zero byte, the Mac's channel key's 32 raw public bytes, a zero byte and the
/// pairing's id as text: the phone has both from pairing, and the relay, which knows the pairing's id, never sees the
/// channel key. The date is the UTC day, `YYYY-MM-DD`; the tag is written as 16 lower-case hexadecimal digits. A phone
/// takes the tags of the day before, the day and the day after, so that clocks a little apart still meet.
///
/// RemoteKit does not hold this yet: it is written here first, and belongs in RemoteKit beside the join token, where the
/// phone (P12) can share it (#675's report).
package enum HomeTag {
	package static func key(channelKey: Curve25519.KeyAgreement.PublicKey, pairing: PairingID) -> SymmetricKey {
		var material = Data("pi2-tag".utf8)
		material.append(0)
		material.append(channelKey.rawRepresentation)
		material.append(0)
		material.append(contentsOf: pairing.text.utf8)
		return SymmetricKey(data: SHA256.hash(data: material))
	}

	package static func day(_ date: Date) -> String {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .gmt
		let parts = calendar.dateComponents([.year, .month, .day], from: date)
		return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
	}

	package static func tag(channelKey: Curve25519.KeyAgreement.PublicKey, pairing: PairingID, date: Date) -> String {
		let mac = HMAC<SHA256>.authenticationCode(for: Data(day(date).utf8), using: key(channelKey: channelKey, pairing: pairing))
		return Data(mac).prefix(8).map { String(format: "%02x", $0) }.joined()
	}

	/// The TXT record's bytes: `v=2` and `t=<tag>`, each a length byte and its text.
	package static func txtRecord(tag: String) -> Data {
		var record = Data()
		for entry in ["v=2", "t=\(tag)"] {
			record.append(UInt8(entry.utf8.count))
			record.append(contentsOf: entry.utf8)
		}
		return record
	}
}

/// Advertising the home path on Bonjour, `_pi2._tcp` with the tag: a release build's alone. A development build and
/// every throwaway copy advertise nothing (5.4, 10): the call is not compiled into them, so they cannot set off the
/// Local Network prompt.
package protocol Advertiser: AnyObject {
	func advertise(port: UInt16, txt: Data)
	func stop()
}

#if !PI2_DEVELOPMENT
import dnssd

/// `DNSServiceRegister` for `_pi2._tcp` on every interface, with the Mac's name as macOS gives it to Bonjour, on the
/// helper's queue. This is where macOS asks the person, once, for the Local Network privilege for pi² Remote, which
/// the Devices page says first (5.5). Never run on a Mac where pi² is in real use by an agent.
final class BonjourAdvertiser: Advertiser, @unchecked Sendable {
	private let queue: DispatchQueue
	private var service: DNSServiceRef?

	init(queue: DispatchQueue) { self.queue = queue }

	func advertise(port: UInt16, txt: Data) {
		stop()
		var reference: DNSServiceRef?
		let status = txt.withUnsafeBytes { bytes in
			DNSServiceRegister(&reference, 0, 0, nil, "_pi2._tcp", nil, nil, port.bigEndian, UInt16(bytes.count), bytes.baseAddress, nil, nil)
		}
		guard status == kDNSServiceErr_NoError, let reference else {
			log("Bonjour: _pi2._tcp could not be advertised (\(status))")
			return
		}
		DNSServiceSetDispatchQueue(reference, queue)
		service = reference
	}

	func stop() {
		if let service { DNSServiceRefDeallocate(service) }
		service = nil
	}
}
#endif

package enum Advertisers {
	/// The advertiser of a build of `kind`, or nil: a development build has none.
	package static func forBuild(_ kind: BuildKind, queue: DispatchQueue) -> (any Advertiser)? {
		#if PI2_DEVELOPMENT
		return nil
		#else
		return kind == .release ? BonjourAdvertiser(queue: queue) : nil
		#endif
	}
}
