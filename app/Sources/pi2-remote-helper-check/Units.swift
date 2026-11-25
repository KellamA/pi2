import CryptoKit
import Darwin
import Foundation
import RemoteKit
import pi2_remote

/// What can be checked of pi² Remote in this process, with no helper running: the pieces its decisions rest on, and
/// the release build's Keychain and Secure Enclave logic with stand-ins for both (never the real ones).
enum Units {
	static func run(sources: URL, helper: URL) {
		addresses()
		admission()
		scan()
		builds()
		engineWords()
		homeTag()
		dataFolder()
		keychainVault()
		keyFiles()
		Advertising.run()
		Unfinished.run()
		sessionLines()
		parentCode(helper: helper)
		nothingFromOutside(sources: sources)
		lineLimitsAsTheEngines(sources: sources)
		nothingOfMacOSInADevelopmentBuild(helper: helper)
	}

	static func addresses() {
		Check.section("the listener's address ranges (5.4, decision 32)")
		let local = ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.20", "169.254.3.4", "100.64.0.1", "100.127.255.254", "::1", "fe80::1", "fd12:3456::1", "fc00::1", "::ffff:192.168.1.2"]
		let public_ = ["8.8.8.8", "172.32.0.1", "172.15.255.255", "100.63.255.255", "100.128.0.1", "192.169.0.1", "2001:db8::1", "2606:4700::1111", "::ffff:8.8.8.8", "fec0::1"]
		for text in local { Check.expect(IPAddress(text)?.isLocalOrPrivate == true, "\(text) is taken with Direct from any address off") }
		for text in public_ { Check.expect(IPAddress(text)?.isLocalOrPrivate == false, "\(text) is refused with Direct from any address off") }
		Check.expect(IPAddress("::ffff:10.0.0.1") == IPAddress("10.0.0.1"), "an IPv4 address mapped into IPv6 is read as itself")
		Check.expect(["127.0.0.1", "192.168.1.2", "10.0.0.3", "169.254.1.1", "fd00::1", "fe80::2"].allSatisfy { IPAddress($0)?.path == "home" }, "an attach from the Mac's own network is told to the engine as the home path")
		Check.expect(["100.64.0.1", "8.8.8.8", "2001:db8::1"].allSatisfy { IPAddress($0)?.path == "direct" }, "and one from a private network's shared range, or any other address, as direct")
		Check.expect(IPAddress("fe80::1")?.withPort(5) == "[fe80::1]:5" && IPAddress("10.0.0.1")?.withPort(5) == "10.0.0.1:5", "addresses are written as the payload writes them")
		Check.expect(MacAddresses.current(port: 9).allSatisfy { PairingPayload.isHostAndPort($0) && !$0.hasPrefix("[fe80") && !$0.hasPrefix("127.") }, "the Mac's addresses are ones the payload takes, without link-local IPv6 or loopback")
	}

	static func admission() {
		Check.section("the listener's limits (5.4, 3.4, and #675's security read B, D1)")
		let gate = Admission()
		let a = IPAddress("192.168.1.2")!, b = IPAddress("192.168.1.3")!
		var taken = (0 ..< 10).filter { _ in gate.admit(a) == .taken }.count
		Check.expect(taken == Admission.maxPendingPerSource && gate.admit(a) == .sourceFull, "at most \(Admission.maxPendingPerSource) connections wait to authenticate from one address", "\(taken)")
		taken = (0 ..< 10).filter { _ in gate.admit(b) == .taken }.count
		Check.expect(gate.pendingCount == Admission.maxPending && gate.admit(IPAddress("192.168.1.9")!) == .allFull, "at most \(Admission.maxPending) wait in all", "\(gate.pendingCount)")
		gate.release(key: gate.sourceKey(a))
		Check.expect(gate.admit(a) == .taken, "a connection that authenticated or closed makes room")
		// The Mac's own prefixes, given: a global /64 of its LAN.
		let six = Admission(localPrefixes: [(IPAddress("2001:db8:aa:1::5")!, 64)])
		let v6 = (1 ... 6).map { IPAddress("2001:db8:1:2::\($0)")! }
		Check.expect(v6.map { six.admit($0) } == [.taken, .taken, .taken, .taken, .sourceFull, .sourceFull], "IPv6 addresses in one /64 away from the Mac's link are one source")
		Check.expect(six.admit(IPAddress("2001:db8:1:3::1")!) == .taken, "and another /64 is another")
		let lan = Admission(localPrefixes: [(IPAddress("2001:db8:aa:1::5")!, 64)])
		for (what, prefix) in [("the Mac's own on-link prefix", "2001:db8:aa:1::"), ("link-local", "fe80::"), ("unique-local", "fd12:3456:789a:1::")] {
			let hosts = (1 ... 6).map { IPAddress("\(prefix)\($0)")! }
			Check.expect(hosts.map { lan.admit($0) }.allSatisfy { $0 == .taken || $0 == .allFull }, "IPv6 hosts on the Mac's own link (\(what)) are each a source of their own (#675's security read B, D1-a)")
			for host in hosts { lan.release(key: lan.sourceKey(host)) }
		}
		// The Mac's prefixes change while a connection waits (it left the network): its slot is still released (D1-a2).
		let moving = Admission(localPrefixes: [(IPAddress("2001:db8:aa:1::5")!, 64)])
		let phone = IPAddress("2001:db8:aa:1::42")!
		let held = moving.sourceKey(phone)
		Check.expect(moving.admit(key: held) == .taken && moving.pendingCount == 1, "a phone on the Mac's own prefix waits under its own address")
		moving.setPrefixes([])
		Check.expect(moving.sourceKey(phone) != held, "the Mac leaves that network: the same address would now be counted by its /64")
		moving.release(key: held)
		Check.expect(moving.pendingCount == 0, "and the waiting slot is released by the key it was admitted under, so none leaks")
		Check.expect(IPAddress("fe80::1")!.limitKey(localPrefixes: []) == IPAddress("fe80::1") && IPAddress("fd00::7")!.limitKey(localPrefixes: []) == IPAddress("fd00::7"), "link-local and unique-local are counted by address")
		Check.expect(IPAddress("2001:db8:aa:1::9")!.limitKey(localPrefixes: [(IPAddress("2001:db8:aa:1::5")!, 64)]) == IPAddress("2001:db8:aa:1::9"), "an address in a prefix the Mac has is counted by itself")
		Check.expect(contains(IPAddress("10.1.2.3")!, in: IPAddress("10.1.0.0")!, length: 16) && !contains(IPAddress("10.2.2.3")!, in: IPAddress("10.1.0.0")!, length: 16) && contains(IPAddress("2001:db8::1")!, in: IPAddress("2001:db8::")!, length: 33), "prefixes are matched bit by bit")
		let now = 1_000.0
		let firsts = (0 ..< 30).filter { _ in gate.firstMessage(from: a, now: now) }.count
		Check.expect(firsts == Admission.firstMessagesPerSourcePerMinute, "at most \(Admission.firstMessagesPerSourcePerMinute) first messages a minute from one address", "\(firsts)")
		Check.expect(gate.firstMessage(from: a, now: now + 61), "and more a minute later")
		for _ in 0 ..< Admission.unknownFirstMessagesPerMinute { gate.unknownFirstMessage(now: now + 61) }
		Check.expect(!gate.firstMessage(from: IPAddress("10.0.0.7")!, now: now + 62), "after \(Admission.unknownFirstMessagesPerMinute) first messages that found no device in a minute, none more from anyone")
		Check.expect(gate.firstMessage(from: IPAddress("10.0.0.7")!, now: now + 122), "and more a minute later")
		let shakes = (0 ..< 20).filter { _ in gate.handshake(for: "dev_x", now: now) }.count
		Check.expect(shakes == Admission.handshakesPerDevicePerMinute, "at most \(Admission.handshakesPerDevicePerMinute) handshakes a minute for one device", "\(shakes)")
		Check.expect(gate.handshake(for: "dev_y", now: now), "which does not hold back another device")
		let recorded = Bytes.random(48)
		gate.remember(recorded, now: now)
		Check.expect(gate.replayed(recorded, now: now + 5) && !gate.replayed(Bytes.random(48), now: now + 5), "a first message that found its device, seen again, is a replay; another is not")
		Check.expect(!gate.replayed(recorded, now: now + Admission.replayKept + 1), "and is forgotten after \(Int(Admission.replayKept / 60)) minutes")

		Check.section("who the listener takes and keeps (5.4, decision 32; #675's security read B, M4 and D2)")
		let local = IPAddress("192.168.1.5")!, public4 = IPAddress("8.8.8.8")!, shared = IPAddress("100.100.1.2")!, public6 = IPAddress("2606:4700::1")!
		Check.expect(admits(peer: public4, arrivedOn: nil, kind: .development, direct: false), "a development build's listener, on 127.0.0.1 alone, takes what reaches it")
		Check.expect(admits(peer: local, arrivedOn: nil, kind: .release, direct: false) && admits(peer: IPAddress("fd00::1")!, arrivedOn: nil, kind: .release, direct: false), "with Direct from any address off: a private or unique-local address is taken")
		Check.expect(!admits(peer: public4, arrivedOn: nil, kind: .release, direct: false) && !admits(peer: public6, arrivedOn: nil, kind: .release, direct: false), "a public address is not, and is ended when the switch goes off")
		Check.expect(admits(peer: public4, arrivedOn: nil, kind: .release, direct: true) && admits(peer: public6, arrivedOn: nil, kind: .release, direct: true), "with it on, a public address is taken")
		Check.expect(admits(peer: shared, arrivedOn: "utun4", kind: .release, direct: false), "100.64.0.0/10 by a tunnel interface (Tailscale) is taken with the switch off")
		Check.expect(!admits(peer: shared, arrivedOn: "en0", kind: .release, direct: false) && !admits(peer: shared, arrivedOn: nil, kind: .release, direct: false), "100.64.0.0/10 by any other interface (carrier-grade NAT) is not")
		Check.expect(IPAddress("2001:db8::1:2:3:4")?.limitKey(localPrefixes: []) == IPAddress("2001:db8::") && IPAddress("10.1.2.3")?.limitKey(localPrefixes: []) == IPAddress("10.1.2.3"), "an IPv6 source away from the Mac's link is counted by its /64, an IPv4 one by its address")
		Check.expect(MacAddresses.routeInterface(to: IPAddress("127.0.0.1")!)?.hasPrefix("lo") == true, "the interface of the route back to a peer is read without sending anything (D2)", MacAddresses.routeInterface(to: IPAddress("127.0.0.1")!) ?? "none")

		Check.section("what phones may make pi² Remote hold together (#675's security read B, M1b)")
		Check.expect(Remote.overBudget([("a", 100), ("b", 50)], budget: 200) == nil, "within the budget, nothing is let go")
		Check.expect(Remote.overBudget([("a", 100), ("b", 150), ("c", 10)], budget: 200) == "b", "over it, the connection leaving the most unread is")
		Check.expect(Remote.queueBudget == 256 * 1024 * 1024 && Remote.attachedPerDevice == 2, "the budget is 256 MB in all, and a device keeps two attached connections")
		unfinishedLines()
	}

	/// When a phone's unfinished line ends its connection (#908), on a clock of the check's own: 30 seconds with nothing
	/// more of it, or longer than 30 seconds and what it holds takes at 64 KiB a second.
	static func unfinishedLines() {
		Check.section("how long a phone's unfinished line is held (#908), on the check's own clock")
		let zero = SuspendingClock.now
		let stall = Duration.seconds(30), slowest = 64 * 1024
		func overdue(began: Double, grew: Double, held: Int, at now: Double) -> LineOverdue? {
			Remote.overdue(UnfinishedLine(began: zero + .seconds(began), grew: zero + .seconds(grew), held: held), at: zero + .seconds(now), stalledAfter: stall, slowest: slowest)
		}
		let piece = Frame.maxBodyLength, pictures = 67 * 1024 * 1024, most = 71 * 1024 * 1024
		Check.expect(overdue(began: 0, grew: 0, held: most, at: 29.9) == nil && overdue(began: 0, grew: 0, held: most, at: 30) == .stalled, "most of a line, then nothing: held 30 seconds, then its connection ends")
		Check.expect(overdue(began: 90, grew: 100, held: 10 * piece, at: 129) == nil && overdue(began: 90, grew: 100, held: 10 * piece, at: 130) == .stalled, "a line that stops partway is ended 30 seconds after its last piece, whenever it began")
		// Ten pictures on the slowest link allowed, a piece as soon as it has come: never overdue, though it takes 17 minutes.
		var slowAndHonest = true
		var held = 0, at = 0.0
		while held + piece < pictures {
			let grew = at
			held += piece
			at = Double(held) / Double(slowest)
			if overdue(began: 0, grew: grew, held: held, at: at - 0.001) != nil { slowAndHonest = false }
		}
		Check.expect(slowAndHonest && at > 16 * 60, "ten pictures (67 MiB) at 64 KiB a second, the slowest link allowed, are never cut", String(format: "%.0f s", at))
		Check.expect(overdue(began: 0, grew: 35.9, held: 72 * 1024 * 1024, at: 36) == nil, "nor 72 MiB at the relay's 2 MB a second")
		// At half that rate, it is cut, a little after twice as long as what it holds would take at the slowest.
		let half = Double(4 * 1024 * 1024) / Double(slowest / 2)
		Check.expect(overdue(began: 0, grew: half - 1, held: 4 * 1024 * 1024, at: half) == .tooSlow, "a line coming at half the slowest link's rate is ended as too slow, though a piece came a second before")
		// A piece every 29 seconds, or a byte: the stall's clock never runs out, the whole line's does.
		let allowed = 30 + Double(most) / Double(slowest)
		Check.expect(overdue(began: 0, grew: allowed - 29, held: most, at: allowed - 1) == nil && overdue(began: 0, grew: allowed - 1, held: most + 1, at: allowed + 1) == .tooSlow, "71 MiB sent at once and then a byte every 29 seconds is held \(Int(allowed / 60)) minutes at most, not for ever")
		Check.expect(overdue(began: 0, grew: 0, held: 1, at: 30) == .stalled && overdue(began: 0, grew: 59, held: 2, at: 60.5) == .tooSlow, "and a byte a minute is ended by either clock")
		// Timed on a suspending clock (#960's security read): a sleep of the Mac, when pi² Remote reads nothing, is no time
		// on it, so a line held through one is not cut on waking. That this takes SuspendingClock's instants is the check.
		let timedBy: (UnfinishedLine, SuspendingClock.Instant, Duration, Int) -> LineOverdue? = Remote.overdue
		Check.expect(timedBy(UnfinishedLine(began: zero, grew: zero, held: most), zero + .seconds(29), stall, slowest) == nil, "a line is timed on a clock that stops while the Mac sleeps: 29 seconds awake after its last piece, however long the Mac slept, it is held")
	}

	static func scan() {
		Check.section("a phone's line, read without building it (#675's security read B, M2)")
		func names(_ text: String) -> [String]? { JSONScan.object(Data(text.utf8)) }
		Check.expect(names(#"{"id":1,"method":"submit","params":{"text":"é \u00e9 \ud83d\ude00","a":[1,-2.5e3,true,false,null,{}]}}"#) == ["id", "method", "params"], "an engine request is taken, its member names read")
		Check.expect(names(#"{"sessionEnd":{}}"#) == ["sessionEnd"] && names(#"{"\u0073essionEnd":{}}"#) == ["sessionEnd"], "a name is read as it decodes")
		Check.expect(names("{}") == [], "an empty object is one")
		let refused: [(String, String)] = [
			("[1]", "an array"), (#"{"a":1} "#, "white space after"), (#" {"a":1}"#, "white space before"), (#"{"a":1}{"b":2}"#, "two objects"),
			(#"{"a":1},"session":"other""#, "a second session named after it"), (#"{"a":1,"a":2}"#, "a name twice"), (#"{"a":"\ud800"}"#, "a lone surrogate"),
			("{\"a\":\"\u{01}\"}", "a control character in a string"), (#"{"a":01}"#, "a number with a leading zero"), (#"{"a":1.}"#, "a number with no fraction digits"),
			(#"{"a":tru}"#, "a word cut short"), (#"{"a":"\x"}"#, "an escape there is no such"), (#"{"a" 1}"#, "no colon"), (#"{"a":1,}"#, "a comma before the end"),
			(String(repeating: #"{"a":"#, count: 33) + "1" + String(repeating: "}", count: 33), "33 levels"),
		]
		for (text, what) in refused { Check.expect(names(text) == nil, "refused: \(what)") }
		Check.expect(JSONScan.object(Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xC3, 0x28, 0x22, 0x7D])) == nil, "refused: invalid UTF-8")
		Check.expect(JSONScan.object(Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xED, 0xA0, 0x80, 0x22, 0x7D])) == nil, "refused: a surrogate written in UTF-8")
		Check.expect(names(String(repeating: #"{"a":"#, count: 32) + "1" + String(repeating: "}", count: 32)) != nil, "32 levels are taken")
		let many = "{" + (0 ..< 65).map { "\"k\($0)\":0" }.joined(separator: ",") + "}"
		Check.expect(names(many) == nil, "refused: more than \(JSONScan.maxMembers) members")
		let long = Data(("{\"x\":[" + String(repeating: "0,", count: 4 * 1024 * 1024) + "0]}").utf8)
		let began = Date()
		Check.expect(JSONScan.object(long) == ["x"], "an 8 MB line of small numbers is taken")
		Check.expect(Date().timeIntervalSince(began) < 30, "in a few seconds", String(format: "%.1f s", Date().timeIntervalSince(began)))
	}

	static func builds() {
		Check.section("the minimum phone build")
		Check.expect(Remote.buildAtLeast("2", "1") && Remote.buildAtLeast("1.0", "1") && Remote.buildAtLeast("1.10", "1.9"), "builds compare part by part, as the engine's buildAtLeast does")
		Check.expect(!Remote.buildAtLeast("0", "1") && !Remote.buildAtLeast("1.2", "1.10"), "an older build is below the minimum")
		Check.expect(Remote.isBuild("12.3") && !Remote.isBuild("1a") && !Remote.isBuild("") && !Remote.isBuild("1.2.3.4.5"), "a build is what the engine takes as one")
	}

	static func engineWords() {
		Check.section("the engine's fixed words for a phone, never its words (#818, #881)")
		let attach: [(String?, Refusal.Reason?)] = [
			("update", .update), ("suspended", .suspended), ("presence", .presence), ("clock", .clock), (nil, nil), ("resume", nil), ("Suspended", nil),
			("suspended ", nil), ("revoked", nil), ("", nil), ("This device is suspended. Resume it on the Mac's Devices page.", nil),
			("ѕuspended", nil),
		]
		for (word, expected) in attach {
			Check.expect(EngineWords.attachRefusal(word) == expected, "remote.attach's reason \(word.map { "\"\($0)\"" } ?? "none") is \(expected?.rawValue ?? "no reason for the phone")")
		}
		let pairing: [(String?, PairRefusal.Why?)] = [("unsaved", .unsaved), ("cancelled", .cancelled), (nil, nil), ("Unsaved", nil), ("not-kept", nil), ("canceled", nil), ("The Mac could not save the pairing. Start again.", nil)]
		for (word, expected) in pairing {
			Check.expect(EngineWords.pairRefusal(word) == expected, "pairRefused's reason \(word.map { "\"\($0)\"" } ?? "none") is \(expected?.rawValue ?? "no word for the phone")")
		}
	}

	static func homeTag() {
		Check.section("the Bonjour tag (5.4): RemoteKit's, under the home key (#845)")
		let key = HomeKey(rawRepresentation: Data(0 ..< 32))!
		let pairing = PairingID(Base64URL.encode(Data(repeating: 1, count: 16)))!
		let day = Date(timeIntervalSince1970: 1_795_000_000)
		let tag = HomeTag.tag(key: key, pairing: pairing, date: day)
		Check.expect(tag == "3871f8b1b7ba63ee", "the tag of 2026-11-18 is remotekit.md's test value", tag)
		Check.expect(HomeTag.recognises(tag, key: key, pairing: pairing, now: day), "and a phone holding the key recognises it")
		Check.expect(HomeTXT.record(tag: tag) == Data([3]) + Data("v=2".utf8) + Data([18]) + Data("t=\(tag)".utf8), "the TXT record is v=2 and t=<tag>")
		Check.expect(EngineLink.maxLineToEngine == 72 * 1024 * 1024 + 64 * 1024 && Remote.phoneLineLimit + 256 <= EngineLink.maxLineToEngine, "a phone's longest line, wrapped in its session, fits the engine's cap on pi² Remote's lines (#776's 29)")
	}

	static func dataFolder() {
		Check.section("the data folder")
		let usual = URL(fileURLWithPath: "/Users/someone/Library/Application Support/pi2", isDirectory: true)
		Check.expect((try? DataFolder.choose(kind: .release, named: "/tmp/elsewhere", bundle: nil, usual: usual)) == usual, "a release build takes the usual data folder, whatever the engine's environment names")
		Check.expect((try? DataFolder.choose(kind: .development, named: "/tmp/x", bundle: nil, usual: usual))?.path == "/tmp/x", "a development build takes the engine's PI2_HOME")
		for named in [usual.path, usual.path + "/", "/Users/someone/Library/Application Support/PI2"] {
			Check.expect((try? DataFolder.choose(kind: .development, named: named, bundle: nil, usual: usual)) == nil, "a development build refuses the usual data folder written as \(named)")
		}
		Check.expect((try? DataFolder.choose(kind: .development, named: nil, bundle: nil, usual: usual)) == nil, "a development build with no PI2_HOME and no bundle refuses")
		Check.expect(DataFolder.developmentSuffix(bundleID: "dev.pi2.app.test-675") == "test-675" && DataFolder.developmentSuffix(bundleID: "dev.pi2.app") == "dev", "a bundle id names a development build's folder as the app names it")
		Check.expect(try! DataFolder.usual().path.hasSuffix("/Library/Application Support/pi2"), "the usual data folder is the one the app uses")
	}

	/// Stand-ins for the Keychain and the Secure Enclave: the release build's logic is checked here, never the real ones.
	final class MemoryItems: SecretItems, @unchecked Sendable {
		var items: [String: Data] = [:]
		var reads = 0
		func read(_ account: String) throws -> Data? {
			reads += 1
			return items[account]
		}

		/// A Keychain that refuses every write, as one that is locked or full does.
		var refuseWrites = false
		func write(_ account: String, _ data: Data) throws {
			if refuseWrites { throw Refused("stand-in: the Keychain refused the write") }
			items[account] = data
		}

		/// A stand-in for another pi² Remote adding the same account between this one's read and its add.
		var raceWith: [String: Data] = [:]
		func add(_ account: String, _ data: Data) throws -> Bool {
			if let other = raceWith.removeValue(forKey: account) { items[account] = other }
			guard items[account] == nil else { return false }
			items[account] = data
			return true
		}
	}

	final class StandInEnclave: Enclave, @unchecked Sendable {
		let isAvailable: Bool
		var usable = true
		var made = 0
		init(available: Bool) { isAvailable = available }
		func makeSigningKey() throws -> (key: SigningKey, blob: Data) {
			made += 1
			let key = P256.Signing.PrivateKey()
			return (.software(key), Data("sealed-by-enclave".utf8) + key.rawRepresentation)
		}

		func signingKey(blob: Data) throws -> SigningKey {
			guard usable, blob.starts(with: Data("sealed-by-enclave".utf8)) else { throw Refused("stand-in: not usable") }
			return .software(try P256.Signing.PrivateKey(rawRepresentation: blob.dropFirst(17)))
		}

		func makeAgreementKey() throws -> (key: RecordKey, blob: Data) {
			made += 1
			let key = P256.KeyAgreement.PrivateKey()
			return (.software(key), Data("sealed-by-enclave".utf8) + key.rawRepresentation)
		}

		func agreementKey(blob: Data) throws -> RecordKey {
			guard usable, blob.starts(with: Data("sealed-by-enclave".utf8)) else { throw Refused("stand-in: not usable") }
			return .software(try P256.KeyAgreement.PrivateKey(rawRepresentation: blob.dropFirst(17)))
		}
	}

	static func keychainVault() {
		Check.section("a release build's keys: the Keychain and the Secure Enclave, with stand-ins (decision 30)")
		let items = MemoryItems()
		let enclave = StandInEnclave(available: true)
		let vault = KeychainVault(items: items, enclave: enclave)
		let first = try! vault.macKeys()
		func place(_ account: String) -> String? { items.items[account].flatMap { try? JSON.parse($0) }?["in"]?.stringValue }
		let relayA = try! vault.relayKey(for: "wss://relay.one/v1"), relayB = try! vault.relayKey(for: "wss://relay.two/v1")
		Check.expect(place("identity") == "enclave" && place("record") == "enclave" && place("relay wss://relay.one/v1") == "enclave", "with a Secure Enclave, the identity, record and relay keys are made in it")
		Check.expect(place("channel") == "software", "the channel key, Curve25519, is in the Keychain")
		Check.expect(enclave.made == 4, "four keys made in the Secure Enclave: identity, record, and a relay key for each of two relays", "\(enclave.made)")
		Check.expect(relayA.publicKey.derRepresentation != relayB.publicKey.derRepresentation, "each relay address has a relay key of its own (#678's security read)")
		// secureEnclave in the report is read from the keys' own kind, which only a real Secure Enclave key has; the
		// stand-in's keys are in software.
		Check.expect(first.report(relay: relayA)["relay"]?.stringValue == PublicKeys.text(relayA.publicKey), "remote.hello gives the relay key of the relay in use")
		let again = try! vault.macKeys()
		let relayAgain = try! vault.relayKey(for: "wss://relay.one/v1")
		Check.expect(again.identity.publicKey.derRepresentation == first.identity.publicKey.derRepresentation && again.channel.publicKey.rawRepresentation == first.channel.publicKey.rawRepresentation
			&& relayAgain.publicKey.derRepresentation == relayA.publicKey.derRepresentation && enclave.made == 4, "read again, the same keys, the same relay key for the same address, none made")
		enclave.usable = false
		Check.expect((try? vault.macKeys()) == nil && (try? vault.relayKey(for: "wss://relay.one/v1")) == nil && enclave.made == 4, "a Secure Enclave key that cannot be used is a refusal, never a new key made in silence")
		let plain = MemoryItems()
		let plainVault = KeychainVault(items: plain, enclave: StandInEnclave(available: false))
		let without = try! plainVault.macKeys()
		let withoutRelay = try! plainVault.relayKey(for: "wss://relay.one/v1")
		Check.expect(plain.items.values.allSatisfy { (try? JSON.parse($0))?["in"]?.stringValue == "software" }, "without a Secure Enclave, every key in the Keychain")
		Check.expect(without.report(relay: withoutRelay)["secureEnclave"]?.boolValue == false, "and secureEnclave: false in remote.hello")
		let racing = MemoryItems()
		let theirs = P256.Signing.PrivateKey()
		racing.raceWith["identity"] = Data("{\"in\":\"software\",\"key\":\"\(Base64URL.encode(theirs.rawRepresentation))\"}".utf8)
		let raced = try? KeychainVault(items: racing, enclave: StandInEnclave(available: false)).macKeys()
		Check.expect(raced?.identity.publicKey.derRepresentation == theirs.publicKey.derRepresentation, "two pi² Remotes making a key at once: the second reads back the first's, never writes over it (S2)")
		plain.items["identity"] = Data("{\"in\":\"elsewhere\",\"key\":\"AA\"}".utf8)
		Check.expect((try? KeychainVault(items: plain, enclave: StandInEnclave(available: false)).macKeys()) == nil, "an item pi² Remote did not write is refused")
		let device = ListedDevice(id: DeviceID.random(), deviceKey: P256.Signing.PrivateKey().publicKey, presenceKey: nil, channelKey: Curve25519.KeyAgreement.PrivateKey().publicKey, recordKey: P256.KeyAgreement.PrivateKey().publicKey, attestKeyId: "a2V5+aWQ/=")
		Check.expect((try? vault.kept()).map { $0.devices.isEmpty && $0.homeKey == nil } == true, "no list of devices and no home key before the first pairing")
		let home = HomeKey.random()
		try! vault.keep(KeptDevices(devices: [device], homeKey: home))
		let back = try? vault.kept()
		Check.expect(back?.devices.map(\.id) == [device.id] && back?.devices.first?.attestKeyId == "a2V5+aWQ/=", "the list of devices is kept in the Keychain and read back, with each one's App Attest key id")
		Check.expect(back?.homeKey == home && items.items.keys.filter { $0 == "home" || $0 == "devices" } == ["devices"], "the home key is kept with it, in the one item, in the Keychain and not the Secure Enclave (its bytes go to the phones): both are written or neither (S1)")
		try! vault.keep(KeptDevices(devices: [], homeKey: nil))
		Check.expect((try? vault.kept()).map { $0.devices.isEmpty && $0.homeKey == nil } == true, "an empty list keeps no home key")
		items.items["devices"] = Data(#"{"v":1,"devices":[],"home":"AAAA"}"#.utf8)
		Check.expect((try? vault.kept()) == nil, "a home key that is not 32 bytes is refused")
		Check.expect((try? KeyVaults.forBuild(.release, folder: URL(fileURLWithPath: "/nonexistent"))) == nil, "a development build cannot make a release build's vault: the Keychain is not compiled into it")
	}

	static func keyFiles() {
		Check.section("a development build's keys: files in its own data folder")
		let folder = temporaryFolder("pi2-remote-keys")
		defer { try? FileManager.default.removeItem(at: folder) }
		let vault = try! KeyVaults.forBuild(.development, folder: folder)
		let keys = try! vault.macKeys()
		let file = folder.appendingPathComponent("remote-keys.json")
		let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? -1
		Check.expect(mode == 0o600, "remote-keys.json is readable by the person alone", String(mode, radix: 8))
		let relayA = try! vault.relayKey(for: "ws://127.0.0.1:9/v1"), relayB = try! vault.relayKey(for: "ws://127.0.0.1:10/v1")
		Check.expect(keys.report(relay: relayA)["secureEnclave"]?.boolValue == false, "and says its keys are not in a Secure Enclave")
		Check.expect(relayA.publicKey.derRepresentation != relayB.publicKey.derRepresentation && (try? vault.relayKey(for: "ws://127.0.0.1:9/v1"))?.publicKey.derRepresentation == relayA.publicKey.derRepresentation, "a relay key for each relay address, the same one read again")
		Check.expect((try? vault.macKeys())?.identity.publicKey.derRepresentation == keys.identity.publicKey.derRepresentation, "the same keys read again")
		chmod(file.path, 0o644)
		Check.expect((try? vault.macKeys()) == nil, "a key file others can read is refused")
		chmod(file.path, 0o600)
		let link = folder.appendingPathComponent("remote-devices.json")
		symlink(file.path, link.path)
		Check.expect((try? vault.kept()) == nil, "a list of devices that is a link is refused")
		unlink(link.path)
		Check.expect((try? vault.kept())?.devices.isEmpty == true, "no list yet is an empty list")
		let home = HomeKey.random()
		try! vault.keep(KeptDevices(devices: [], homeKey: home))
		let homeMode = (try? FileManager.default.attributesOfItem(atPath: link.path)[.posixPermissions] as? Int) ?? -1
		Check.expect((try? vault.kept())?.homeKey == home && homeMode == 0o600, "the home key is kept in the list's own file, readable by the person alone")
	}

	static func sessionLines() {
		Check.section("the control connection's session lines")
		let line = Data(#"{"session":"s_abc-1","message":{"id":1,"result":{"a":"}"}}}"#.utf8)
		let parsed = EngineLink.sessionLine(line)
		Check.expect(parsed?.0 == "s_abc-1" && parsed?.1 == Data(#"{"id":1,"result":{"a":"}"}}"#.utf8), "a session's line is passed on as its bytes")
		for bad in [#"{"session":"s 1","message":{}}"#, #"{"session":"s1","message":[1]}"#, #"{"session":"s1","other":{}}"#, #"{"id":1,"result":{}}"#] {
			Check.expect(EngineLink.sessionLine(Data(bad.utf8)) == nil, "not a session's line: \(bad)")
		}
		Check.expect(Log.oneLine("refused\nFAKE 2026 line\r\u{2028}\u{202E}x\u{1B}[31m") == "refused FAKE 2026 line   x [31m", "a text from outside is logged as one line, its breaks and control characters replaced (S6)", Log.oneLine("refused\nFAKE 2026 line\r\u{2028}\u{202E}x\u{1B}[31m"))
		Check.expect(EngineLink.maxLineLength == Lines.defaultMaxLength, "the control connection takes lines of at most \(EngineLink.maxLineLength) bytes")
	}

	/// The release build's check of its parent's code, on this process's own connection: the check is the process, its
	/// own executable the code.
	static func parentCode(helper: URL) {
		Check.section("a release build's check of the engine's code (run on this process, not on an engine)")
		let (mine, theirs) = socketPair()
		defer {
			close(mine)
			close(theirs)
		}
		guard let token = Startup.peerToken(theirs) else { return Check.expect(false, "a socket pair has an audit token") }
		let own = AppBundle.ownExecutable()!
		Check.expect((try? Startup.codeMatches(token: token, executable: own).get()) != nil, "a process satisfies its own executable's requirement")
		Check.expect((try? Startup.codeMatches(token: token, executable: helper).get()) == nil, "and not another's (pi² Remote's own)")
		Check.expect((try? Startup.codeMatches(token: token, executable: URL(fileURLWithPath: "/usr/bin/true")).get()) == nil, "nor Apple's /usr/bin/true")
		Check.expect(AppBundle.containing(executable: URL(fileURLWithPath: "/A/pi².app/Contents/Helpers/pi² Remote.app/Contents/MacOS/pi² Remote"))?.node.path == "/A/pi².app/Contents/Resources/node", "pi² Remote finds the Node of the bundle it is in")
		Check.expect(AppBundle.containing(executable: URL(fileURLWithPath: "/A/.build/debug/pi2-remote-helper")) == nil, "and no bundle when it is in none")
	}

	/// Nothing in pi² Remote reads its own arguments or environment: what it is told comes from the engine alone (5.5).
	static func nothingFromOutside(sources: URL) {
		Check.section("no settings from outside (decision 24)")
		let files = (try? FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "swift" } ?? []
		Check.expect(files.count >= 10, "pi² Remote's sources are found", "\(files.count) in \(sources.path)")
		let forbidden = ["CommandLine", "ProcessInfo.processInfo.environment", "ProcessInfo.processInfo.arguments", "getenv(", "environ", "UserDefaults", "NSUserDefaults"]
		for file in files {
			let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
			let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }.joined(separator: "\n")
			for word in forbidden where code.range(of: "(?<![A-Za-z_])\\Q\(word)\\E(?![A-Za-z_])", options: .regularExpression) != nil {
				Check.expect(false, "\(file.lastPathComponent) reads nothing from outside", "it names \(word)")
			}
		}
		Check.expect(true, "no file of pi² Remote names CommandLine, its environment, getenv or user defaults")
	}

	/// A phone's longest line as pi² Remote takes it, and the longest line the engine takes from pi² Remote, are the
	/// engine's own (#904): `MAX_PHONE_LINE` and `MAX_HELPER_LINE` in engine/src/remote.ts, read from its source, so that
	/// one side raised without the other fails here. Equal, not merely fitting: an engine that takes less stops pi² Remote
	/// for a line it was right to pass on, and one that takes more takes lines no phone may send. And the other way
	/// (#919): the longest line the engine writes pi² Remote, `MAX_LINE_TO_HELPER`, is what pi² Remote takes from it
	/// (`EngineLink.maxLineLength`), and what a phone takes once attached (`Lines.defaultMaxLength`): one longer would
	/// stop pi² Remote, and every phone's session.
	static func lineLimitsAsTheEngines(sources: URL) {
		Check.section("a phone's longest line, here and in the engine (#904)")
		let file = sources.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("engine/src/remote.ts")
		let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
		/// `export const NAME = <sum of products of whole numbers and names already read>;`
		var values: [String: Int] = [:]
		func constant(_ name: String) -> Int? {
			guard let range = text.range(of: "export const \(name) = "), let end = text[range.upperBound...].firstIndex(of: ";") else { return nil }
			var sum = 0
			for term in text[range.upperBound ..< end].split(separator: "+") {
				var product = 1
				for factor in term.split(separator: "*").map({ $0.trimmingCharacters(in: .whitespaces) }) {
					guard let value = Int(factor) ?? values[factor] else { return nil }
					product *= value
				}
				sum += product
			}
			values[name] = sum
			return sum
		}
		let phone = constant("MAX_PHONE_LINE"), helper = constant("MAX_HELPER_LINE")
		Check.expect(phone != nil && helper != nil, "remote.ts's MAX_PHONE_LINE and MAX_HELPER_LINE are read from \(file.path)")
		Check.expect(phone == Remote.phoneLineLimit, "a phone's longest line is the engine's MAX_PHONE_LINE", "\(Remote.phoneLineLimit) here, \(phone.map(String.init) ?? "none") in remote.ts")
		Check.expect(helper == EngineLink.maxLineToEngine, "the longest line written to the engine is its MAX_HELPER_LINE", "\(EngineLink.maxLineToEngine) here, \(helper.map(String.init) ?? "none") in remote.ts")
		Check.expect(Remote.phoneLineLimit == 72 * 1024 * 1024, "and it is 72 MiB: ten pictures of 5 MiB in base64, and their message")
		let toHelper = constant("MAX_LINE_TO_HELPER")
		Check.expect(toHelper == EngineLink.maxLineLength, "the longest line the engine writes pi² Remote is the longest it takes from the engine, remote.ts's MAX_LINE_TO_HELPER", "\(EngineLink.maxLineLength) here, \(toHelper.map(String.init) ?? "none") in remote.ts")
		Check.expect(toHelper == Lines.defaultMaxLength, "and the longest a phone takes once attached", "\(Lines.defaultMaxLength) in RemoteKit, \(toHelper.map(String.init) ?? "none") in remote.ts")
	}

	/// A development build's executable names none of the calls that could ask macOS for anything (CONTRIBUTING.md,
	/// "Testing safely"): no Keychain item, no Secure Enclave key made or read, no Bonjour.
	static func nothingOfMacOSInADevelopmentBuild(helper: URL) {
		Check.section("a development build asks macOS for nothing")
		let output = Pipe()
		let nm = Process()
		nm.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
		nm.arguments = ["-u", helper.path]
		nm.standardOutput = output
		nm.standardError = FileHandle.nullDevice
		guard (try? nm.run()) != nil else { return Check.expect(false, "nm reads pi² Remote's executable") }
		let symbols = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
		nm.waitUntilExit()
		Check.expect(symbols.count > 50 && symbols.contains("_socket"), "nm lists what pi² Remote calls", "\(symbols.count) symbols")
		let asking = symbols.filter { symbol in
			symbol.hasPrefix("_SecItem") || symbol.hasPrefix("_DNSService") || symbol.hasPrefix("_SecAccessControlCreate") || symbol.hasPrefix("_SecKeyCreate")
				|| symbol.contains("NSNetService") || symbol.contains("NWListener") || symbol.contains("NWBrowser")
				|| (symbol.contains("SecureEnclave") && (symbol.hasSuffix("fC") || symbol.contains("isAvailable")))
		}
		Check.expect(asking.isEmpty, "a development build of pi² Remote calls no Keychain item, makes or reads no Secure Enclave key, and advertises nothing", asking.joined(separator: ", "))
	}
}
