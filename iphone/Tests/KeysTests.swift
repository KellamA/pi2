import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import pi2

// The phone's keys, App Attest and the Face ID session (docs/iphone.md 3.2, 3.3, 4.3, 4.5; #680). An unsigned
// simulator build is refused every Keychain call (errSecMissingEntitlement), so the keys are tested here over
// `MemoryKeychain`, which keeps the protection each item was written with; the Keychain itself, the Secure Enclave
// presence key's access control and App Attest are for a phone.

// MARK: Stand-ins

/// A Keychain in memory, which refuses an item under Face ID without a context as the Keychain does.
final class MemoryKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (Data, KeyProtection)] = [:]
    /// Items left by someone else (an earlier installation), which `names` lists and `deleteEverything` removes.
    private var foreign: Set<String> = []

    func write(_ data: Data, as item: KeyItem) throws {
        lock.withLock { items[item.rawValue] = (data, item.protection) }
    }

    func read(_ item: KeyItem, context: LAContext?) throws -> Data? {
        if item.protection == .whenPasscodeSetUnderFaceID, context == nil { throw KeysError.sessionNotOpen }
        return lock.withLock { items[item.rawValue]?.0 }
    }

    func delete(_ item: KeyItem) throws {
        lock.withLock { items[item.rawValue] = nil }
    }

    func names() throws -> [String] {
        lock.withLock { (Array(items.keys) + foreign).sorted() }
    }

    func deleteEverything() throws {
        lock.withLock {
            items = [:]
            foreign = []
        }
    }

    func leave(_ name: String) {
        lock.withLock { _ = foreign.insert(name) }
    }

    func protection(of item: KeyItem) -> KeyProtection? {
        lock.withLock { items[item.rawValue]?.1 }
    }
}

@MainActor
final class FakePass: FaceIDPass {
    let stateHash: Data?
    private(set) var invalidated = false
    init(stateHash: Data?) { self.stateHash = stateHash }
    var context: LAContext? { nil }
    func invalidate() { invalidated = true }
}

/// Face ID that answers as scripted, and counts how often it was asked.
@MainActor
final class FakeFaceID: FaceIDGate {
    var outcomes: [FaceIDOutcome] = []
    var stateHash: Data? = Data("faces-1".utf8)
    var available: Result<Data?, SessionFailure>?
    private(set) var checks = 0
    private(set) var passes: [FakePass] = []
    /// If set, a check waits until `release()`.
    var holds = false
    private var waiting: CheckedContinuation<Void, Never>?

    func availability() -> Result<Data?, SessionFailure> { available ?? .success(stateHash) }

    func check(reason: String) async -> FaceIDOutcome {
        checks += 1
        if holds { await withCheckedContinuation { waiting = $0 } }
        if !outcomes.isEmpty, case let next = outcomes.removeFirst(), !isPass(next) { return next }
        let pass = FakePass(stateHash: stateHash)
        passes.append(pass)
        return .passed(pass)
    }

    func release() {
        waiting?.resume()
        waiting = nil
    }

    private func isPass(_ outcome: FaceIDOutcome) -> Bool {
        if case .passed = outcome { true } else { false }
    }
}

/// A presence key that signs in software, and can behave as a phone where one Face ID signs only once.
final class FakePresenceKeys: PresenceKeyHolding, @unchecked Sendable {
    let key = P256.Signing.PrivateKey()
    var present = true
    var madeFor: Data? = Data("faces-1".utf8)
    var reuseHolds = true
    private(set) var replaced = 0
    private(set) var signatures = 0
    /// The pass each signature was made under, by its identity: a stand-in pass has no LAContext.
    var currentPass: (() -> AnyObject?)?
    private var used: Set<ObjectIdentifier> = []

    func hasPresenceKey() throws -> Bool { present }
    func presencePublicKey() throws -> Data? { present ? key.publicKey.derRepresentation : nil }
    func presenceFaceIDState() throws -> Data? { madeFor }

    func signPresence(_ data: Data, context: LAContext?) throws -> Data {
        if !reuseHolds, let pass = currentPass?() {
            let id = ObjectIdentifier(pass)
            if used.contains(id) { throw KeysError.needsFaceIDAgain }
            used.insert(id)
        }
        signatures += 1
        return try key.signature(for: data).rawRepresentation
    }

    func replacePresenceKey(faceIDState: Data?) throws -> Data {
        replaced += 1
        madeFor = faceIDState
        return key.publicKey.derRepresentation
    }

    func cacheKey(context: LAContext?) throws -> SymmetricKey? { SymmetricKey(size: .bits256) }
}

/// A clock the test moves by hand.
@MainActor
final class HandClock {
    var now = ContinuousClock.now
    func advance(_ by: Duration) { now = now.advanced(by: by) }
}

private func verifies(_ signature: Data, _ message: Data, _ der: Data) throws -> Bool {
    let key = try P256.Signing.PublicKey(derRepresentation: der)
    return key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message)
}

private func hex(_ text: String) -> Data {
    var data = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        data.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return data
}

// MARK: The keys

struct KeysTests {
    @Test func everyItemHasTheProtectionTheContractNames() {
        #expect(KeyItem.deviceKey.protection == .whenPasscodeSet)
        #expect(KeyItem.presenceKey.protection == .whenPasscodeSet)
        #expect(KeyItem.channelKey.protection == .whenPasscodeSet)
        #expect(KeyItem.cacheKey.protection == .whenPasscodeSetUnderFaceID)
        #expect(KeyItem.recordKey.protection == .afterFirstUnlock)
        #expect(KeyItem.macRecord.protection == .afterFirstUnlock)
        #expect(KeyItem.allCases.filter(\.shared) == [.recordKey, .macRecord])
    }

    @Test func theAccessControlsAreMade() throws {
        // Made, not used: using them needs a phone. A failure here would mean the flags cannot go together.
        _ = try KeyAccess.deviceKey()
        _ = try KeyAccess.underFaceID(privateKey: true)
        _ = try KeyAccess.underFaceID(privateKey: false)
    }

    @Test func theDeviceKeyIsWrittenAsRemoteKitReadsIt() throws {
        let keychain = MemoryKeychain()
        let keys = PhoneKeys(keychain: keychain, secureEnclave: false)
        let made = try keys.makeDeviceKey()
        #expect(made.publicKeyDER.count == 91)
        // RemoteKit takes only the one encoding CryptoKit writes: read and written again, the same bytes.
        #expect(try P256.Signing.PublicKey(derRepresentation: made.publicKeyDER).derRepresentation == made.publicKeyDER)
        let message = Data(#"{"v":2,"kind":"pair"}"#.utf8)
        let signature = try made.sign(message)
        #expect(signature.count == 64)
        #expect(try verifies(signature, message, made.publicKeyDER))
        // Read back from the Keychain, it is the same key.
        let again = try #require(try keys.deviceKey())
        #expect(again.publicKeyDER == made.publicKeyDER)
        #expect(try verifies(try again.sign(message), message, made.publicKeyDER))
        #expect(keychain.protection(of: .deviceKey) == .whenPasscodeSet)
    }

    @Test func theDeviceKeyInTheSimulatorsSecureEnclave() throws {
        // The simulator has a Secure Enclave of its own for keys without Face ID (SecureEnclave.isAvailable is true
        // there): the blob kept in the Keychain loads and signs. It proves the code path, not the phone's enclave.
        guard SecureEnclave.isAvailable else { return }
        let keys = PhoneKeys(keychain: MemoryKeychain(), secureEnclave: true)
        let made = try keys.makeDeviceKey()
        #expect(made.inSecureEnclave)
        #expect(made.publicKeyDER.count == 91)
        let again = try #require(try keys.deviceKey())
        let message = Data("attach".utf8)
        #expect(try verifies(try again.sign(message), message, made.publicKeyDER))
    }

    /// The vectors come from the relay's own `joinClientDataHash` (relay/src/join.ts) and node:crypto, for the P-256
    /// key whose private scalar is the bytes 1 to 32.
    @Test func theClientDataHashesMatchTheRelaysAndRemoteKits() throws {
        let keychain = MemoryKeychain()
        let scalar = Data((1...32).map { UInt8($0) })
        try keychain.write(try P256.Signing.PrivateKey(rawRepresentation: scalar).rawRepresentation, as: .deviceKey)
        let key = try #require(try PhoneKeys(keychain: keychain, secureEnclave: false).deviceKey())
        #expect(key.publicKeyDER == hex("3059301306072a8648ce3d020106082a8648ce3d03010703420004515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f4536be3a50f318fbf9a5475902a221502bef0d57e08c53b2cc0a56f17d9f9354"))
        let challenge = Data(repeating: 0xab, count: 32)
        let binding = Data(repeating: 0xcd, count: 32)
        #expect(try key.joinClientDataHash(relayChallenge: challenge) == hex("a2d6ae8f751c5dece978815182397f6fdeea1286ca046a1caca91609c4ee78a2"))
        #expect(try key.pairClientDataHash(macChallenge: challenge, binding: binding) == hex("47696fa1fbcc08f6451bcbb5200bcc540ac580157573fac13b7213a10c005b45"))
        #expect(throws: KeysError.badChallenge) { try key.joinClientDataHash(relayChallenge: Data(repeating: 1, count: 31)) }
        #expect(throws: KeysError.badChallenge) { try key.joinClientDataHash(relayChallenge: Data(repeating: 1, count: 33)) }
    }

    @Test func thePairingKeysAreMadeWithTheirPublicHalves() throws {
        let keychain = MemoryKeychain()
        let keys = PhoneKeys(keychain: keychain, secureEnclave: false)
        #expect(throws: KeysError.missing("device key")) { try keys.makePairingKeys(faceIDState: nil) }
        try keys.makeDeviceKey()
        let state = Data("faces".utf8)
        let made = try keys.makePairingKeys(faceIDState: state)
        #expect([made.device.count, made.presence.count, made.channel.count, made.record.count] as [Int] == [91, 91, 32, 91])
        #expect(made.device != made.presence)
        #expect(try P256.KeyAgreement.PublicKey(derRepresentation: made.record).derRepresentation == made.record)
        #expect(try keys.channelKey()?.publicKey.rawRepresentation == made.channel)
        #expect(try keys.recordKey()?.publicKey.derRepresentation == made.record)
        #expect(try keys.publicKeys() == made)
        #expect(try keys.presenceFaceIDState() == state)
        #expect(try keys.presenceKeyIsWaiting() == false)
        #expect(keychain.protection(of: .cacheKey) == .whenPasscodeSetUnderFaceID)
        #expect(keychain.protection(of: .recordKey) == .afterFirstUnlock)
        // The cache key is read only under a context.
        #expect(throws: KeysError.sessionNotOpen) { try keys.cacheKey(context: nil) }
        #expect(try keys.cacheKey(context: LAContext()) != nil)
        // The presence key signs as the device key does, checked against the half the claim carries.
        let message = Data("attach".utf8)
        #expect(try verifies(try keys.signPresence(message, context: nil), message, made.presence))
    }

    @Test func aNewPresenceKeyWaitsForTheMac() throws {
        let keys = PhoneKeys(keychain: MemoryKeychain(), secureEnclave: false)
        try keys.makeDeviceKey()
        let made = try keys.makePairingKeys(faceIDState: Data("old".utf8))
        let cacheBefore = try keys.cacheKey(context: LAContext())
        let replaced = try keys.replacePresenceKey(faceIDState: Data("new".utf8))
        #expect(replaced != made.presence)
        #expect(try keys.presencePublicKey() == replaced)
        #expect(try keys.presenceFaceIDState() == Data("new".utf8))
        #expect(try keys.presenceKeyIsWaiting())
        #expect(try keys.cacheKey(context: LAContext()) != cacheBefore)
        try keys.presenceKeyAccepted()
        #expect(try keys.presenceKeyIsWaiting() == false)
    }

    @Test func theMacsRecordIsKeptAsGiven() throws {
        let keychain = MemoryKeychain()
        let keys = PhoneKeys(keychain: keychain, secureEnclave: false)
        #expect(try keys.macRecord() == nil)
        let record = Data(#"{"pairing":"p","name":"Mac"}"#.utf8)
        try keys.keepMacRecord(record)
        #expect(try keys.macRecord() == record)
        #expect(keychain.protection(of: .macRecord) == .afterFirstUnlock)
    }

    @Test func theFirstLaunchDeletesWhatAnEarlierInstallationLeft() throws {
        let keychain = MemoryKeychain()
        let keys = PhoneKeys(keychain: keychain, secureEnclave: false)
        try keys.makeDeviceKey()
        keychain.leave("left-by-an-earlier-install")
        let suite = "pi2.tests.keys.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Before the phone's first unlock the preferences cannot be read: nothing is deleted.
        #expect(try keys.removeLeftoversAtFirstLaunch(defaults: defaults, protectedDataAvailable: false) == false)
        #expect(try keys.itemNames().count == 2)

        #expect(try keys.removeLeftoversAtFirstLaunch(defaults: defaults, protectedDataAvailable: true))
        #expect(try keys.itemNames().isEmpty)

        // Once: the keys made after it stay.
        try keys.makeDeviceKey()
        #expect(try keys.removeLeftoversAtFirstLaunch(defaults: defaults, protectedDataAvailable: true) == false)
        #expect(try keys.itemNames() == ["device-key"])
    }

    @Test @MainActor func wipingRemovesEveryKeyAndEndsTheSession() async throws {
        let keychain = MemoryKeychain()
        let keys = PhoneKeys(keychain: keychain, secureEnclave: false)
        let faceID = FakeFaceID()
        let keyring = PhoneKeyring(keys: keys, faceID: faceID, attester: AppAttest.live())
        try keys.makeDeviceKey()
        _ = try keyring.makePairingKeys()
        try keys.keepMacRecord(Data("mac".utf8))
        keychain.leave("something else of the app's")
        #expect(try keys.itemNames().count == 9)

        var ended: [PresenceSession.EndReason] = []
        keyring.session.onEnd = { ended.append($0) }
        await keyring.session.open()
        #expect(keyring.session.state == .open)

        try keyring.wipe()
        #expect(try keys.itemNames().isEmpty)
        #expect(keyring.session.state == .locked)
        #expect(ended == [.revoked])
        #expect(faceID.passes.allSatisfy { $0.invalidated })
        await #expect(throws: KeysError.sessionNotOpen) { try await keyring.session.signPresence(Data("x".utf8)) }
    }

    @Test @MainActor func pairingKeysNeedFaceID() throws {
        let faceID = FakeFaceID()
        faceID.available = .failure(.noFaceID)
        let keys = PhoneKeys(keychain: MemoryKeychain(), secureEnclave: false)
        try keys.makeDeviceKey()
        let keyring = PhoneKeyring(keys: keys, faceID: faceID, attester: AppAttest.live())
        #expect(throws: KeysError.noFaceID) { try keyring.makePairingKeys() }
        faceID.available = .failure(.noPasscode)
        #expect(throws: KeysError.noPasscode) { try keyring.makePairingKeys() }
        #expect(try keys.hasPresenceKey() == false)
    }

    #if targetEnvironment(simulator)
    @Test func theSimulatorClaimsWithoutAttestation() async throws {
        let attester = AppAttest.live()
        #expect(try await attester.attestNewKey(clientDataHash: Data(repeating: 7, count: 32)) == .noneSimulator)
        await #expect(throws: KeysError.badClientDataHash) { try await attester.attestNewKey(clientDataHash: Data(count: 31)) }
        await #expect(throws: KeysError.appAttestUnavailable) {
            try await attester.assertion(keyID: "a2V5", clientDataHash: Data(count: 32))
        }
    }

    @Test func theSimulatorsKeyFileKeepsAndForgets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString).plist")
        let file = SimulatorKeyFile(url: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = PhoneKeys(keychain: file, secureEnclave: false)
        let made = try keys.makeDeviceKey()
        #expect(try PhoneKeys(keychain: SimulatorKeyFile(url: url), secureEnclave: false).deviceKey()?.publicKeyDER == made.publicKeyDER)
        #expect(throws: KeysError.sessionNotOpen) { try file.read(.cacheKey, context: nil) }
        #expect(try (url.resourceValues(forKeys: [.isExcludedFromBackupKey])).isExcludedFromBackup == true)
        try keys.wipe()
        #expect(try file.names().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    #endif
}

// MARK: The session

@MainActor
struct PresenceSessionTests {
    private func session(
        _ keys: FakePresenceKeys = FakePresenceKeys(), _ faceID: FakeFaceID = FakeFaceID(),
        mode: PresenceSession.Mode = .oneCheckPerSession, clock: HandClock = HandClock()
    ) -> PresenceSession {
        PresenceSession(keys: keys, faceID: faceID, mode: mode, now: { clock.now })
    }

    @Test func theDefaultIsOneCheckForTheSession() {
        #expect(PresenceSession.Mode.chosen == .oneCheckPerSession)
        #expect(PresenceSession.awayLimit == .seconds(60))
    }

    @Test func oneFaceIDSignsEveryPresenceSignatureUntilTheSessionEnds() async throws {
        let keys = FakePresenceKeys()
        let faceID = FakeFaceID()
        let session = session(keys, faceID)
        #expect(session.state == .locked)
        await #expect(throws: KeysError.sessionNotOpen) { try await session.signPresence(Data("x".utf8)) }

        await session.open()
        #expect(session.state == .open)
        let der = try #require(try session.presencePublicKeyDER())
        for index in 1...20 {
            let message = Data("attach \(index)".utf8)
            #expect(try verifies(try await session.signPresence(message), message, der))
        }
        #expect(faceID.checks == 1)
        #expect(session.mode == .oneCheckPerSession)

        var ended: [PresenceSession.EndReason] = []
        session.onEnd = { ended.append($0) }
        session.end(.lockButton)
        #expect(session.state == .locked)
        #expect(session.lastEnd == .lockButton)
        #expect(faceID.passes.first?.invalidated == true)
        #expect(ended == [.lockButton])
        await #expect(throws: KeysError.sessionNotOpen) { try await session.signPresence(Data("x".utf8)) }
        // Ending again tells nobody: there is no session.
        session.end(.lockButton)
        #expect(ended == [.lockButton])
    }

    @Test func whereOneCheckSignsOnlyOnceEachConnectionAsksAgain() async throws {
        let keys = FakePresenceKeys()
        keys.reuseHolds = false
        let faceID = FakeFaceID()
        let session = session(keys, faceID)
        keys.currentPass = { [weak faceID] in faceID?.passes.last }
        await session.open()
        for index in 1...5 {
            _ = try await session.signPresence(Data("attach \(index)".utf8))
        }
        // The first under the opening Face ID; then the refusal is noticed, and each asks a Face ID of its own.
        #expect(session.fellBack)
        #expect(session.mode == .checkPerConnection)
        #expect(faceID.checks == 5)
        #expect(keys.signatures == 5)
        // Each connection's own Face ID ends once it has signed; the session's stays until the session ends.
        #expect(faceID.passes.dropFirst().allSatisfy { $0.invalidated })
        #expect(faceID.passes.first?.invalidated == false)
        #expect(session.state == .open)
    }

    @Test func theFallbackChosenAsksForEachConnection() async throws {
        let faceID = FakeFaceID()
        let session = session(FakePresenceKeys(), faceID, mode: .checkPerConnection)
        await session.open()
        _ = try await session.signPresence(Data("attach".utf8))
        _ = try await session.signPresence(Data("resume".utf8))
        #expect(faceID.checks == 3)
        #expect(!session.fellBack)
        // A connection whose Face ID does not pass is not signed for; the session stays open.
        faceID.outcomes = [.failed(.notRecognised)]
        await #expect(throws: KeysError.faceIDNotPassed) { try await session.signPresence(Data("again".utf8)) }
        #expect(session.state == .open)
    }

    @Test func aMinuteAwayEndsTheSession() async throws {
        let clock = HandClock()
        let faceID = FakeFaceID()
        let session = session(FakePresenceKeys(), faceID, clock: clock)
        var ended: [PresenceSession.EndReason] = []
        session.onEnd = { ended.append($0) }
        await session.open()

        session.movedToBackground()
        clock.advance(.seconds(59))
        #expect(session.cameToForeground())
        #expect(session.state == .open)

        session.movedToBackground()
        clock.advance(.seconds(60))
        // Asked to sign while away for a minute, even before it is back: refused, and the session ends.
        await #expect(throws: KeysError.sessionNotOpen) { try await session.signPresence(Data("x".utf8)) }
        #expect(session.state == .locked)
        #expect(ended == [.awayTooLong])
        #expect(!session.cameToForeground())
        #expect(faceID.passes.first?.invalidated == true)
    }

    @Test func theTimerEndsTheSessionWhileAway() async throws {
        let session = PresenceSession(keys: FakePresenceKeys(), faceID: FakeFaceID(), awayLimit: .milliseconds(50))
        await session.open()
        session.movedToBackground()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while session.state == .open, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.state == .locked)
        #expect(session.lastEnd == .awayTooLong)
    }

    @Test func lockingThePhoneEndsTheSession() async {
        let session = session()
        await session.open()
        session.phoneWillLock()
        #expect(session.state == .locked)
        #expect(session.lastEnd == .phoneLocked)
    }

    @Test func failuresAndCancelling() async {
        let faceID = FakeFaceID()
        let session = session(FakePresenceKeys(), faceID)
        for failure in [SessionFailure.noFaceID, .faceIDLockedOut, .faceIDNotAllowed, .noBiometrics, .noPasscode, .notRecognised] {
            faceID.outcomes = [.failed(failure)]
            await session.open()
            #expect(session.state == .failed(failure))
        }
        faceID.outcomes = [.cancelled]
        await session.open()
        #expect(session.state == .locked)
        await session.open()
        #expect(session.state == .open)
    }

    @Test func noPresenceKeyAsksNothing() async {
        let keys = FakePresenceKeys()
        keys.present = false
        let faceID = FakeFaceID()
        let session = session(keys, faceID)
        await session.open()
        #expect(session.state == .failed(.keysGone))
        #expect(faceID.checks == 0)
    }

    @Test func faceIDSetUpAgainMakesANewKeyForTheMacToAccept() async {
        let keys = FakePresenceKeys()
        let faceID = FakeFaceID()
        faceID.stateHash = Data("faces-2".utf8)
        let session = session(keys, faceID)
        await session.open()
        #expect(session.state == .failed(.faceIDSetUpAgain))
        #expect(keys.replaced == 1)
        #expect(keys.madeFor == Data("faces-2".utf8))
        #expect(faceID.passes.first?.invalidated == true)
        // Asked again, it opens with the new key.
        await session.open()
        #expect(session.state == .open)
        #expect(keys.replaced == 1)
    }

    @Test func aFaceIDThatAnswersAfterTheSessionEndedIsDropped() async {
        let faceID = FakeFaceID()
        faceID.holds = true
        let session = session(FakePresenceKeys(), faceID)
        let opening = Task { await session.open() }
        while faceID.checks == 0 { await Task.yield() }
        #expect(session.state == .opening)
        session.end(.phoneLocked)
        faceID.release()
        await opening.value
        #expect(session.state == .locked)
        #expect(faceID.passes.first?.invalidated == true)
    }

    @Test func localAuthenticationsErrorsAreRead() {
        #expect(LocalFaceID.failure(code: LAError.Code.biometryNotEnrolled.rawValue, biometry: .faceID) == .noFaceID)
        #expect(LocalFaceID.failure(code: LAError.Code.biometryLockout.rawValue, biometry: .faceID) == .faceIDLockedOut)
        #expect(LocalFaceID.failure(code: LAError.Code.biometryNotAvailable.rawValue, biometry: .faceID) == .faceIDNotAllowed)
        #expect(LocalFaceID.failure(code: LAError.Code.biometryNotAvailable.rawValue, biometry: .none) == .noBiometrics)
        #expect(LocalFaceID.failure(code: LAError.Code.passcodeNotSet.rawValue, biometry: .faceID) == .noPasscode)
        #expect(LocalFaceID.failure(code: LAError.Code.authenticationFailed.rawValue, biometry: .faceID) == .notRecognised)
        #expect(LocalFaceID.failure(code: -9999, biometry: .faceID) == .other(-9999))
    }

    @Test func everyStateHasItsWords() {
        let states: [PresenceSession.State] = [.locked, .opening, .open] + [
            SessionFailure.noFaceID, .faceIDLockedOut, .faceIDNotAllowed, .noBiometrics, .noPasscode, .notRecognised,
            .faceIDSetUpAgain, .keysGone, .other(-1),
        ].map { .failed($0) }
        for state in states {
            let words = PresenceLockWords(state: state)
            #expect(!words.title.isEmpty && !words.text.isEmpty)
        }
        // The passcode never opens pi²: no state offers it.
        #expect(states.allSatisfy { PresenceLockWords(state: $0).button?.localizedCaseInsensitiveContains("passcode") != true })
        #expect(PresenceLockWords(state: .locked).button == "Open with Face ID")
        #expect(PresenceLockWords(state: .failed(.noBiometrics)).button == nil)
        #expect(PresenceLockWords(state: .locked, lastEnd: .awayTooLong).text.hasPrefix("It locked after a minute away."))
    }

    /// Face ID itself, in the simulator: enrolled and matched from outside, as docs/iphone.md 10 has it. Runs only
    /// when `TEST_RUNNER_PI2_FACE_ID_MATCH=1` says something is sending `com.apple.BiometricKit_Sim.fingerTouch.match`
    /// meanwhile, since otherwise Face ID's sheet would wait for a face.
    @Test func theSimulatorsFaceIDOpensASession() async throws {
        guard ProcessInfo.processInfo.environment["PI2_FACE_ID_MATCH"] == "1" else { return }
        let gate = LocalFaceID()
        guard case .success(let state) = gate.availability() else {
            Issue.record("Face ID is not enrolled in this simulator")
            return
        }
        let keys = PhoneKeys(keychain: MemoryKeychain(), secureEnclave: false)
        try keys.makeDeviceKey()
        let made = try keys.makePairingKeys(faceIDState: state)
        let session = PresenceSession(keys: keys, faceID: gate)
        await session.open()
        #expect(session.state == .open)
        for index in 1...20 {
            let message = Data("attach \(index)".utf8)
            #expect(try verifies(try await session.signPresence(message), message, made.presence))
        }
        #expect(try session.cacheKey() != nil)
        session.end(.lockButton)
        await #expect(throws: KeysError.sessionNotOpen) { try await session.signPresence(Data("x".utf8)) }
    }
}
