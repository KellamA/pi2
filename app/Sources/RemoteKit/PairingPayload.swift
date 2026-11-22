import CryptoKit
import Foundation

/// What the Mac shows as a QR code and the phone scans (iphone.md 3.1):
///
///     pi2://pair?v=2&p=<pairing>&n=<Mac's name>&c=<channel key>&i=<identity key>&r=<record key>&s=<secret>&u=<relay>&a=<address:port,…>&e=<expiry>
///
/// Each value is written as JavaScript's `encodeURIComponent` writes it (letters, digits and `-_.!~*'()` as they are,
/// every other byte of its UTF-8 as `%XX` in upper case), so the engine can make the text with that function. Reading is
/// strict, so that each payload has one spelling: every parameter exactly once and no other, no `+`, no lower-case
/// escape and no escape of a character that needs none, only valid UTF-8, and each value checked for what it is. The
/// Mac's name may hold no control or invisible formatting character (`ShownText`).
///
/// The secret `s` is never in `description`, `debugDescription` or a mirror (`dump`): printing a payload cannot put it in
/// a log.
public struct PairingPayload: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	public static let version = 2
	public static let maxLength = 4096
	public static let maxAddresses = 16
	public static let maxNameLength = 128

	public var pairing: PairingID
	/// The Mac's name, as macOS gives it.
	public var macName: String
	/// `c`: the Mac's channel key, a Curve25519 public key.
	public var channelKey: Curve25519.KeyAgreement.PublicKey
	/// `i`: the Mac's identity key.
	public var identityKey: P256.Signing.PublicKey
	/// `r`: the Mac's record key.
	public var recordKey: P256.KeyAgreement.PublicKey
	/// `s`: the 32-byte secret of this pairing alone, the pre-shared key of the pairing handshake.
	public var secret: Data
	/// `u`: the relay's address.
	public var relay: String
	/// `a`: the Mac's addresses on its network now, each `a.b.c.d:port` or `[v6]:port`.
	public var addresses: [String]
	/// `e`: when the join window closes, in seconds since 1970.
	public var expires: Int64

	public init(
		pairing: PairingID, macName: String, channelKey: Curve25519.KeyAgreement.PublicKey, identityKey: P256.Signing.PublicKey,
		recordKey: P256.KeyAgreement.PublicKey, secret: Data, relay: String, addresses: [String], expires: Int64
	) throws {
		self.pairing = pairing
		self.macName = macName
		self.channelKey = channelKey
		self.identityKey = identityKey
		self.recordKey = recordKey
		self.secret = secret
		self.relay = relay
		self.addresses = addresses
		self.expires = expires
		try check()
	}

	public static func == (lhs: PairingPayload, rhs: PairingPayload) -> Bool {
		lhs.pairing == rhs.pairing && lhs.macName.sameBytes(rhs.macName)
			&& Bytes.constantTimeEqual(lhs.channelKey.rawRepresentation, rhs.channelKey.rawRepresentation)
			&& Bytes.constantTimeEqual(lhs.identityKey.derRepresentation, rhs.identityKey.derRepresentation)
			&& Bytes.constantTimeEqual(lhs.recordKey.derRepresentation, rhs.recordKey.derRepresentation)
			&& Bytes.constantTimeEqual(lhs.secret, rhs.secret) && lhs.relay.sameBytes(rhs.relay)
			&& lhs.addresses.count == rhs.addresses.count && zip(lhs.addresses, rhs.addresses).allSatisfy { $0.sameBytes($1) }
			&& lhs.expires == rhs.expires
	}

	public var description: String { "pairing \(pairing) with \(macName), until \(expires)" }
	public var debugDescription: String { description }

	public var customMirror: Mirror {
		Mirror(self, children: ["pairing": pairing.text, "macName": macName, "relay": relay, "addresses": addresses, "expires": expires], displayStyle: .struct)
	}

	/// Whether the join window this payload names is still open at `date`, by the phone's clock.
	public func isOpen(at date: Date) -> Bool { Int64(date.timeIntervalSince1970) < expires }

	/// The payload's text.
	public var text: String {
		let fields: [(String, String)] = [
			("v", String(Self.version)),
			("p", pairing.text),
			("n", macName),
			("c", PublicKeys.text(channelKey)),
			("i", PublicKeys.text(identityKey)),
			("r", PublicKeys.text(recordKey)),
			("s", Base64URL.encode(secret)),
			("u", relay),
			("a", addresses.joined(separator: ",")),
			("e", String(expires)),
		]
		return "pi2://pair?" + fields.map { "\($0.0)=\(Self.escape($0.1))" }.joined(separator: "&")
	}

	private static let prefix = "pi2://pair?"
	private static let names = ["v", "p", "n", "c", "i", "r", "s", "u", "a", "e"]

	public static func parse(_ text: String) throws -> PairingPayload {
		func fail(_ reason: String) -> RemoteKitError { RemoteKitError("pairing payload", reason) }
		guard text.utf8.count <= maxLength else { throw fail("too long") }
		guard text.utf8.starts(with: prefix.utf8) else { throw fail("not a pi2://pair link") }
		let query = String(decoding: text.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
		var values: [String: String] = [:]
		for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
			let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
			guard parts.count == 2 else { throw fail("a parameter with no value") }
			let name = String(parts[0])
			guard names.contains(where: { $0.sameBytes(name) }) else { throw fail("an unknown parameter") }
			guard values[name] == nil else { throw fail("a parameter twice") }
			guard let value = unescape(String(parts[1])) else { throw fail("a value that is not written as encodeURIComponent writes it") }
			values[name] = value
		}
		for name in names where values[name] == nil { throw fail("a parameter is missing") }

		guard values["v"]!.sameBytes(String(version)) else { throw fail("not version 2") }
		guard let pairing = PairingID(values["p"]!) else { throw fail("p is not a pairing's id") }
		guard let channelKey = PublicKeys.channelKey(fromBase64URL: values["c"]!) else { throw fail("c is not a channel key") }
		guard let identityKey = PublicKeys.signingKey(fromBase64URL: values["i"]!) else { throw fail("i is not a P-256 key") }
		guard let recordKey = PublicKeys.agreementKey(fromBase64URL: values["r"]!) else { throw fail("r is not a P-256 key") }
		guard let secret = Base64URL.decode(values["s"]!, count: 32) else { throw fail("s is not 32 bytes") }
		let addressText = values["a"]!
		let addresses = addressText.isEmpty ? [] : addressText.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
		guard let expires = Self.seconds(values["e"]!) else { throw fail("e is not a time") }
		return try PairingPayload(
			pairing: pairing, macName: values["n"]!, channelKey: channelKey, identityKey: identityKey, recordKey: recordKey,
			secret: secret, relay: values["u"]!, addresses: addresses, expires: expires)
	}

	private func check() throws {
		func fail(_ reason: String) -> RemoteKitError { RemoteKitError("pairing payload", reason) }
		guard !macName.isEmpty, macName.utf8.count <= Self.maxNameLength, ShownText.isShowable(macName) else { throw fail("n is not a Mac's name") }
		guard secret.count == 32 else { throw fail("s is not 32 bytes") }
		guard Self.isRelayAddress(relay) else { throw fail("u is not a relay's address") }
		guard addresses.count <= Self.maxAddresses, addresses.allSatisfy(Self.isHostAndPort) else { throw fail("a is not a list of addresses") }
		guard expires > 0 else { throw fail("e is not a time") }
	}

	// MARK: Escaping as encodeURIComponent does

	private static func isUnescaped(_ byte: UInt8) -> Bool {
		switch byte {
		case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): true
		case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "!"), UInt8(ascii: "~"), UInt8(ascii: "*"),
			UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"):
			true
		default: false
		}
	}

	/// `text` written as encodeURIComponent writes it.
	public static func escape(_ text: String) -> String {
		let hex = Array("0123456789ABCDEF".utf8)
		var out = [UInt8]()
		for byte in text.utf8 {
			if isUnescaped(byte) {
				out.append(byte)
			} else {
				out += [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 15)]]
			}
		}
		return String(decoding: out, as: UTF8.self)
	}

	static func unescape(_ text: String) -> String? {
		let bytes = Array(text.utf8)
		var out = [UInt8]()
		var index = 0
		while index < bytes.count {
			let byte = bytes[index]
			if byte == UInt8(ascii: "%") {
				// Only upper-case hex, and only for a byte encodeURIComponent escapes: each value has one spelling.
				guard index + 2 < bytes.count, let high = upperHexValue(bytes[index + 1]), let low = upperHexValue(bytes[index + 2]),
					!isUnescaped(high << 4 | low)
				else { return nil }
				out.append(high << 4 | low)
				index += 3
			} else {
				guard isUnescaped(byte) else { return nil }
				out.append(byte)
				index += 1
			}
		}
		// Only valid UTF-8: String(validating:) refuses anything else rather than putting in replacement characters.
		return String(validating: out, as: UTF8.self)
	}

	private static func upperHexValue(_ byte: UInt8) -> UInt8? {
		switch byte {
		case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
		case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
		default: nil
		}
	}

	private static func hexValue(_ byte: UInt8) -> UInt8? {
		switch byte {
		case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
		case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
		case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
		default: nil
		}
	}

	private static func seconds(_ text: String) -> Int64? {
		let digits = Array(text.utf8)
		guard (1...12).contains(digits.count), digits.allSatisfy({ $0 >= 48 && $0 <= 57 }), digits.count == 1 || digits[0] != 48 else { return nil }
		return Int64(text)
	}

	// MARK: Addresses

	/// `wss://host[:port]/path`, or `ws://` to this Mac's own loopback address, for a relay run here in tests (iphone.md 10).
	public static func isRelayAddress(_ text: String) -> Bool {
		guard text.utf8.count <= 256 else { return false }
		let secure = text.hasPrefix("wss://")
		guard secure || text.hasPrefix("ws://") else { return false }
		let rest = text.dropFirst(secure ? 6 : 5)
		guard let slash = rest.firstIndex(of: "/") else { return false }
		let authority = String(rest[..<slash])
		let path = rest[slash...]
		guard path.utf8.allSatisfy(isPathByte) else { return false }
		guard let host = hostOfAuthority(authority, portRequired: false) else { return false }
		if !secure { return host == "localhost" || host == "127.0.0.1" || host == "[::1]" }
		return true
	}

	/// Letters, digits, `-_.~` and `/`: RFC 3986's unreserved characters and the separator, which is all a relay's path needs.
	private static func isPathByte(_ byte: UInt8) -> Bool {
		switch byte {
		case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
			UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"), UInt8(ascii: "/"):
			true
		default: false
		}
	}

	/// `a.b.c.d:port` or `[v6]:port`, as the `home` and `direct` paths take them.
	public static func isHostAndPort(_ text: String) -> Bool {
		guard text.utf8.count <= 64, let host = hostOfAuthority(text, portRequired: true) else { return false }
		return host.hasPrefix("[") || isIPv4(host)
	}

	/// The host of `host[:port]`, if both are well formed.
	private static func hostOfAuthority(_ authority: String, portRequired: Bool) -> String? {
		var host = authority
		var port: Substring?
		if authority.hasPrefix("[") {
			guard let close = authority.firstIndex(of: "]") else { return nil }
			host = String(authority[...close])
			let after = authority[authority.index(after: close)...]
			if !after.isEmpty {
				guard after.hasPrefix(":") else { return nil }
				port = after.dropFirst()
			}
			guard isIPv6(String(host.dropFirst().dropLast())) else { return nil }
		} else {
			let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
			guard parts.count <= 2 else { return nil }
			host = String(parts[0])
			if parts.count == 2 { port = parts[1] }
			guard isHostName(host) else { return nil }
		}
		if let port {
			guard isPort(port) else { return nil }
		} else if portRequired {
			return nil
		}
		return host
	}

	private static func isPort(_ text: Substring) -> Bool {
		let digits = Array(text.utf8)
		guard (1...5).contains(digits.count), digits.allSatisfy({ $0 >= 48 && $0 <= 57 }), digits[0] != 48, let value = Int(text) else { return false }
		return value <= 65535
	}

	private static func isHostName(_ host: String) -> Bool {
		guard (1...253).contains(host.utf8.count) else { return false }
		let labels = host.split(separator: ".", omittingEmptySubsequences: false)
		return labels.allSatisfy { label in
			(1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
				&& label.utf8.allSatisfy { byte in
					switch byte {
					case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
						UInt8(ascii: "-"):
						true
					default: false
					}
				}
		}
	}

	static func isIPv4(_ text: String) -> Bool {
		let parts = text.split(separator: ".", omittingEmptySubsequences: false)
		guard parts.count == 4 else { return false }
		return parts.allSatisfy { part in
			let digits = Array(part.utf8)
			guard (1...3).contains(digits.count), digits.allSatisfy({ $0 >= 48 && $0 <= 57 }), digits.count == 1 || digits[0] != 48 else { return false }
			return Int(part)! <= 255
		}
	}

	/// An IPv6 address as RFC 4291 section 2.2 writes it, without a zone: eight groups of one to four hex digits, `::` at
	/// most once for one or more groups of zeros, and an IPv4 address as the last two groups.
	static func isIPv6(_ text: String) -> Bool {
		guard (2...45).contains(text.utf8.count) else { return false }
		let halves = text.components(separatedBy: "::")
		guard halves.count <= 2 else { return false }
		func groups(_ part: String, last: Bool) -> Int? {
			if part.isEmpty { return 0 }
			let pieces = part.split(separator: ":", omittingEmptySubsequences: false)
			var count = 0
			for (index, piece) in pieces.enumerated() {
				if last, index == pieces.count - 1, piece.contains(".") {
					guard isIPv4(String(piece)) else { return nil }
					count += 2
				} else {
					guard (1...4).contains(piece.utf8.count), piece.utf8.allSatisfy({ hexValue($0) != nil }) else { return nil }
					count += 1
				}
			}
			return count
		}
		if halves.count == 1 { return groups(halves[0], last: true) == 8 }
		guard let before = groups(halves[0], last: false), let after = groups(halves[1], last: true) else { return false }
		return before + after <= 7
	}
}
