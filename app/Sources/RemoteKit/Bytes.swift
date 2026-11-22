import CryptoKit
import Foundation

/// Byte helpers every part of RemoteKit shares.
public enum Bytes {
	/// Whether `a` and `b` hold the same bytes, in a time that depends on their lengths alone, never on where they first
	/// differ. Used wherever a tag, a key, a binding, a challenge or a code is compared (#674).
	public static func constantTimeEqual<A: DataProtocol, B: DataProtocol>(_ a: A, _ b: B) -> Bool {
		guard a.count == b.count else { return false }
		var difference: UInt8 = 0
		for (x, y) in zip(a, b) { difference |= x ^ y }
		return difference == 0
	}

	/// `count` random bytes from the system's generator, through CryptoKit.
	public static func random(_ count: Int) -> Data {
		// CryptoKit takes no key of zero bits.
		guard count > 0 else { return Data() }
		return SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
	}

	static func bigEndian(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xff)]) }

	static func bigEndian(_ value: UInt64) -> Data {
		Data((0..<8).reversed().map { UInt8((value >> (UInt64($0) * 8)) & 0xff) })
	}

	static func readUInt16<D: DataProtocol>(_ data: D, at offset: Int) -> UInt16 {
		let start = data.index(data.startIndex, offsetBy: offset)
		return UInt16(data[start]) << 8 | UInt16(data[data.index(after: start)])
	}

	static func readUInt64<D: DataProtocol>(_ data: D, at offset: Int) -> UInt64 {
		var value: UInt64 = 0
		var index = data.index(data.startIndex, offsetBy: offset)
		for _ in 0..<8 {
			value = value << 8 | UInt64(data[index])
			index = data.index(after: index)
		}
		return value
	}
}

/// Base64url without padding (RFC 4648 section 5), the one way RemoteKit writes bytes in text. Reading is strict: no
/// padding, no other alphabet, no white space, and the unused bits of the last character zero, so that every text it
/// takes is the one way of writing its bytes.
public enum Base64URL {
	private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

	private static let values: [Int8] = {
		var table = [Int8](repeating: -1, count: 256)
		for (index, character) in alphabet.enumerated() { table[Int(character)] = Int8(index) }
		return table
	}()

	public static func encode<D: DataProtocol>(_ data: D) -> String {
		let bytes = Array(data)
		var out = [UInt8]()
		out.reserveCapacity((bytes.count * 4 + 2) / 3)
		var index = 0
		while index + 3 <= bytes.count {
			let n = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
			out.append(alphabet[Int(n >> 18 & 63)])
			out.append(alphabet[Int(n >> 12 & 63)])
			out.append(alphabet[Int(n >> 6 & 63)])
			out.append(alphabet[Int(n & 63)])
			index += 3
		}
		let rest = bytes.count - index
		if rest == 1 {
			let n = UInt32(bytes[index]) << 16
			out.append(alphabet[Int(n >> 18 & 63)])
			out.append(alphabet[Int(n >> 12 & 63)])
		} else if rest == 2 {
			let n = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8
			out.append(alphabet[Int(n >> 18 & 63)])
			out.append(alphabet[Int(n >> 12 & 63)])
			out.append(alphabet[Int(n >> 6 & 63)])
		}
		return String(decoding: out, as: UTF8.self)
	}

	/// The bytes `text` stands for, or nil if it is not base64url written as `encode` writes it.
	public static func decode(_ text: String) -> Data? {
		let characters = Array(text.utf8)
		if characters.count % 4 == 1 { return nil }
		var out = Data()
		out.reserveCapacity(characters.count * 3 / 4)
		var buffer: UInt32 = 0
		var bits = 0
		for character in characters {
			let value = values[Int(character)]
			if value < 0 { return nil }
			buffer = buffer << 6 | UInt32(value)
			bits += 6
			if bits >= 8 {
				bits -= 8
				out.append(UInt8(buffer >> UInt32(bits) & 0xff))
				buffer &= (1 << UInt32(bits)) - 1
			}
		}
		// The bits left over must be zero, or two texts would stand for the same bytes.
		if buffer != 0 { return nil }
		return out
	}

	/// The bytes `text` stands for, which must be exactly `count` of them.
	public static func decode(_ text: String, count: Int) -> Data? {
		guard text.utf8.count == (count * 4 + 2) / 3, let data = decode(text), data.count == count else { return nil }
		return data
	}
}

extension String {
	/// Equal byte for byte in UTF-8. Swift's `==` takes canonically equivalent texts as equal (the Kelvin sign and K), which
	/// the engine's JavaScript does not; every comparison of a text read from outside uses this instead.
	func sameBytes(_ other: String) -> Bool { utf8.elementsEqual(other.utf8) }
}
