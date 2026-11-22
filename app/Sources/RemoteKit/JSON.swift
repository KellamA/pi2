import Foundation

/// A JSON value, as RemoteKit reads and writes the lines it owns: the first lines of a channel and what is inside a
/// sealed item (iphone.md 5.6, 5.3). The engine's own lines pass through a channel as bytes and are never read here.
///
/// Reading is strict, so that the text one side signs means one thing to every reader: RFC 8259's grammar, no white
/// space before or after the value, no key twice in an object (compared byte for byte), only valid UTF-8 and no lone
/// surrogate, at most `JSON.maxDepth` levels, and nothing after the value. A number keeps the text it was written as.
public indirect enum JSONValue: Equatable, Sendable {
	case null
	case bool(Bool)
	/// The number as written, checked against the grammar.
	case number(String)
	case string(String)
	case array([JSONValue])
	/// Members in the order written. Keys are unique.
	case object([(String, JSONValue)])

	public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
		switch (lhs, rhs) {
		case (.null, .null): return true
		case let (.bool(a), .bool(b)): return a == b
		case let (.number(a), .number(b)): return a.sameBytes(b)
		case let (.string(a), .string(b)): return a.sameBytes(b)
		case let (.array(a), .array(b)): return a == b
		case let (.object(a), .object(b)):
			return a.count == b.count && zip(a, b).allSatisfy { $0.0.sameBytes($1.0) && $0.1 == $1.1 }
		default: return false
		}
	}

	/// A whole number. Keep it from -(2^53 - 1) to 2^53 - 1, which JavaScript reads exactly: `integerValue` takes no other.
	public static func integer(_ value: Int64) -> JSONValue { .number(String(value)) }

	public subscript(key: String) -> JSONValue? {
		guard case let .object(members) = self else { return nil }
		return members.first { $0.0.sameBytes(key) }?.1
	}

	public var stringValue: String? {
		if case let .string(text) = self { return text }
		return nil
	}

	/// The value as a whole number that JavaScript reads exactly, written with no fraction or exponent.
	public var integerValue: Int64? {
		guard case let .number(text) = self else { return nil }
		guard !text.contains("."), !text.contains("e"), !text.contains("E") else { return nil }
		guard let value = Int64(text), value >= -JSON.maxSafeInteger, value <= JSON.maxSafeInteger else { return nil }
		return value
	}

	public var boolValue: Bool? {
		if case let .bool(value) = self { return value }
		return nil
	}

	public var isNull: Bool {
		if case .null = self { return true }
		return false
	}

	/// The keys of an object, in order.
	public var keys: [String]? {
		guard case let .object(members) = self else { return nil }
		return members.map(\.0)
	}
}

public enum JSON {
	public static let maxDepth = 32
	public static let maxSafeInteger: Int64 = 9_007_199_254_740_991
	/// The longest number text taken. JSON.stringify writes none longer.
	static let maxNumberLength = 40

	/// Reads `data` as one JSON value and nothing else.
	public static func parse<D: DataProtocol>(_ data: D) throws -> JSONValue {
		var parser = Parser(bytes: Array(data))
		let value = try parser.value(depth: 0)
		if parser.index != parser.bytes.count { throw RemoteKitError("JSON", "bytes after the value") }
		return value
	}

	public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

	/// Writes `value` compactly: no white space, members in their order, strings escaped as JSON.stringify escapes them.
	public static func write(_ value: JSONValue) -> Data {
		var out = [UInt8]()
		write(value, into: &out)
		return Data(out)
	}

	public static func text(_ value: JSONValue) -> String { String(decoding: write(value), as: UTF8.self) }

	private static func write(_ value: JSONValue, into out: inout [UInt8]) {
		switch value {
		case .null: out += Array("null".utf8)
		case let .bool(flag): out += Array((flag ? "true" : "false").utf8)
		case let .number(text): out += Array(text.utf8)
		case let .string(text): writeString(text, into: &out)
		case let .array(items):
			out.append(UInt8(ascii: "["))
			for (index, item) in items.enumerated() {
				if index > 0 { out.append(UInt8(ascii: ",")) }
				write(item, into: &out)
			}
			out.append(UInt8(ascii: "]"))
		case let .object(members):
			out.append(UInt8(ascii: "{"))
			for (index, member) in members.enumerated() {
				if index > 0 { out.append(UInt8(ascii: ",")) }
				writeString(member.0, into: &out)
				out.append(UInt8(ascii: ":"))
				write(member.1, into: &out)
			}
			out.append(UInt8(ascii: "}"))
		}
	}

	private static func writeString(_ text: String, into out: inout [UInt8]) {
		let hex = Array("0123456789abcdef".utf8)
		out.append(UInt8(ascii: "\""))
		for byte in text.utf8 {
			switch byte {
			case UInt8(ascii: "\""): out += [UInt8(ascii: "\\"), UInt8(ascii: "\"")]
			case UInt8(ascii: "\\"): out += [UInt8(ascii: "\\"), UInt8(ascii: "\\")]
			case 0x08: out += [UInt8(ascii: "\\"), UInt8(ascii: "b")]
			case 0x0c: out += [UInt8(ascii: "\\"), UInt8(ascii: "f")]
			case 0x0a: out += [UInt8(ascii: "\\"), UInt8(ascii: "n")]
			case 0x0d: out += [UInt8(ascii: "\\"), UInt8(ascii: "r")]
			case 0x09: out += [UInt8(ascii: "\\"), UInt8(ascii: "t")]
			case 0..<0x20: out += Array("\\u00".utf8) + [hex[Int(byte >> 4)], hex[Int(byte & 15)]]
			default: out.append(byte)
			}
		}
		out.append(UInt8(ascii: "\""))
	}

	private struct Parser {
		let bytes: [UInt8]
		var index = 0

		init(bytes: [UInt8]) { self.bytes = bytes }

		func fail(_ reason: String) -> RemoteKitError { RemoteKitError("JSON", reason) }

		mutating func skipSpace() {
			while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 }
		}

		mutating func value(depth: Int) throws -> JSONValue {
			guard depth <= JSON.maxDepth else { throw fail("nested too deeply") }
			guard index < bytes.count else { throw fail("ends early") }
			switch bytes[index] {
			case UInt8(ascii: "{"): return try object(depth: depth)
			case UInt8(ascii: "["): return try array(depth: depth)
			case UInt8(ascii: "\""): return .string(try string())
			case UInt8(ascii: "t"): try literal("true"); return .bool(true)
			case UInt8(ascii: "f"): try literal("false"); return .bool(false)
			case UInt8(ascii: "n"): try literal("null"); return .null
			case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
			default: throw fail("not a value")
			}
		}

		mutating func literal(_ word: String) throws {
			let expected = Array(word.utf8)
			guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
				throw fail("not a value")
			}
			index += expected.count
		}

		mutating func object(depth: Int) throws -> JSONValue {
			index += 1
			var members: [(String, JSONValue)] = []
			var seen = Set<[UInt8]>()
			skipSpace()
			if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
				index += 1
				return .object(members)
			}
			while true {
				skipSpace()
				guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("a key is not a string") }
				let key = try string()
				guard seen.insert(Array(key.utf8)).inserted else { throw fail("a key twice in one object") }
				skipSpace()
				guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail("no colon after a key") }
				index += 1
				skipSpace()
				let member = try value(depth: depth + 1)
				members.append((key, member))
				skipSpace()
				guard index < bytes.count else { throw fail("ends early") }
				if bytes[index] == UInt8(ascii: ",") {
					index += 1
					continue
				}
				guard bytes[index] == UInt8(ascii: "}") else { throw fail("no comma or brace after a member") }
				index += 1
				return .object(members)
			}
		}

		mutating func array(depth: Int) throws -> JSONValue {
			index += 1
			var items: [JSONValue] = []
			skipSpace()
			if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
				index += 1
				return .array(items)
			}
			while true {
				skipSpace()
				items.append(try value(depth: depth + 1))
				skipSpace()
				guard index < bytes.count else { throw fail("ends early") }
				if bytes[index] == UInt8(ascii: ",") {
					index += 1
					continue
				}
				guard bytes[index] == UInt8(ascii: "]") else { throw fail("no comma or bracket after an item") }
				index += 1
				return .array(items)
			}
		}

		mutating func number() throws -> String {
			let start = index
			if bytes[index] == UInt8(ascii: "-") { index += 1 }
			guard index < bytes.count else { throw fail("ends early") }
			if bytes[index] == UInt8(ascii: "0") {
				index += 1
			} else if isDigit(bytes[index]) {
				while index < bytes.count, isDigit(bytes[index]) { index += 1 }
			} else {
				throw fail("not a number")
			}
			if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
				index += 1
				guard index < bytes.count, isDigit(bytes[index]) else { throw fail("not a number") }
				while index < bytes.count, isDigit(bytes[index]) { index += 1 }
			}
			if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
				index += 1
				if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
				guard index < bytes.count, isDigit(bytes[index]) else { throw fail("not a number") }
				while index < bytes.count, isDigit(bytes[index]) { index += 1 }
			}
			guard index - start <= JSON.maxNumberLength else { throw fail("a number too long") }
			return String(decoding: bytes[start..<index], as: UTF8.self)
		}

		func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

		mutating func string() throws -> String {
			index += 1
			var scalars = String.UnicodeScalarView()
			while true {
				guard index < bytes.count else { throw fail("a string ends early") }
				let byte = bytes[index]
				switch byte {
				case UInt8(ascii: "\""):
					index += 1
					return String(scalars)
				case UInt8(ascii: "\\"):
					index += 1
					guard index < bytes.count else { throw fail("a string ends early") }
					let escape = bytes[index]
					index += 1
					switch escape {
					case UInt8(ascii: "\""): scalars.append("\"")
					case UInt8(ascii: "\\"): scalars.append("\\")
					case UInt8(ascii: "/"): scalars.append("/")
					case UInt8(ascii: "b"): scalars.append("\u{08}")
					case UInt8(ascii: "f"): scalars.append("\u{0C}")
					case UInt8(ascii: "n"): scalars.append("\n")
					case UInt8(ascii: "r"): scalars.append("\r")
					case UInt8(ascii: "t"): scalars.append("\t")
					case UInt8(ascii: "u"):
						let unit = try hex4()
						if (0xD800...0xDBFF).contains(unit) {
							guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
								throw fail("a lone surrogate")
							}
							index += 2
							let low = try hex4()
							guard (0xDC00...0xDFFF).contains(low) else { throw fail("a lone surrogate") }
							let value = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
							guard let scalar = Unicode.Scalar(value) else { throw fail("a lone surrogate") }
							scalars.append(scalar)
						} else {
							guard let scalar = Unicode.Scalar(unit) else { throw fail("a lone surrogate") }
							scalars.append(scalar)
						}
					default: throw fail("an unknown escape")
					}
				case 0..<0x20:
					throw fail("a control character in a string")
				default:
					scalars.append(try utf8Scalar())
				}
			}
		}

		mutating func hex4() throws -> UInt32 {
			guard index + 4 <= bytes.count else { throw fail("a string ends early") }
			var value: UInt32 = 0
			for _ in 0..<4 {
				let byte = bytes[index]
				let digit: UInt32
				switch byte {
				case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
				case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
				case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
				default: throw fail("a bad \\u escape")
				}
				value = value << 4 | digit
				index += 1
			}
			return value
		}

		/// One scalar of well-formed UTF-8: shortest form, no surrogates, nothing past U+10FFFF.
		mutating func utf8Scalar() throws -> Unicode.Scalar {
			let first = bytes[index]
			let length: Int
			let minimum: UInt32
			var value: UInt32
			switch first {
			case 0x00...0x7F: index += 1; return Unicode.Scalar(first)
			case 0xC2...0xDF: length = 2; minimum = 0x80; value = UInt32(first & 0x1F)
			case 0xE0...0xEF: length = 3; minimum = 0x800; value = UInt32(first & 0x0F)
			case 0xF0...0xF4: length = 4; minimum = 0x10000; value = UInt32(first & 0x07)
			default: throw fail("not UTF-8")
			}
			guard index + length <= bytes.count else { throw fail("not UTF-8") }
			for offset in 1..<length {
				let next = bytes[index + offset]
				guard next & 0xC0 == 0x80 else { throw fail("not UTF-8") }
				value = value << 6 | UInt32(next & 0x3F)
			}
			guard value >= minimum, value <= 0x10FFFF, !(0xD800...0xDFFF).contains(value), let scalar = Unicode.Scalar(value) else {
				throw fail("not UTF-8")
			}
			index += length
			return scalar
		}
	}
}

/// Reading the fields of an object RemoteKit owns, with each refusal named after the part being read.
struct Fields {
	let part: String
	let members: [(String, JSONValue)]

	init(_ value: JSONValue, part: String, keys required: [String], optional: [String] = []) throws {
		self.part = part
		guard case let .object(members) = value else { throw RemoteKitError(part, "not an object") }
		for (key, _) in members where !required.contains(where: { $0.sameBytes(key) }) && !optional.contains(where: { $0.sameBytes(key) }) {
			throw RemoteKitError(part, "an unknown field")
		}
		for key in required where !members.contains(where: { $0.0.sameBytes(key) }) {
			throw RemoteKitError(part, "a field is missing")
		}
		self.members = members
	}

	func value(_ key: String) -> JSONValue? { members.first { $0.0.sameBytes(key) }?.1 }

	func string(_ key: String, maxLength: Int = 256) throws -> String {
		guard let text = value(key)?.stringValue, text.utf8.count <= maxLength else { throw RemoteKitError(part, "\(key) is not a fitting text") }
		return text
	}

	func nonEmpty(_ key: String, maxLength: Int = 256) throws -> String {
		let text = try string(key, maxLength: maxLength)
		guard !text.isEmpty, !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
			throw RemoteKitError(part, "\(key) is not a fitting text")
		}
		return text
	}

	func integer(_ key: String) throws -> Int64 {
		guard let number = value(key)?.integerValue else { throw RemoteKitError(part, "\(key) is not a whole number") }
		return number
	}

	func bytes(_ key: String, count: Int) throws -> Data {
		guard let text = value(key)?.stringValue, let data = Base64URL.decode(text, count: count) else {
			throw RemoteKitError(part, "\(key) is not \(count) bytes of base64url")
		}
		return data
	}

	func bytes(_ key: String, maxCount: Int) throws -> Data {
		guard let text = value(key)?.stringValue, text.utf8.count <= (maxCount * 4 + 2) / 3, let data = Base64URL.decode(text), !data.isEmpty else {
			throw RemoteKitError(part, "\(key) is not base64url of a fitting length")
		}
		return data
	}

	func version() throws {
		guard value("v")?.integerValue == 2 else { throw RemoteKitError(part, "not version 2") }
	}
}
