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
		builds()
		homeTag()
		dataFolder()
		keychainVault()
		keyFiles()
		sessionLines()
		parentCode(helper: helper)
		nothingFromOutside(sources: sources)
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
		Check.section("the listener's limits (5.4, 3.4)")
		let gate = Admission()
		let a = IPAddress("192.168.1.2")!, b = IPAddress("192.168.1.3")!
		var taken = (0 ..< 10).filter { _ in gate.admit(a) }.count
		Check.expect(taken == Admission.maxPendingPerSource, "at most \(Admission.maxPendingPerSource) connections wait to authenticate from one address", "\(taken)")
		taken = (0 ..< 10).filter { _ in gate.admit(b) }.count
		Check.expect(gate.pendingCount == Admission.maxPending, "at most \(Admission.maxPending) wait in all", "\(gate.pendingCount)")
		gate.release(a)
		Check.expect(gate.admit(a), "a connection that authenticated or closed makes room")
		let now = 1_000.0
		let firsts = (0 ..< 30).filter { _ in gate.firstMessage(from: a, now: now) }.count
		Check.expect(firsts == Admission.firstMessagesPerSourcePerMinute, "at most \(Admission.firstMessagesPerSourcePerMinute) first messages a minute from one address", "\(firsts)")
		Check.expect(gate.firstMessage(from: a, now: now + 61), "and more a minute later")
		var all = 0
		for host in 0 ..< 100 { if gate.firstMessage(from: IPAddress("10.0.0.\(host)")!, now: now + 61) { all += 1 } }
		Check.expect(all + 1 <= Admission.firstMessagesPerMinute && all > 0, "at most \(Admission.firstMessagesPerMinute) first messages a minute in all", "\(all + 1)")
		let shakes = (0 ..< 20).filter { _ in gate.handshake(for: "dev_x", now: now) }.count
		Check.expect(shakes == Admission.handshakesPerDevicePerMinute, "at most \(Admission.handshakesPerDevicePerMinute) handshakes a minute for one device", "\(shakes)")
		Check.expect(gate.handshake(for: "dev_y", now: now), "which does not hold back another device")
	}

	static func builds() {
		Check.section("the minimum phone build")
		Check.expect(Remote.buildAtLeast("2", "1") && Remote.buildAtLeast("1.0", "1") && Remote.buildAtLeast("1.10", "1.9"), "builds compare part by part, as the engine's buildAtLeast does")
		Check.expect(!Remote.buildAtLeast("0", "1") && !Remote.buildAtLeast("1.2", "1.10"), "an older build is below the minimum")
		Check.expect(Remote.isBuild("12.3") && !Remote.isBuild("1a") && !Remote.isBuild("") && !Remote.isBuild("1.2.3.4.5"), "a build is what the engine takes as one")
	}

	static func homeTag() {
		Check.section("the Bonjour tag (5.4)")
		let key = try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(repeating: 7, count: 32))
		let pairing = PairingID(Base64URL.encode(Data(repeating: 1, count: 16)))!
		let day = Date(timeIntervalSince1970: 1_795_000_000)
		let tag = HomeTag.tag(channelKey: key, pairing: pairing, date: day)
		Check.expect(HomeTag.day(day) == "2026-11-18", "the tag's date is the UTC day", HomeTag.day(day))
		var material = Data("pi2-tag".utf8) + Data([0]) + Data(repeating: 7, count: 32) + Data([0]) + Data(pairing.text.utf8)
		let expected = HMAC<SHA256>.authenticationCode(for: Data("2026-11-18".utf8), using: SymmetricKey(data: SHA256.hash(data: material)))
		material = Data()
		Check.expect(tag == Data(expected).prefix(8).map { String(format: "%02x", $0) }.joined() && tag.count == 16, "the tag is 8 bytes of HMAC-SHA256 of the day, keyed from the channel key and the pairing", tag)
		Check.expect(tag != HomeTag.tag(channelKey: key, pairing: pairing, date: day.addingTimeInterval(86_400)), "and changes each day")
		Check.expect(!tag.contains(pairing.text) && !tag.contains(Base64URL.encode(key.rawRepresentation)), "and says neither the pairing nor the key")
		Check.expect(HomeTag.txtRecord(tag: tag) == Data([3]) + Data("v=2".utf8) + Data([18]) + Data("t=\(tag)".utf8), "the TXT record is v=2 and t=<tag>")
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

		func write(_ account: String, _ data: Data) throws { items[account] = data }

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
			guard usable, blob.starts(with: Data("sealed-by-enclave".utf8)) else { throw Refusal("stand-in: not usable") }
			return .software(try P256.Signing.PrivateKey(rawRepresentation: blob.dropFirst(17)))
		}

		func makeAgreementKey() throws -> (key: RecordKey, blob: Data) {
			made += 1
			let key = P256.KeyAgreement.PrivateKey()
			return (.software(key), Data("sealed-by-enclave".utf8) + key.rawRepresentation)
		}

		func agreementKey(blob: Data) throws -> RecordKey {
			guard usable, blob.starts(with: Data("sealed-by-enclave".utf8)) else { throw Refusal("stand-in: not usable") }
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
		try! vault.saveDevices([device])
		let back = try? vault.devices()
		Check.expect(back?.map(\.id) == [device.id] && back?.first?.attestKeyId == "a2V5+aWQ/=", "the list of devices is kept in the Keychain and read back, with each one's App Attest key id")
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
		Check.expect((try? vault.devices()) == nil, "a list of devices that is a link is refused")
		unlink(link.path)
		Check.expect((try? vault.devices())?.isEmpty == true, "no list yet is an empty list")
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
