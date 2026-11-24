import CryptoKit
import Foundation
import RemoteKit

/// The home path's Bonjour TXT record: `v=2` and `t=<tag>`, the tag RemoteKit's (`HomeTag`, remotekit.md "The home
/// tag"), each a length byte and its text.
package enum HomeTXT {
	package static func record(tag: String) -> Data {
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
