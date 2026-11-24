import CryptoKit
import Foundation
@_spi(Vectors) import RemoteKit

/// What each reader takes and refuses, case by case. The fuzzer tries the rest.
enum Formats {
	static func run() {
		bytes()
		json()
		frames()
		payload()
		lines()
		refusedLine()
		pairRefusedLine()
		homeKeyLines()
		directions()
		homeTag()
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
		Check.that(ShownText.isShowable("Alex’s iPhone") && !ShownText.isShowable("Alex\u{202E}enohPi") && !ShownText.isShowable("a\u{7}"),
			"a name with a direction-changing or control character is not shown")
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
		var many = LengthFraming()
		Check.runs("4 MB of small messages in one push come out whole, read where they lie") {
			let one = try LengthFraming.encode(Data(repeating: 9, count: 16))
			let pushed = Data((0..<(4 * 1024 * 1024 / one.count)).flatMap { _ in one })
			let messages = try many.push(pushed)
			guard messages.count == pushed.count / one.count, many.buffered == 0 else { throw RemoteKitError("check", "framing") }
		}
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
		variant(replacing("n", "Alex%c3%a9"), "a lower-case escape, which encodeURIComponent never writes")
		variant(replacing("n", "%41lex"), "an escape of a letter, which needs none")
		variant(replacing("n", "%2Dx"), "an escape of a hyphen, which needs none")
		variant(replacing("n", "Alex%E2%80%AE"), "a name with a direction-changing character (U+202E)")
		variant(replacing("n", "Al%E2%80%8Bex"), "a name with an invisible space (U+200B)")
		variant(replacing("n", "%EF%BB%BFAlex"), "a name with a byte-order mark (U+FEFF)")
		variant(replacing("n", "Alex%E2%81%A6"), "a name with an isolate (U+2066)")
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
			(#"{"paired":{"device":"x","pairing":"y","name":"n","addresses":[],"homeKey":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}}"#, "ids of no form"),
			(#"{"challenge":"AAAA","mac":{"signed":"{}","signature":"AAAA"}}"#, "a challenge that is not 32 bytes"),
			(#"{"attach":{"signed":"{}","signature":"AAAA","presence":"AAAA"}}"#, "signatures that are not 64 bytes"),
			("{}", "no member"),
		] {
			Check.refuses("a line with \(why)") { _ = try ControlLine.parse(Data(text.utf8)) }
		}
		Check.that((try? ControlLine.parse(Data(#"{"attached":{"session":"s1","resume":true}}"#.utf8))) != nil, "attached reads")
	}

	/// The refused line (#816): a reason from a fixed list, a reason of the same form this build does not know read as a
	/// plain refusal, and nothing else.
	static func refusedLine() {
		Check.section("The refused line")
		Check.that(Refusal.Reason.allCases.map(\.rawValue) == ["update", "suspended", "presence", "clock", "resume"], "the reasons are exactly the five listed")
		for reason in Refusal.Reason.allCases {
			let written = ControlLine.refused(Refusal(reason)).line
			Check.that(written == Data(#"{"refused":{"reason":"\#(reason.rawValue)"}}"#.utf8), "refused \(reason.rawValue) is written as remotekit.md says")
			guard case let .refused(read)? = try? ControlLine.parse(written) else {
				Check.that(false, "refused \(reason.rawValue) reads")
				continue
			}
			Check.that(read.reason == reason && read == Refusal(reason), "refused \(reason.rawValue) reads back as itself")
		}
		let unknown = Data(#"{"refused":{"reason":"moonphase"}}"#.utf8)
		if case let .refused(read)? = try? ControlLine.parse(unknown) {
			Check.that(read.reason == nil, "a reason this build does not know is a plain refusal")
			Check.that(ControlLine.refused(read).line == unknown, "and is written back as it came")
		} else {
			Check.that(false, "a reason this build does not know is read, not refused")
		}
		for (text, why) in [
			(#"{"refused":{}}"#, "no reason"),
			(#"{"refused":{"reason":"update","text":"Update pi²"}}"#, "a field beside the reason"),
			(#"{"refused":{"reason":"update","reason":"clock"}}"#, "the reason twice"),
			(#"{"refused":{"reason":""}}"#, "an empty reason"),
			(#"{"refused":{"reason":"Update"}}"#, "a reason with a capital"),
			(#"{"refused":{"reason":"update the app"}}"#, "a reason in words"),
			(#"{"refused":{"reason":"abcdefghijklmnopqrstuvwxyzabcdefg"}}"#, "a reason of 33 letters"),
			(#"{"refused":{"reason":1}}"#, "a reason that is a number"),
			(#"{"refused":{"reason":null}}"#, "a reason that is null"),
			(#"{"refused":"update"}"#, "a reason that is not in an object"),
			(#"{"refused":{"reason":"update"},"x":1}"#, "a second member"),
			(#"{"refused":{"reason":"уpdate"}}"#, "a reason with a Cyrillic letter"),
		] {
			Check.refuses("a refused line with \(why)") { _ = try ControlLine.parse(Data(text.utf8)) }
		}
		// An escape that reads as a letter is that letter once read: it is taken, and written back without the escape.
		if case let .refused(read)? = try? ControlLine.parse(Data(#"{"refused":{"reason":"upd\u0061te"}}"#.utf8)) {
			Check.that(read.reason == .update, "an escaped letter in a reason is the letter")
		} else {
			Check.that(false, "an escaped letter in a reason is read")
		}
		let longest = String(repeating: "z", count: 32)
		Check.that((try? ControlLine.parse(Data(#"{"refused":{"reason":"\#(longest)"}}"#.utf8))) != nil, "a reason of 32 letters is read")
	}

	/// The pairRefused line (#881): a word from a fixed list, a word of the same form this build does not know read as no
	/// word, and nothing else.
	static func pairRefusedLine() {
		Check.section("The pairRefused line")
		Check.that(PairRefusal.Why.allCases.map(\.rawValue) == ["unsaved", "cancelled"], "the words are exactly the two listed")
		for why in PairRefusal.Why.allCases {
			let written = ControlLine.pairRefused(PairRefusal(why)).line
			Check.that(written == Data(#"{"pairRefused":{"why":"\#(why.rawValue)"}}"#.utf8), "pairRefused \(why.rawValue) is written as remotekit.md says")
			guard case let .pairRefused(read)? = try? ControlLine.parse(written, from: .mac) else {
				Check.that(false, "pairRefused \(why.rawValue) reads")
				continue
			}
			Check.that(read.why == why && read == PairRefusal(why), "pairRefused \(why.rawValue) reads back as itself")
			Check.refuses("pairRefused \(why.rawValue) from a phone") { _ = try ControlLine.parse(written, from: .phone) }
		}
		let unknown = Data(#"{"pairRefused":{"why":"moonphase"}}"#.utf8)
		if case let .pairRefused(read)? = try? ControlLine.parse(unknown) {
			Check.that(read.why == nil, "a word this build does not know is no word")
			Check.that(ControlLine.pairRefused(read).line == unknown, "and is written back as it came")
		} else {
			Check.that(false, "a word this build does not know is read, not refused")
		}
		for (text, why) in [
			(#"{"pairRefused":{}}"#, "no word"),
			(#"{"pairRefused":{"why":"unsaved","text":"The Mac could not save the pairing."}}"#, "a field beside the word"),
			(#"{"pairRefused":{"why":"unsaved","why":"cancelled"}}"#, "the word twice"),
			(#"{"pairRefused":{"why":""}}"#, "an empty word"),
			(#"{"pairRefused":{"why":"Unsaved"}}"#, "a word with a capital"),
			(#"{"pairRefused":{"why":"not-saved"}}"#, "a word with a hyphen"),
			(#"{"pairRefused":{"why":"The Mac could not save the pairing. Start again."}}"#, "the engine's words"),
			(#"{"pairRefused":{"why":"abcdefghijklmnopqrstuvwxyzabcdefg"}}"#, "a word of 33 letters"),
			(#"{"pairRefused":{"why":1}}"#, "a word that is a number"),
			(#"{"pairRefused":{"why":null}}"#, "a word that is null"),
			(#"{"pairRefused":"unsaved"}"#, "a word that is not in an object"),
			(#"{"pairRefused":{"why":"unsaved"},"x":1}"#, "a second member"),
			(#"{"pairRefused":{"reason":"unsaved"}}"#, "the refused line's member in place of why"),
			(#"{"pairRefused":{"why":"уnsaved"}}"#, "a word with a Cyrillic letter"),
		] {
			Check.refuses("a pairRefused line with \(why)") { _ = try ControlLine.parse(Data(text.utf8)) }
		}
	}

	/// The home key in `paired` and in the `homeKey` line (#845): exactly 32 bytes of base64url, never missing, and
	/// nothing beside it.
	static func homeKeyLines() {
		Check.section("The home key in paired and in homeKey")
		guard let key = HomeKey(rawRepresentation: Data(0..<32)) else { return Check.that(false, "the home key's test key") }
		let keyText = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
		let written = ControlLine.homeKey(key).line
		Check.that(written == Data(#"{"homeKey":{"key":"\#(keyText)"}}"#.utf8), "homeKey is written as remotekit.md says")
		if case let .homeKey(read)? = try? ControlLine.parse(written) {
			Check.that(read == key, "homeKey reads back as its key")
		} else {
			Check.that(false, "homeKey reads")
		}
		let short = Base64URL.encode(Data(0..<31))
		let long = Base64URL.encode(Data(0..<33))
		for (text, why) in [
			(#"{"homeKey":{}}"#, "no key"),
			(#"{"homeKey":{"key":"\#(short)"}}"#, "a key of 31 bytes"),
			(#"{"homeKey":{"key":"\#(long)"}}"#, "a key of 33 bytes"),
			(#"{"homeKey":{"key":""}}"#, "an empty key"),
			(#"{"homeKey":{"key":"\#(keyText)="}}"#, "a key with padding"),
			(#"{"homeKey":{"key":"\#(Data(0..<32).base64EncodedString())"}}"#, "a key in base64's other alphabet"),
			(#"{"homeKey":{"key":null}}"#, "a key that is null"),
			(#"{"homeKey":{"key":[0,1,2]}}"#, "a key that is not text"),
			(#"{"homeKey":{"key":"\#(keyText)","pairing":"AQEBAQEBAQEBAQEBAQEBAQ"}}"#, "a field beside the key"),
			(#"{"homeKey":{"key":"\#(keyText)","key":"\#(keyText)"}}"#, "the key twice"),
			(#"{"homeKey":"\#(keyText)"}"#, "a key that is not in an object"),
			(#"{"homeKey":{"key":"\#(keyText)"},"x":1}"#, "a second member"),
		] {
			Check.refuses("a homeKey line with \(why)") { _ = try ControlLine.parse(Data(text.utf8)) }
		}

		// In paired, the key is a field like the others: required, and exactly 32 bytes.
		guard let device = DeviceID("dev_" + Base64URL.encode(Data(repeating: 3, count: 16))), let pairing = PairingID("AQEBAQEBAQEBAQEBAQEBAQ"),
			let paired = try? Paired(device: device, pairing: pairing, name: "Mac", addresses: ["10.0.0.1:1"], homeKey: key)
		else { return Check.that(false, "a paired to read") }
		let pairedText = String(decoding: ControlLine.paired(paired).line, as: UTF8.self)
		Check.that(pairedText == #"{"paired":{"device":"\#(device.text)","pairing":"\#(pairing.text)","name":"Mac","addresses":["10.0.0.1:1"],"homeKey":"\#(keyText)"}}"#,
			"paired is written with its home key, as remotekit.md says")
		if case let .paired(read)? = try? ControlLine.parse(Data(pairedText.utf8)) {
			Check.that(read == paired && read.homeKey == key, "paired reads back with its home key")
		} else {
			Check.that(false, "paired reads")
		}
		let withoutKey = pairedText.replacingOccurrences(of: #","homeKey":"\#(keyText)""#, with: "")
		Check.that(withoutKey != pairedText, "the check can take the home key out of paired")
		Check.refuses("a paired without its home key") { _ = try ControlLine.parse(Data(withoutKey.utf8)) }
		for (replacement, why) in [(#""\#(short)""#, "of 31 bytes"), (#""\#(long)""#, "of 33 bytes"), ("null", "that is null"), (#""""#, "that is empty")] {
			let changed = pairedText.replacingOccurrences(of: #""\#(keyText)""#, with: replacement)
			Check.refuses("a paired with a home key \(why)") { _ = try ControlLine.parse(Data(changed.utf8)) }
		}
		let twice = pairedText.replacingOccurrences(of: #""}}"#, with: #"","homeKey":"\#(keyText)"}}"#)
		Check.refuses("a paired with its home key twice") { _ = try ControlLine.parse(Data(twice.utf8)) }
		Check.that(!String(describing: paired).contains(keyText) && !String(reflecting: paired).contains(keyText), "a paired's description shows no home key")
	}

	/// Every channel line has one writer (#845): read as from the other end, it is refused.
	static func directions() {
		Check.section("Which end sends each line")
		do {
			let identity = P256.Signing.PrivateKey()
			let deviceKey = P256.Signing.PrivateKey()
			let presenceKey = P256.Signing.PrivateKey()
			let pairing = PairingID.random()
			let device = DeviceID.random()
			let binding = Bytes.random(32)
			let description = DeviceDescription(
				name: "Phone", model: "iPhone 17", system: "iOS 27.1", build: "1.0", deviceKey: deviceKey.publicKey, presenceKey: presenceKey.publicKey,
				channelKey: Curve25519.KeyAgreement.PrivateKey().publicKey, recordKey: P256.KeyAgreement.PrivateKey().publicKey)
			let lines: [(ControlLine, ControlLine.Side, String)] = [
				(.mac(try MacProof.make(challenge: Bytes.random(32), pairing: pairing, binding: binding, identity: identity)), .mac, "the Mac's proof"),
				(.paired(try Paired(device: device, pairing: pairing, name: "Mac", addresses: [], homeKey: HomeKey.random())), .mac, "paired"),
				(.attached(Attached(session: SessionID("s1")!, resume: false)), .mac, "attached"),
				(.revoked(try Revocation.make(pairing: pairing, device: device, identity: identity)), .mac, "revoked"),
				(.refused(Refusal(.update)), .mac, "refused"),
				(.pairRefused(PairRefusal(.unsaved)), .mac, "pairRefused"),
				(.homeKey(HomeKey.random()), .mac, "homeKey"),
				(.pair(try PairClaim.make(device: description, attestation: nil, keyId: nil, pairing: pairing, binding: binding, deviceKey: deviceKey)), .phone, "pair"),
				(.attach(try AttachClaim.make(
					pairing: pairing, device: device, session: nil, received: nil, binding: binding, challenge: Bytes.random(32), build: "1.0",
					deviceKey: deviceKey, presenceKey: presenceKey)), .phone, "attach"),
				(.sessionEnd, .phone, "sessionEnd"),
			]
			for (line, side, name) in lines {
				let other: ControlLine.Side = side == .mac ? .phone : .mac
				Check.that(line.sender == side, "\(name) is sent by the \(side == .mac ? "Mac" : "phone")")
				Check.that((try? ControlLine.parse(line.line, from: side))?.line == line.line, "\(name) is read from the \(side == .mac ? "Mac" : "phone")")
				Check.refuses("\(name) read as from the \(other == .mac ? "Mac" : "phone")") { _ = try ControlLine.parse(line.line, from: other) }
			}
			Check.refuses("a line read from the Mac that is no line at all") { _ = try ControlLine.parse(Data(#"{"id":1,"result":{}}"#.utf8), from: .mac) }
		} catch {
			Check.that(false, "directions: \(error)")
		}
	}

	/// The home path's Bonjour tag (#815) and its secret key (#845): the key's form, the test value of remotekit.md, the
	/// UTC day, the three days the phone takes, and another pairing's or key's tag.
	static func homeTag() {
		Check.section("The home tag")
		guard let key = HomeKey(rawRepresentation: Data(0..<32)),
			let pairing = PairingID("AQEBAQEBAQEBAQEBAQEBAQ"), let other = PairingID(Base64URL.encode(Data(repeating: 2, count: 16)))
		else { return Check.that(false, "the home tag's test keys") }

		// The key: 32 random bytes the Mac makes, kept and read back as they are, and no other length.
		let made = HomeKey.random()
		Check.that(made.rawRepresentation.count == HomeKey.length && HomeKey.length == 32, "a home key the Mac makes is 32 bytes")
		Check.that(made != HomeKey.random(), "each home key made is another")
		Check.that(HomeKey(rawRepresentation: made.rawRepresentation) == made, "a home key kept reads back as itself")
		Check.that(HomeKey(rawRepresentation: Data(repeating: 1, count: 31)) == nil && HomeKey(rawRepresentation: Data(repeating: 1, count: 33)) == nil
			&& HomeKey(rawRepresentation: Data()) == nil, "a home key of 31, 33 or no bytes is refused")
		var dumped = ""
		dump(made, to: &dumped)
		let forms = [made.rawRepresentation.hex, made.rawRepresentation.base64EncodedString(), Base64URL.encode(made.rawRepresentation)]
		Check.that(!([dumped, String(describing: made), String(reflecting: made)].contains { text in forms.contains { text.contains($0) } }) && !dumped.contains(" bytes"),
			"a home key's description and dump show none of its bytes")
		// #820's bytes, the Mac's channel key 32 bytes of 7, as the key give #820's tag: the label, the pairing and the day
		// are as they were, and only where the key comes from changed.
		if let old = HomeKey(rawRepresentation: Data(repeating: 7, count: 32)), let first = PairingID("AQEBAQEBAQEBAQEBAQEBAQ") {
			Check.that(HomeTag.tag(key: old, pairing: first, date: Date(timeIntervalSince1970: 1_795_000_000)) == "c6b71440d4d049db",
				"with #820's bytes as its key, the tag is #820's: only the key changed")
		}

		// 2026-11-18T11:06:40Z.
		let date = Date(timeIntervalSince1970: 1_795_000_000)
		let tag = HomeTag.tag(key: key, pairing: pairing, date: date)
		Check.that(tag == "3871f8b1b7ba63ee", "the tag is remotekit.md's test value, worked out apart in Node")
		Check.that(tag.utf8.count == HomeTag.length && tag.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) },
			"a tag is 16 lower-case hexadecimal digits")
		let startOfDay = Date(timeIntervalSince1970: 1_794_960_000)
		let endOfDay = Date(timeIntervalSince1970: 1_795_046_399)
		Check.that(HomeTag.tag(key: key, pairing: pairing, date: startOfDay) == tag && HomeTag.tag(key: key, pairing: pairing, date: endOfDay) == tag,
			"one tag from 00:00:00 to 23:59:59 UTC")
		let before = HomeTag.tag(key: key, pairing: pairing, date: startOfDay.addingTimeInterval(-1))
		let after = HomeTag.tag(key: key, pairing: pairing, date: endOfDay.addingTimeInterval(1))
		Check.that(before == "2d62232fb4b8fae6", "the day before's tag is remotekit.md's")
		Check.that(after == "5729f00f52d9eea9", "the day after's tag is remotekit.md's")
		Check.that(HomeTag.tag(key: key, pairing: other, date: date) == "65d50404a02ece2b", "another pairing's tag is remotekit.md's")
		Check.that(HomeTag.tag(key: key, pairing: other, date: date) != tag, "another pairing gives another tag")
		let otherKey = HomeKey.random()
		Check.that(HomeTag.tag(key: otherKey, pairing: pairing, date: date) != tag, "another home key gives another tag")
		Check.that(!HomeTag.recognises(tag, key: otherKey, pairing: pairing, now: date), "and a phone holding another key, as a revoked one does once the key was made again, does not take the tag")
		Check.that(!tag.contains(pairing.text) && !tag.contains(Base64URL.encode(key.rawRepresentation)), "a tag holds neither the pairing's id nor the key")

		// The phone takes the day before, the day and the day after, by its own clock, and nothing further.
		Check.that(HomeTag.recognises(tag, key: key, pairing: pairing, now: date), "the phone recognises the day's tag")
		Check.that(HomeTag.recognises(before, key: key, pairing: pairing, now: date), "and the day before's, from a Mac whose clock is behind")
		Check.that(HomeTag.recognises(after, key: key, pairing: pairing, now: date), "and the day after's, from a Mac whose clock is ahead")
		let twoBefore = HomeTag.tag(key: key, pairing: pairing, date: date.addingTimeInterval(-2 * 86_400))
		let twoAfter = HomeTag.tag(key: key, pairing: pairing, date: date.addingTimeInterval(2 * 86_400))
		Check.that(!HomeTag.recognises(twoBefore, key: key, pairing: pairing, now: date) && !HomeTag.recognises(twoAfter, key: key, pairing: pairing, now: date),
			"but not two days before or after")
		Check.that(!HomeTag.recognises(tag, key: key, pairing: other, now: date), "nor another pairing's tag")
		Check.that(!HomeTag.recognises(tag.uppercased(), key: key, pairing: pairing, now: date), "nor the tag in capitals")
		Check.that(!HomeTag.recognises(String(tag.dropLast()), key: key, pairing: pairing, now: date) && !HomeTag.recognises(tag + "0", key: key, pairing: pairing, now: date)
			&& !HomeTag.recognises("", key: key, pairing: pairing, now: date), "nor one a digit short or long, nor nothing")
		// Compared in constant time: a tag that differs in its first digit and one that differs in its last are refused
		// alike; the comparison is Bytes.constantTimeEqual, which `bytes()` checks.
		var first = Array(tag.utf8)
		first[0] = first[0] == 0x30 ? 0x31 : 0x30
		var last = Array(tag.utf8)
		last[15] = last[15] == 0x30 ? 0x31 : 0x30
		Check.that(!HomeTag.recognises(String(decoding: first, as: UTF8.self), key: key, pairing: pairing, now: date)
			&& !HomeTag.recognises(String(decoding: last, as: UTF8.self), key: key, pairing: pairing, now: date), "nor one a digit off, first or last")

		// The day is the UTC day, written as remotekit.md says, at the edges of days, months, leap years and the range.
		for (seconds, day) in [
			(0.0, "1970-01-01"), (-1, "1969-12-31"), (951_782_400, "2000-02-29"), (951_868_799, "2000-02-29"), (4_107_542_400, "2100-03-01"),
			(1_795_046_399, "2026-11-18"), (1_795_046_400, "2026-11-19"), (253_402_300_799, "9999-12-31"), (-62_167_219_200, "0000-01-01"),
			(1e15, "9999-12-31"), (-1e15, "0000-01-01"), (.infinity, "9999-12-31"), (-.infinity, "0000-01-01"),
		] {
			let written = HomeTag.day(Date(timeIntervalSince1970: seconds))
			Check.that(written == day, "\(seconds) seconds is the UTC day \(day)")
		}
		Check.that(HomeTag.day(Date(timeIntervalSince1970: .nan)) == "1970-01-01", "a date that is no number is taken as 1970-01-01")
	}
}
