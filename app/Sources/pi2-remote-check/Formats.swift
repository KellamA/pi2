import CryptoKit
import Foundation
import RemoteKit

/// What each reader takes and refuses, case by case. The fuzzer tries the rest.
enum Formats {
	static func run() {
		bytes()
		json()
		frames()
		payload()
		lines()
	}

	static func bytes() {
		Check.section("Bytes and base64url")
		Check.that(Bytes.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])), "equal bytes compare equal")
		Check.that(!Bytes.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])), "different bytes compare different")
		Check.that(!Bytes.constantTimeEqual(Data([1, 2]), Data([1, 2, 3])), "different lengths compare different")
		for count in 0..<40 {
			let data = Bytes.random(count)
			Check.that(Base64URL.decode(Base64URL.encode(data)) == data, "base64url reads back \(count) bytes")
		}
		Check.that(Base64URL.encode(Data([0xfb, 0xff])) == "-_8", "base64url uses - and _")
		Check.that(Base64URL.decode("-_8=") == nil, "base64url with padding is refused")
		Check.that(Base64URL.decode("+/8") == nil, "base64's other alphabet is refused")
		Check.that(Base64URL.decode("-_9") == nil, "a last character with bits that are not zero is refused")
		Check.that(Base64URL.decode("A") == nil, "a length no bytes have is refused")
		Check.that(Base64URL.decode("AA AA") == nil, "white space is refused")
		Check.that(PairingID(Base64URL.encode(Bytes.random(15))) == nil, "a pairing's id of 15 bytes is refused")
		Check.that(DeviceID("dev_" + Base64URL.encode(Bytes.random(16))) != nil, "a device's id reads")
		Check.that(DeviceID("dav_" + Base64URL.encode(Bytes.random(16))) == nil, "a device's id without dev_ is refused")
		Check.that(SessionID("") == nil && SessionID("a b") == nil && SessionID(String(repeating: "a", count: 65)) == nil, "session ids are kept to their form")
		let key = P256.Signing.PrivateKey().publicKey
		Check.that(PublicKeys.signingKey(fromBase64URL: PublicKeys.text(key)) != nil, "an SPKI key reads")
		Check.that(PublicKeys.signingKey(fromBase64URL: Base64URL.encode(key.x963Representation)) == nil, "a key that is not SPKI DER is refused")
		Check.that(PublicKeys.signingKey(fromBase64URL: Base64URL.encode(key.compressedRepresentation)) == nil, "a compressed key is refused")
	}

	static func json() {
		Check.section("JSON as RemoteKit reads it")
		let good = #"{"a":[1,-2.5e3,true,false,null,"x\"\\\/\b\f\n\r\t\u00e9\ud83d\ude00"],"b":{}}"#
		Check.runs("a value with every kind reads") { _ = try JSON.parse(good) }
		if let value = try? JSON.parse(good) {
			Check.that((try? JSON.parse(JSON.write(value))) == value, "what is written reads back as the same value")
			Check.that(JSON.write((try? JSON.parse(JSON.write(value))) ?? .null) == JSON.write(value), "writing is stable")
		}
		for (text, why) in [
			(#"{"a":1,"a":2}"#, "a key twice"),
			(#"{"a":1} "#, "white space after the value"),
			(#" {"a":1}"#, "white space before the value"),
			(#"{"a":1}{"#, "bytes after the value"),
			(#"{"a":01}"#, "a number with a leading zero"),
			(#"{"a":1.}"#, "a number with no digits after the point"),
			(#"{"a":"\ud800"}"#, "a lone surrogate"),
			(#"{"a":"\udc00\ud800"}"#, "surrogates in the wrong order"),
			("{\"a\":\"\u{01}\"}", "a control character"),
			(#"{"a":"\x"}"#, "an unknown escape"),
			(#"{"a":tru}"#, "a broken literal"),
			(#"{a:1}"#, "a key that is not a string"),
			(#"[1,]"#, "a trailing comma"),
			(String(repeating: "[", count: 40) + String(repeating: "]", count: 40), "nesting too deep"),
			("{\"a\":\"" + "1" + "\"}" + "\u{0}", "a zero byte after the value"),
			(#"{"a":1e999999999999999999999999999999999999999999}"#, "a number too long"),
		] {
			Check.refuses("JSON with \(why)") { _ = try JSON.parse(text) }
		}
		Check.refuses("JSON that is not UTF-8") { _ = try JSON.parse(Data([0x22, 0xc0, 0x80, 0x22])) }
		Check.refuses("JSON with an encoded surrogate") { _ = try JSON.parse(Data([0x22, 0xed, 0xa0, 0x80, 0x22])) }
		// The Kelvin sign is canonically equivalent to K in Swift, but not to the engine's JavaScript.
		if let value = try? JSON.parse("{\"\u{212A}\":1}") {
			Check.that(value["K"] == nil, "a key is found by its bytes, not by canonical equivalence")
		}
		Check.that((try? JSON.parse(#"{"n":9007199254740991}"#))?["n"]?.integerValue == 9_007_199_254_740_991, "the largest safe integer reads")
		Check.that((try? JSON.parse(#"{"n":9007199254740992}"#))?["n"]?.integerValue == nil, "a larger integer is not taken as one")
		Check.that((try? JSON.parse(#"{"n":-9223372036854775808}"#))?["n"]?.integerValue == nil, "the smallest Int64 is not taken as one")
	}

	static func frames() {
		Check.section("Frames and the TCP path's framing")
		Check.runs("frames read back, padded and not") {
			for frame in [try Frame(.data, Data("x".utf8)), try Frame(.more, Data(repeating: 7, count: 300)), Frame.ack(42), try Frame(.ping), try Frame(.bye)] {
				for block in [nil, 256] as [Int?] {
					let bytes = frame.encoded(padTo: block)
					guard try Frame.decode(bytes) == frame else { throw RemoteKitError("check", "a frame did not read back") }
					if block != nil, bytes.count % 256 != 0 { throw RemoteKitError("check", "a frame was not padded") }
				}
			}
		}
		Check.refuses("a frame with padding that is not zeros") { _ = try Frame.decode(Data([1, 0, 1, 0x41, 0, 7])) }
		Check.refuses("a frame of an unknown kind") { _ = try Frame.decode(Data([9, 0, 0])) }
		Check.refuses("a frame of kind zero") { _ = try Frame.decode(Data([0, 0, 0])) }
		Check.refuses("an ack whose body is not eight bytes") { _ = try Frame.decode(Data([3, 0, 1, 5])) }
		Check.refuses("a ping with a body") { _ = try Frame.decode(Data([4, 0, 1, 5])) }
		Check.refuses("a frame whose body runs past it") { _ = try Frame.decode(Data([1, 0, 9, 5])) }
		Check.refuses("a frame too short for its header") { _ = try Frame.decode(Data([1, 0])) }
		Check.refuses("an empty more frame") { _ = try Frame.decode(Data([2, 0, 0])) }
		Check.refuses("a frame longer than a Noise plaintext") { _ = try Frame.decode(Data([1, 0, 0]) + Data(repeating: 0, count: Noise.maxPlaintextLength)) }
		Check.refuses("a line holding a line break") { _ = try Lines.frames(for: Data("a\nb".utf8)) }
		Check.refuses("an empty line") { _ = try Lines.frames(for: Data()) }
		var assembler = LineAssembler(maxLength: 10)
		Check.refuses("a line longer than allowed") {
			_ = try assembler.take(try Frame(.more, Data(repeating: 0x61, count: 6)))
			_ = try assembler.take(try Frame(.data, Data(repeating: 0x61, count: 6)))
		}
		var empty = LineAssembler()
		Check.refuses("an empty data frame alone") { _ = try empty.take(try Frame(.data)) }
		var framing = LengthFraming()
		Check.runs("the TCP framing takes a message in pieces and two at once") {
			let a = try LengthFraming.encode(Data(repeating: 1, count: 48))
			let b = try LengthFraming.encode(Data(repeating: 2, count: 20))
			guard try framing.push(a.prefix(1)).isEmpty, try framing.push(a.dropFirst(1) + b.prefix(3)).count == 1,
				try framing.push(b.dropFirst(3)) == [Data(repeating: 2, count: 20)], framing.buffered == 0
			else { throw RemoteKitError("check", "framing") }
		}
		var short = LengthFraming()
		Check.refuses("a TCP message shorter than a tag") { _ = try short.push(Data([0, 3, 1, 2, 3])) }
		var zero = LengthFraming()
		Check.refuses("a TCP message of length zero") { _ = try zero.push(Data([0, 0])) }
		Check.refuses("a TCP message longer than Noise allows") { _ = try LengthFraming.encode(Data(repeating: 0, count: 65536)) }
	}

	static func payload() {
		Check.section("The pairing payload")
		let identity = P256.Signing.PrivateKey().publicKey
		let record = P256.KeyAgreement.PrivateKey().publicKey
		let channel = Curve25519.KeyAgreement.PrivateKey().publicKey
		guard let payload = try? PairingPayload(
			pairing: PairingID.random(), macName: "Alex's Mac & 'Studio' (2) é", channelKey: channel, identityKey: identity, recordKey: record,
			secret: Bytes.random(32), relay: "wss://relay.example.dev/v1", addresses: ["10.0.0.2:1", "[::1]:65535", "[fe80::1:2:3:4]:443"],
			expires: 1_800_000_000)
		else {
			Check.that(false, "a payload is made")
			return
		}
		let text = payload.text
		Check.that(text.hasPrefix("pi2://pair?v=2&p="), "the payload starts as iphone.md 3.1 writes it")
		Check.that((try? PairingPayload.parse(text)) == payload, "the payload reads back")
		Check.that(text.contains("n=Alex's%20Mac%20%26%20'Studio'%20(2)%20%C3%A9"), "the name is escaped as encodeURIComponent escapes it")
		Check.that(payload.isOpen(at: Date(timeIntervalSince1970: 1_799_999_999)) && !payload.isOpen(at: Date(timeIntervalSince1970: 1_800_000_000)), "expiry")
		func variant(_ change: (String) -> String, _ why: String) {
			Check.refuses("a payload with \(why)") { _ = try PairingPayload.parse(change(text)) }
		}
		func replacing(_ name: String, _ value: String) -> (String) -> String {
			{ text in
				text.split(separator: "&").map { $0.hasPrefix("\(name)=") || $0.hasPrefix("pi2://pair?\(name)=") ? ($0.hasPrefix("pi2") ? "pi2://pair?" : "") + "\(name)=\(value)" : String($0) }
					.joined(separator: "&")
			}
		}
		variant({ $0 + "&x=1" }, "an unknown parameter")
		variant({ $0 + "&v=2" }, "a parameter twice")
		variant({ $0.replacingOccurrences(of: "&e=1800000000", with: "") }, "a parameter missing")
		variant({ $0.replacingOccurrences(of: "pi2://pair?", with: "pi2://pairing?") }, "another host")
		variant({ $0.replacingOccurrences(of: "pi2://", with: "https://") }, "another scheme")
		variant(replacing("v", "3"), "another version")
		variant(replacing("n", "Alex+Mac"), "a +, which encodeURIComponent never writes")
		variant(replacing("n", "%FF"), "a name that is not UTF-8")
		variant(replacing("n", "%0A"), "a line break in the name")
		variant(replacing("n", ""), "an empty name")
		variant(replacing("n", "%zz"), "a broken escape")
		variant(replacing("s", Base64URL.encode(Bytes.random(31))), "a secret of 31 bytes")
		variant(replacing("c", Base64URL.encode(Bytes.random(33))), "a channel key of 33 bytes")
		variant(replacing("i", Base64URL.encode(identity.x963Representation)), "an identity key that is not SPKI")
		variant(replacing("r", "AAAA"), "a record key that is not a key")
		variant(replacing("u", PairingPayload.escape("ws://relay.example.dev/v1")), "a relay reached without TLS")
		variant(replacing("u", PairingPayload.escape("wss://user@relay.example.dev/v1")), "a relay address with a user")
		variant(replacing("u", PairingPayload.escape("wss://relay.example.dev/v1?x=1")), "a relay address with a query")
		variant(replacing("u", PairingPayload.escape("wss://relay.example.dev:0/v1")), "a relay on port zero")
		variant(replacing("a", PairingPayload.escape("10.0.0.256:1")), "an address that is not IPv4")
		variant(replacing("a", PairingPayload.escape("[fe80::1%en0]:1")), "an address with a zone")
		variant(replacing("a", PairingPayload.escape("[1::2::3]:1")), "an IPv6 address with :: twice")
		variant(replacing("a", PairingPayload.escape("10.0.0.1")), "an address without its port")
		variant(replacing("a", PairingPayload.escape("example.com:1")), "an address that is a name")
		variant(replacing("e", "0123"), "an expiry with a leading zero")
		variant(replacing("e", "-1"), "a negative expiry")
		variant({ $0 + String(repeating: "x", count: 5000) }, "more than 4,096 bytes")
		Check.that((try? PairingPayload.parse(replacing("u", PairingPayload.escape("ws://127.0.0.1:8787/v1"))(text))) != nil, "a relay on this Mac's loopback is taken")
		Check.that((try? PairingPayload.parse(replacing("a", "")(text)))?.addresses == [], "no addresses is taken")
		for address in ["[::]:1", "[::ffff:10.0.0.1]:1", "[2001:db8:0:0:0:0:2:1]:1", "[2001:db8::2:1]:1"] {
			Check.that(PairingPayload.isHostAndPort(address), "\(address) is an address")
		}
		for address in ["[2001:db8:0:0:0:0:2:1:5]:1", "[12345::1]:1", "[::1]", "1.2.3:4", "[::1]:65536", "[::1]:01"] {
			Check.that(!PairingPayload.isHostAndPort(address), "\(address) is not an address")
		}
	}

	static func lines() {
		Check.section("The channel's own lines")
		for (text, why) in [
			(#"{"pair":{}}"#, "a pair with nothing in it"),
			(#"{"attached":{"session":"s1","resume":true,"x":1}}"#, "an unknown field"),
			(#"{"attached":{"session":"s 1","resume":true}}"#, "a session id of another form"),
			(#"{"attached":{"session":"s1","resume":1}}"#, "resume that is not true or false"),
			(#"{"sessionEnd":{"x":1}}"#, "a sessionEnd that is not empty"),
			(#"{"id":1,"method":"projects.list"}"#, "an engine line"),
			(#"{"paired":{"device":"x","pairing":"y","name":"n","addresses":[]}}"#, "ids of no form"),
			(#"{"challenge":"AAAA","mac":{"signed":"{}","signature":"AAAA"}}"#, "a challenge that is not 32 bytes"),
			(#"{"attach":{"signed":"{}","signature":"AAAA","presence":"AAAA"}}"#, "signatures that are not 64 bytes"),
			("{}", "no member"),
		] {
			Check.refuses("a line with \(why)") { _ = try ControlLine.parse(Data(text.utf8)) }
		}
		Check.that((try? ControlLine.parse(Data(#"{"attached":{"session":"s1","resume":true}}"#.utf8))) != nil, "attached reads")
	}
}
