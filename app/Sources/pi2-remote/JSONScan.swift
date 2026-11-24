import Foundation

/// Reads a phone's line as exactly one JSON object, as strictly as RemoteKit's reader (RFC 8259's grammar, no white
/// space before or after it, valid UTF-8 with no lone surrogate, at most 32 levels, no control character in a string),
/// **without building it** (#675's security read B, M2): a line is held once, as its bytes, and nothing in proportion to
/// it is made. What it keeps is the names of the object's own members, decoded, which pi² Remote reads to tell
/// `sessionEnd` and the channel's own lines from an engine request; a name twice among them, or more than
/// `maxMembers` of them (an engine request has three), is refused. Nil for anything else.
package enum JSONScan {
	package static let maxDepth = 32
	package static let maxMembers = 64

	package static func object(_ data: Data) -> [String]? {
		data.withUnsafeBytes { raw -> [String]? in
			var scanner = Scanner(bytes: raw.bindMemory(to: UInt8.self))
			guard scanner.peek == UInt8(ascii: "{"), let names = scanner.topObject(), scanner.index == scanner.bytes.count else { return nil }
			return names
		}
	}

	private struct Scanner {
		let bytes: UnsafeBufferPointer<UInt8>
		var index = 0

		var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

		mutating func space() {
			while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
		}

		mutating func expect(_ byte: UInt8) -> Bool {
			guard peek == byte else { return false }
			index += 1
			return true
		}

		/// The top-level object, keeping its members' names.
		mutating func topObject() -> [String]? {
			guard expect(UInt8(ascii: "{")) else { return nil }
			var names: [String] = []
			space()
			if expect(UInt8(ascii: "}")) { return names }
			while true {
				space()
				guard let name = string(keep: true) else { return nil }
				guard names.count < JSONScan.maxMembers, !names.contains(where: { $0.utf8.elementsEqual(name.utf8) }) else { return nil }
				names.append(name)
				space()
				guard expect(UInt8(ascii: ":")) else { return nil }
				space()
				guard value(depth: 2) else { return nil }
				space()
				if expect(UInt8(ascii: ",")) { continue }
				guard expect(UInt8(ascii: "}")) else { return nil }
				return names
			}
		}

		/// A value inside `depth - 1` containers: an object or array at it is the `depth`th level, at most `maxDepth`.
		mutating func value(depth: Int) -> Bool {
			guard let byte = peek else { return false }
			if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "["), depth > JSONScan.maxDepth { return false }
			switch byte {
			case UInt8(ascii: "{"):
				index += 1
				space()
				if expect(UInt8(ascii: "}")) { return true }
				while true {
					space()
					guard string(keep: false) != nil else { return false }
					space()
					guard expect(UInt8(ascii: ":")) else { return false }
					space()
					guard value(depth: depth + 1) else { return false }
					space()
					if expect(UInt8(ascii: ",")) { continue }
					return expect(UInt8(ascii: "}"))
				}
			case UInt8(ascii: "["):
				index += 1
				space()
				if expect(UInt8(ascii: "]")) { return true }
				while true {
					space()
					guard value(depth: depth + 1) else { return false }
					space()
					if expect(UInt8(ascii: ",")) { continue }
					return expect(UInt8(ascii: "]"))
				}
			case UInt8(ascii: "\""): return string(keep: false) != nil
			case UInt8(ascii: "t"): return word("true")
			case UInt8(ascii: "f"): return word("false")
			case UInt8(ascii: "n"): return word("null")
			default: return number()
			}
		}

		mutating func word(_ text: String) -> Bool {
			let expected = Array(text.utf8)
			guard index + expected.count <= bytes.count else { return false }
			for offset in 0 ..< expected.count where bytes[index + offset] != expected[offset] { return false }
			index += expected.count
			return true
		}

		mutating func digits() -> Int {
			let start = index
			while let byte = peek, byte >= 0x30, byte <= 0x39 { index += 1 }
			return index - start
		}

		mutating func number() -> Bool {
			_ = expect(UInt8(ascii: "-"))
			if expect(UInt8(ascii: "0")) {
				if let byte = peek, byte >= 0x30, byte <= 0x39 { return false }
			} else if digits() == 0 { return false }
			if expect(UInt8(ascii: ".")), digits() == 0 { return false }
			if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
				index += 1
				if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { index += 1 }
				if digits() == 0 { return false }
			}
			return true
		}

		mutating func hex4() -> UInt32? {
			guard index + 4 <= bytes.count else { return nil }
			var value: UInt32 = 0
			for _ in 0 ..< 4 {
				let byte = bytes[index]
				let digit: UInt32
				switch byte {
				case 0x30 ... 0x39: digit = UInt32(byte - 0x30)
				case 0x41 ... 0x46: digit = UInt32(byte - 0x41 + 10)
				case 0x61 ... 0x66: digit = UInt32(byte - 0x61 + 10)
				default: return nil
				}
				value = value << 4 | digit
				index += 1
			}
			return value
		}

		/// A string, decoded when `keep` (a member name of the top-level object), else only checked.
		mutating func string(keep: Bool) -> String? {
			guard expect(UInt8(ascii: "\"")) else { return nil }
			var kept = [UInt8]()
			func put(_ scalar: UInt32) {
				guard keep, let scalar = Unicode.Scalar(scalar) else { return }
				kept.append(contentsOf: Array(String(Character(scalar)).utf8))
			}
			while let byte = peek {
				switch byte {
				case UInt8(ascii: "\""):
					index += 1
					return keep ? String(decoding: kept, as: UTF8.self) : ""
				case UInt8(ascii: "\\"):
					index += 1
					guard let escape = peek else { return nil }
					index += 1
					switch escape {
					case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): put(UInt32(escape))
					case UInt8(ascii: "b"): put(0x08)
					case UInt8(ascii: "f"): put(0x0C)
					case UInt8(ascii: "n"): put(0x0A)
					case UInt8(ascii: "r"): put(0x0D)
					case UInt8(ascii: "t"): put(0x09)
					case UInt8(ascii: "u"):
						guard let unit = hex4() else { return nil }
						if (0xDC00 ... 0xDFFF).contains(unit) { return nil }
						if (0xD800 ... 0xDBFF).contains(unit) {
							guard expect(UInt8(ascii: "\\")), expect(UInt8(ascii: "u")), let low = hex4(), (0xDC00 ... 0xDFFF).contains(low) else { return nil }
							put(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
						} else {
							put(unit)
						}
					default: return nil
					}
				case 0x00 ..< 0x20:
					return nil
				case 0x20 ..< 0x80:
					if keep { kept.append(byte) }
					index += 1
				default:
					guard let length = utf8Length() else { return nil }
					if keep { kept.append(contentsOf: bytes[index ..< index + length]) }
					index += length
				}
			}
			return nil
		}

		/// The length of the valid UTF-8 sequence at `index` (not ASCII): no overlong form, no surrogate, nothing past
		/// U+10FFFF. Nil for anything else.
		func utf8Length() -> Int? {
			let first = bytes[index]
			let length: Int, low: UInt8, high: UInt8
			switch first {
			case 0xC2 ... 0xDF: (length, low, high) = (2, 0x80, 0xBF)
			case 0xE0: (length, low, high) = (3, 0xA0, 0xBF)
			case 0xE1 ... 0xEC, 0xEE ... 0xEF: (length, low, high) = (3, 0x80, 0xBF)
			case 0xED: (length, low, high) = (3, 0x80, 0x9F)
			case 0xF0: (length, low, high) = (4, 0x90, 0xBF)
			case 0xF1 ... 0xF3: (length, low, high) = (4, 0x80, 0xBF)
			case 0xF4: (length, low, high) = (4, 0x80, 0x8F)
			default: return nil
			}
			guard index + length <= bytes.count, (low ... high).contains(bytes[index + 1]) else { return nil }
			for offset in 2 ..< max(2, length) where !(0x80 ... 0xBF).contains(bytes[index + offset]) { return nil }
			return length
		}
	}
}
