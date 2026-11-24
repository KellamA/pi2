
import Foundation
import LocalAuthentication
import RemoteKit
import Testing
@testable import pi2

/// The app's start-up (#680, `App/Launch.swift`, `App/PhoneLink.swift`, `App/RootView.swift`): which root for which
/// state, which transport the client is on, and, with Keys/'s keys in memory, the store in a folder of the test's own
/// and the test Mac over loopback TCP, the order of a session's start (store, connection, client, Outbox) and what a
/// revocation wipes.
@MainActor
@Suite(.serialized)
struct AppStartTests {
    // MARK: - Decisions

    @Test func theLaunchChoosesByTheLaunchValueThenByThePairing() {
        #expect(Launch.choice(paired: true) == .remote)
        #expect(Launch.choice(paired: false) == .firstRun)
        #expect(Launch.choice(paired: true, transport: "remote") == .remote)
        #expect(Launch.choice(paired: false, transport: "remote") == .firstRun, "remote with nothing paired is the first screen")
        #expect(Launch.choice(paired: true, transport: "demo") == .demo)
        #expect(Launch.choice(paired: false, transport: "replay") == .replay)
        #expect(Launch.choice(paired: false, connection: "home") == .stated)
        #expect(Launch.choice(paired: true, transport: "remote", connection: "home") == .remote)
        #expect(Launch.choice(paired: true, transport: "nonsense") == .remote, "a word that is no transport starts as with none")
    }

    @Test func theRootIsTheFirstScreenOnlyWhileNothingIsPaired() {
        #expect(RootView.screen(for: .notPaired) == .firstScreen)
        for connection: AppSession.Connection in [.demo, .connecting, .connected(.home), .connected(.relay, relayReachable: true), .outOfReach(lastSeen: nil)] {
            #expect(RootView.screen(for: connection) == .projects, "\(connection)")
        }
    }

    @Test func theClientIsOnTheChannelOrOnTheStoresLastState() {
        func carrier(_ state: AppSession.Connection, attached: Bool = false, open: Bool = true, empty: Bool = false) -> PhoneLink.Carrier {
            PhoneLink.carrier(for: state, attachedInSession: attached, storeOpen: open, cacheEmpty: empty)
        }
        #expect(carrier(.connected(.direct, relayReachable: false)) == .live)
        #expect(carrier(.connecting) == .cached, "the last state shows while the Mac is reached for")
        #expect(carrier(.connecting, empty: true) == .live, "nothing kept: nothing to show but the channel's")
        #expect(carrier(.connecting, attached: true) == .live, "a drop in a session stays on the channel, which resumes")
        #expect(carrier(.outOfReach(lastSeen: nil)) == .cached, "out of reach, writes go to the Outbox")
        #expect(carrier(.outOfReach(lastSeen: nil), open: false) == .live)
        #expect(carrier(.notPaired) == .none)
    }

    // MARK: - With the test Mac

    private static func folder() -> StoreFolder {
        StoreFolder(FileManager.default.temporaryDirectory.appending(path: "pi2-test-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    struct Phone {
        let mac: TestMac
        let keyring: PhoneKeyring
        let store: PhoneStore
        let session: AppSession
        let link: PhoneLink
        let record: PairingRecord

        /// Ends the session and stops the connection, then the test Mac: a connection left running keeps reaching for
        /// the stopped Mac, opening sockets while the tests after this one run (DemoTests counts the process's).
        @MainActor
        func stop() {
            keyring.session.end(.lockButton)
            link.connection?.stop()
            mac.stop()
        }
    }

    /// A phone paired with the test Mac through the link's own pairing flow, its session not opened yet. (IntentsTests
    /// uses it too.)
    static func pairedPhone() async throws -> Phone {
        let mac = TestMac()
        let address = try await mac.listen()
        // Keys/'s keys in memory, with a Face ID that passes in a context of its own: the cache key reads only under one.
        let keyring = PhoneKeyring(keys: PhoneKeys(keychain: MemoryKeychain(), secureEnclave: false), faceID: ContextFaceID(), attester: NoAttester())
        let store = PhoneStore(folder: folder())
        let session = AppSession()
        let link = PhoneLink(session: session, keyring: keyring, store: store, routes: PairingTests.routes(), phone: { .test })
        #expect(!link.paired && link.record == nil)
        let flow = link.pairingFlow()
        // Pairing is this setup's, not the subject: a try a stalled runner broke is made again (#910).
        guard case let .digits(digits, _, _) = try await PairingTests.digitsForSetup(flow, mac: mac, address: address) else {
            throw TestFailure("no digits: \(flow.step)")
        }
        mac.typed.push(digits)
        #expect(await Wait.until { flow.step == .paired(mac: mac.name) })
        let record = try #require(flow.record)
        #expect(link.record == record, "kept where the launch looks for it")
        return Phone(mac: mac, keyring: keyring, store: store, session: session, link: link, record: record)
    }

    @Test func aSessionOpensTheStoreThenConnectsThenSendsTheOutboxFirst() async throws {
        let phone = try await Self.pairedPhone()
        defer { phone.stop() }
        // Something written while the Mac was out of reach, waiting in the Outbox from an earlier session.
        await phone.keyring.session.open()
        phone.store.open(key: try #require(try phone.keyring.session.cacheKey()))
        try phone.link.outbox.add("submit", ["id": 9, "text": "Written on the train"])
        phone.store.close()
        phone.keyring.session.end(.lockButton)
        let before = phone.link.steps.count

        phone.link.didPair(phone.record)
        #expect(phone.link.paired)
        #expect(RootView.screen(for: phone.session.connection) == .projects)
        #expect(await Wait.until { phone.link.steps.contains(.outboxSent) })
        let steps = Array(phone.link.steps.dropFirst(before))
        // In order: the store, the connection, then the channel and the Outbox on it, once. An attempt the phone gave up
        // (an answer later than 3.4's ten seconds, on a runner that stalls) shows between them as the store's last state,
        // then the channel again (#910).
        #expect(steps.prefix(2) == [.storeOpened, .connectionStarted] && steps.suffix(2) == [.live, .outboxSent], "\(steps)")
        #expect(steps.dropFirst(2).dropLast(2).allSatisfy { $0 == .live || $0 == .cached }, "\(steps)")
        #expect(await Wait.until { phone.session.engine.projects.count == 2 }, "the projects list on the live connection")
        #expect(phone.session.connection == .connected(.direct, relayReachable: false), "the connection's state, mirrored")
        #expect(phone.session.macName == phone.mac.name)
        #expect(phone.link.carrier == .live)
        let requests = phone.mac.state.withLock { $0.requests }
        #expect(requests.first == "submit", "the Outbox goes before anything new: \(requests)")
        // The recorded Mac refuses a message: it stays, saying why, to send again.
        #expect(phone.link.outbox.items.count == 1 && phone.link.outbox.waitingCount == 0)
    }

    @Test func theSessionsEndForgetsTheCacheKeyAndSaysSoToTheMac() async throws {
        let phone = try await Self.pairedPhone()
        defer { phone.stop() }
        phone.link.didPair(phone.record)
        #expect(await Wait.until { phone.session.engine.projects.count == 2 })
        #expect(phone.store.isOpen)

        phone.keyring.session.end(.lockButton)
        #expect(!phone.store.isOpen, "the cache key is forgotten")
        #expect(phone.link.carrier == .none)
        #expect(await Wait.until { phone.mac.state.withLock { $0.sessionEnds } == 1 }, "remote.sessionEnd on the channel")
        #expect(await Wait.until { phone.session.engine.status != .connected }, "the client reaches nothing while locked")
        #expect(phone.link.paired, "still paired: the lock screen, not the first screen")

        // Face ID again: a new session at the Mac.
        await phone.keyring.session.open()
        #expect(await Wait.until { phone.mac.state.withLock { $0.attachedCount } == 2 })
        #expect(await Wait.until { phone.session.engine.status == .connected && phone.link.carrier == .live })
    }

    // MARK: - Ends and opens in a row (#899)

    // Each of these ends and opens the session with no `await` between that could let the main actor run anything else,
    // so that what the end queued (the stopped connection's state, which its watch follows; the keyring's state, which
    // `watchPresence` follows) runs only after all of it: the order a person gets with an unlock right after the lock.

    /// Lets the main actor run what is queued on it, and what that queues in turn, by waiting for tasks queued after it.
    /// (A wait for the Mac can end at once: its channel's writer runs off the main actor.)
    private static func settle() async {
        for _ in 0..<3 { await Task { @MainActor in }.value }
    }

    /// A phone paired with the test Mac, its first session on the channel and its Outbox sent.
    private static func livePhone() async throws -> Phone {
        let phone = try await pairedPhone()
        phone.link.didPair(phone.record)
        #expect(await Wait.until { phone.link.steps.contains(.outboxSent) && phone.session.engine.projects.count == 2 })
        #expect(phone.link.carrier == .live)
        return phone
    }

    @Test func faceIDRightAfterTheEndStartsTheConnectionAgain() async throws {
        let phone = try await Self.livePhone()
        defer { phone.stop() }
        let before = phone.link.steps.count

        phone.keyring.session.end(.lockButton)
        await phone.keyring.session.open()
        #expect(phone.keyring.session.state == .open)
        #expect(Array(phone.link.steps.dropFirst(before)) == [.sessionEnded], "nothing queued has run yet")

        // The stopped connection's `.outOfReach` is followed now, in a session open with the store not yet opened: it
        // must not choose the channel and so stand in for the session's start.
        #expect(await Wait.until { phone.mac.state.withLock { $0.attachedCount } == 2 }, "a new session at the Mac")
        #expect(await Wait.until { phone.session.engine.status == .connected && phone.link.carrier == .live })
        let steps = Array(phone.link.steps.dropFirst(before))
        #expect(Array(steps.prefix(3)) == [.sessionEnded, .storeOpened, .connectionStarted], "\(steps)")
        #expect(phone.store.isOpen)
    }

    @Test func aLockWhileReachingTheMacThenFaceIDStartsItAgain() async throws {
        let phone = try await Self.pairedPhone()
        defer { phone.stop() }
        let before = phone.link.steps.count
        phone.link.startPaired(phone.record)
        await phone.keyring.session.open()
        // The session's start, run here rather than by the task `watchPresence` queued, which comes later and must do
        // nothing: the connection is started and reaching the Mac, its loop not yet run.
        await phone.link.sessionOpened()
        #expect(Array(phone.link.steps.dropFirst(before)) == [.storeOpened, .connectionStarted, .live])
        #expect(phone.link.connection?.connection == .connecting)

        phone.keyring.session.end(.lockButton)
        await phone.keyring.session.open()

        #expect(await Wait.until { phone.session.engine.status == .connected && phone.link.carrier == .live })
        #expect(await Wait.until { phone.link.steps.contains(.outboxSent) })
        let steps = Array(phone.link.steps.dropFirst(before))
        #expect(Array(steps.prefix(6)) == [.storeOpened, .connectionStarted, .live, .sessionEnded, .storeOpened, .connectionStarted], "\(steps)")
        #expect(phone.mac.state.withLock { $0.attachedCount } == 1, "the first start never reached the Mac")
    }

    @Test func unlockLockUnlockStartsTheConnectionOnce() async throws {
        let phone = try await Self.livePhone()
        defer { phone.stop() }
        let before = phone.link.steps.count

        phone.keyring.session.end(.lockButton)
        await phone.keyring.session.open()
        phone.keyring.session.end(.lockButton)
        await phone.keyring.session.open()

        #expect(await Wait.until { phone.mac.state.withLock { $0.attachedCount } == 2 })
        #expect(await Wait.until { phone.session.engine.status == .connected && phone.link.carrier == .live })
        let steps = Array(phone.link.steps.dropFirst(before))
        #expect(Array(steps.prefix(4)) == [.sessionEnded, .sessionEnded, .storeOpened, .connectionStarted], "\(steps)")
        #expect(steps.filter { $0 == .connectionStarted }.count == 1, "\(steps)")
    }

    @Test func unlockThenLockLeavesTheConnectionStopped() async throws {
        let phone = try await Self.livePhone()
        defer { phone.stop() }
        let before = phone.link.steps.count

        phone.keyring.session.end(.lockButton)
        await phone.keyring.session.open()
        phone.keyring.session.end(.lockButton)
        // Everything the ends and the open queued runs now, before what is queued after it.
        await Self.settle()
        #expect(await Wait.until { phone.mac.state.withLock { $0.sessionEnds } == 1 })
        #expect(await Wait.until { phone.session.engine.status != .connected })
        #expect(Array(phone.link.steps.dropFirst(before)) == [.sessionEnded, .sessionEnded], "nothing started while locked")
        #expect(phone.link.carrier == .none && !phone.store.isOpen)
        #expect({ if case .outOfReach = phone.session.connection { true } else { false } }(), "\(phone.session.connection)")

        await phone.keyring.session.open()
        #expect(await Wait.until { phone.mac.state.withLock { $0.attachedCount } == 2 })
        #expect(await Wait.until { phone.session.engine.status == .connected && phone.link.carrier == .live })
    }

    @Test func aWipeAfterTheEndLeavesNothingStarted() async throws {
        let phone = try await Self.livePhone()
        defer { phone.stop() }
        let before = phone.link.steps.count

        phone.keyring.session.end(.lockButton)
        await phone.link.unpairThisIPhone()
        await phone.keyring.session.open()
        #expect(phone.keyring.session.state == .failed(.keysGone), "no keys to open with")

        await Self.settle()
        #expect(await Wait.until { phone.mac.state.withLock { $0.sessionEnds } == 1 })
        #expect(Array(phone.link.steps.dropFirst(before)) == [.sessionEnded, .wiped(.unpaired)])
        #expect(!phone.link.paired && phone.link.connection == nil && phone.link.carrier == .none)
        #expect(phone.session.connection == .notPaired, "the stopped connection's state is not shown")
        #expect(phone.link.ended == .unpaired)
    }

    @Test func theMacsRevocationWipesTheStoreAndTheKeysAndShowsWhatWasNotSent() async throws {
        let phone = try await Self.pairedPhone()
        defer { phone.stop() }
        phone.link.didPair(phone.record)
        #expect(await Wait.until { phone.link.steps.contains(.outboxSent) && phone.session.engine.projects.count == 2 })
        let item = try phone.link.outbox.add("submit", ["id": 9, "text": "Not yet sent"])
        #expect(await Wait.until { phone.store.isOpen })

        phone.mac.rules.withLock { $0.revokeWithLine = true }
        phone.mac.dropChannels()
        #expect(await Wait.until { !phone.link.paired })
        #expect(phone.session.connection == .notPaired)
        #expect(RootView.screen(for: phone.session.connection) == .firstScreen)
        #expect(phone.link.ended == .revoked)
        #expect(phone.link.steps.contains(.wiped(.revoked)))
        #expect(phone.store.lastWipe == .revoked && !phone.store.isOpen && !phone.store.folder.exists, "the store, whole")
        #expect(phone.link.unsent.map(\.id) == [item.id], "what the Outbox had not sent, shown before it is gone")
        #expect(try phone.keyring.keys.deviceKey() == nil, "the keys")
        #expect(try phone.link.pairingStore.load() == nil, "the Mac's record")
        #expect(phone.link.connection == nil)
    }
}

/// Face ID that always passes, with a context, as LocalAuthentication's would give (`FakeFaceID` gives none).
@MainActor
private final class ContextFaceID: FaceIDGate {
    final class Pass: FaceIDPass {
        let context: LAContext? = LAContext()
        let stateHash: Data? = Data("faces-1".utf8)
        func invalidate() { context?.invalidate() }
    }

    func availability() -> Result<Data?, SessionFailure> { .success(Data("faces-1".utf8)) }
    func check(reason: String) async -> FaceIDOutcome { .passed(Pass()) }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
