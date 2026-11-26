
import EngineKit
import Foundation
import Observation
import os

/// The app's hold on its Mac (docs/iphone-app.md, "How the app starts"): the keys, the store and its Outbox, the pairing
/// record and the connection, joined to the one `AppSession` every screen reads. It does, in order, what
/// docs/iphone-app.md's list "What `App/` must call" asks:
///
/// 1. made once at launch, with `PhoneKeyring.live()` and `PhoneStore()` already made and swept (`Pi2App.init`);
/// 2. when Face ID opens a session (`keyring.session.state == .open`): the store opened with the cache key, the
///    connection started, the client started on it (`RecordingTransport` over `connection.transport()`), and the
///    Outbox sent through the engine as soon as the channel is attached, before anything new;
/// 3. while it lasts: the connection's state mirrored into `session.connection`, the client connected again to the
///    next transport when the Mac lost the session, and the store's last state shown through `CachedTransport` while
///    the Mac cannot be reached (so what is written then goes to the Outbox);
/// 4. when the session ends: the cache key forgotten, `sessionEnd` said on the channel, the connection stopped, and the
///    client let go;
/// 5. when the Mac revokes this phone (`connection.unpaired`): the store wiped (`.revoked`), keeping what the Outbox had
///    not sent to show on the first screen, the keys wiped, and the first screen again.
///
/// It watches the keyring's session and the connection itself (not a view), so that it works while no scene is drawn,
/// as when iOS starts pi² in the background for a Shortcut.
@MainActor
@Observable
final class PhoneLink {
    /// What the session's start did, in order: for the tests and the log.
    enum Step: Equatable, Sendable {
        case storeOpened
        case connectionStarted
        /// The client was started on the channel (`RecordingTransport`).
        case live
        /// The client was started on the store's last state (`CachedTransport`), the Mac not reached.
        case cached
        case outboxSent
        case sessionEnded
        case wiped(PhoneStore.Wipe)
    }

    /// Which transport the client is on.
    enum Carrier: Equatable, Sendable {
        /// Nothing: no session is open, or nothing is paired.
        case none
        case live
        case cached
    }

    let session: AppSession
    let keyring: PhoneKeyring
    let store: PhoneStore
    let outbox: Outbox
    let pairingStore: any PairingStore
    let routes: Routes

    /// Whether a Mac is paired, as far as this launch goes: the presence gate is on, and the first screen off, while it is.
    private(set) var paired = false
    /// The connection to the paired Mac, made once a session first opens.
    private(set) var connection: RemoteConnection?
    /// How the last pairing ended on this launch, for the first screen to say.
    private(set) var ended: Ending?
    /// What the Outbox had not sent when the pairing ended, which the first screen shows before it is gone (3.6).
    private(set) var unsent: [OutboxItem] = []
    private(set) var carrier: Carrier = .none

    enum Ending: Equatable, Sendable {
        /// The Mac revoked this phone, with its signature.
        case revoked
        /// The person unpaired it, here.
        case unpaired
        /// The keys were gone (the passcode was turned off): the pairing could not be used.
        case keysGone
    }

    @ObservationIgnored private(set) var steps: [Step] = []
    /// Called once a pairing has ended and the store is wiped (revoked, unpaired, the keys gone): `PhoneSurfaces` takes
    /// away what the extensions and iOS still show of the Mac.
    @ObservationIgnored var onEnded: ((Ending) -> Void)?
    @ObservationIgnored private let phone: @MainActor () -> PhoneDescription
    @ObservationIgnored private var opening = false
    /// Whether the channel attached in this Face ID session: a drop after it keeps the client on the channel, which
    /// resumes, rather than showing the store.
    @ObservationIgnored private var attachedInSession = false
    /// Whether this Face ID session started the connection. Until it has, the connection's state is the stopped one's,
    /// which chooses no transport: followed after a new session opened (an unlock right after the lock, before the main
    /// actor ran what the stop queued), its `.outOfReach` with the store not yet open would put the client on the
    /// channel, and the carrier set then would keep `sessionOpened` from starting the connection (#899).
    @ObservationIgnored private var startedInSession = false
    /// Which watch of the connection is current (#907). `sessionOpened` starts a new one; an unpairing and the end of the
    /// pairing end it. A watch registers again after a change only while it is current, so a session adds no watch to
    /// those before it. The end of a session keeps it: it mirrors the stopped connection's state, and it takes a
    /// revocation, which ends the session (`keyring.wipe()`) before the watch hears of `unpaired`.
    @ObservationIgnored private var watchGeneration = 0
    /// How many times the connection's state was followed: once a change, however many sessions came before (#907).
    @ObservationIgnored private(set) var followed = 0
    @ObservationIgnored private let log = Logger(subsystem: "dev.pi2.ios", category: "link")

    init(
        session: AppSession, keyring: PhoneKeyring, store: PhoneStore, pairingStore: (any PairingStore)? = nil, routes: Routes = Launch.routes,
        phone: @escaping @MainActor () -> PhoneDescription = { PhoneDescription.current() }
    ) {
        self.session = session
        self.keyring = keyring
        self.store = store
        self.pairingStore = pairingStore ?? KeychainPairingStore(keys: keyring.keys)
        self.routes = routes
        self.phone = phone
        outbox = Outbox(store: store)
        session.onConnected = { [weak self] in self?.clientConnected() }
        session.onLost = { [weak self] in self?.clientLost() }
        keyring.session.onEnd = { [weak self] reason in self?.sessionEnded(reason) }
        watchPresence()
    }

    /// The pairing kept on this phone, if any: what `Launch` asks to choose the root.
    var record: PairingRecord? { try? pairingStore.load() }

    /// For Shortcuts (`IntentSessions.register`): whether an intent may go on without opening pi² for Face ID. True
    /// when nothing is paired (the intent then says so), else only in an open session.
    var isOpenForIntents: Bool {
        !paired || keyring.session.state == .open
    }

    /// For Shortcuts (`IntentSessions.register`): whether a session Face ID just opened is still being put on its
    /// transport (the store, the connection, the client), so that an intent waits for it rather than taking the locked
    /// session's closed client for a Mac out of reach.
    var isSettlingForIntents: Bool {
        paired && keyring.session.state == .open && carrier == .none
    }

    // MARK: - Launch

    /// A paired Mac at launch: the lock screen until Face ID opens a session, which the presence gate asks for.
    func startPaired(_ record: PairingRecord) {
        paired = true
        session.macName = record.macName
        session.connection = .outOfReach(lastSeen: store.lastHeard)
        if keyring.session.state == .open { Task { await sessionOpened() } }
    }

    // MARK: - Pairing

    /// The pairing screens' flow, for the first screen's **Scan the code on your Mac**.
    func pairingFlow() -> PairingFlow {
        PairingFlow(needs: PairingFlow.Needs(
            keyStore: keyring, attester: keyring.attester, store: pairingStore, phone: phone(), routes: routes,
            unpair: { [weak self] in await self?.unpairBeforeReplacing() }))
    }

    /// Pairing finished (`PairingView`'s `done`): the session opens with Face ID, and the projects list comes on the
    /// live connection.
    func didPair(_ record: PairingRecord) {
        ended = nil
        unsent = []
        connection = nil
        startPaired(record)
        session.connection = .connecting
        Task { await keyring.session.open() }
    }

    /// Before a pairing replaces this one (3.3, "Pairing again"): the relay told `leave`, the keys and record wiped (by
    /// the connection, or by the flow next), the store wiped.
    private func unpairBeforeReplacing() async {
        // Not the Mac's revocation: the connection's `unpaired` is not to be taken for one.
        watchGeneration += 1
        await connection?.unpairHere()
        forget(.unpaired)
    }

    /// **Unpair this iPhone** (3.6), for Settings to offer: `devices.forgetSelf` through the client if the Mac is
    /// attached, the relay told `leave`, the keys and the record wiped, the store wiped, and the first screen.
    func unpairThisIPhone() async {
        if carrier == .live, session.engine.status == .connected {
            _ = try? await session.engine.call("devices.forgetSelf", [:])
        }
        watchGeneration += 1
        if let connection {
            await connection.unpairHere()
        } else {
            try? keyring.wipe()
        }
        forget(.unpaired)
    }

    // MARK: - The Face ID session

    private func watchPresence() {
        let state = withObservationTracking {
            keyring.session.state
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchPresence() }
        }
        guard paired else { return }
        switch state {
        case .open:
            Task { await sessionOpened() }
        case .failed(.keysGone):
            // A record whose keys are gone (deleted with the passcode) can never open: pair again, from the first screen.
            try? keyring.wipe()
            forget(.keysGone)
        default:
            break
        }
    }

    /// Face ID opened a session: the store, then the connection, then the client on it; the Outbox goes once attached.
    func sessionOpened() async {
        guard paired, keyring.session.state == .open, !opening, carrier == .none else { return }
        opening = true
        defer { opening = false }
        if connection == nil {
            connection = await RemoteConnection.paired(keyStore: keyring, store: pairingStore, routes: routes)
        }
        guard paired, keyring.session.state == .open else { return }
        guard let connection else {
            // Paired, but the record or the keys do not read: nothing half kept is used.
            log.error("The pairing kept on this iPhone does not read; back to the first screen.")
            try? keyring.wipe()
            forget(.keysGone)
            return
        }
        // Opened after the wait above, with the key of the session that starts the connection: a session that ended
        // during it closed the store, and one opened after that found this call opening and left its start to it.
        if let key = try? keyring.session.cacheKey() {
            store.open(key: key)
            step(.storeOpened)
        }
        session.macName = connection.macName
        attachedInSession = false
        startedInSession = true
        connection.start()
        step(.connectionStarted)
        watch(connection)
        follow(connection.connection)
    }

    /// The session ended (a minute away, the phone locked, Lock, a revocation): the cache key forgotten, `sessionEnd`
    /// said on the channel and the connection stopped, and the client let go, so nothing is sent until Face ID again.
    private func sessionEnded(_ reason: PresenceSession.EndReason) {
        // On a revocation the store is wiped next, and what the Outbox held must still be there to be shown.
        if reason != .revoked { store.close() }
        connection?.stop()
        attachedInSession = false
        startedInSession = false
        if carrier != .none {
            carrier = .none
            session.start(LockedTransport(), as: paired ? .outOfReach(lastSeen: store.lastHeard) : .notPaired)
        }
        step(.sessionEnded)
    }

    // MARK: - The connection

    /// Follows the connection's state and its revocation, in a watch of its own: the one before ends at its next change.
    private func watch(_ connection: RemoteConnection) {
        watchGeneration += 1
        watch(connection, generation: watchGeneration)
    }

    private func watch(_ connection: RemoteConnection, generation: Int) {
        let (state, unpaired) = withObservationTracking {
            (connection.connection, connection.unpaired)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.watchGeneration == generation else { return }
                self.watch(connection, generation: generation)
            }
        }
        if unpaired {
            revoked()
            return
        }
        follow(state)
    }

    /// Mirrors the connection's state into the session, and puts the client on the channel or on the store's last state:
    /// only once this session has started the connection (`startedInSession`).
    private func follow(_ state: AppSession.Connection) {
        followed += 1
        let state = Self.aged(state, lastHeard: store.lastHeard)
        guard paired else { return }
        guard keyring.session.state == .open, startedInSession, let connection else {
            session.connection = state
            return
        }
        if case .connected = state { attachedInSession = true }
        let wanted = Self.carrier(for: state, attachedInSession: attachedInSession, storeOpen: store.isOpen, cacheEmpty: store.cache.isEmpty)
        switch wanted {
        case .live where carrier != .live:
            carrier = .live
            session.start(RecordingTransport(connection.transport(), store: store), as: state)
            step(.live)
        case .cached where carrier != .cached:
            carrier = .cached
            session.start(CachedTransport(store.cache, outbox: outbox), as: state)
            step(.cached)
        default:
            session.connection = state
        }
    }

    /// Which transport the client is to be on, for the connection's state (the start-up's one decision of it):
    /// - connected: the channel;
    /// - reaching the Mac: the channel if it attached in this session (it resumes) or the store has nothing to show,
    ///   else the store's last state;
    /// - out of reach: the store's last state, through which what is written goes to the Outbox, if the store is open;
    ///   the channel otherwise, which keeps what is sent until it attaches.
    nonisolated static func carrier(for state: AppSession.Connection, attachedInSession: Bool, storeOpen: Bool, cacheEmpty: Bool) -> Carrier {
        switch state {
        case .connected:
            .live
        case .connecting:
            attachedInSession || !storeOpen || cacheEmpty ? .live : .cached
        case .outOfReach:
            storeOpen ? .cached : .live
        case .notPaired, .demo:
            .none
        }
    }

    /// Keeps the out-of-reach state's time from going back to nil (#949): the connection keeps its own `lastSeen` in
    /// memory only, so on a fresh launch it is nil, while the store knows when the Mac was last heard. For an out-of-reach
    /// state the later of the two wins (either may be nil, and both nil leaves it nil); every other state is unchanged.
    nonisolated static func aged(_ state: AppSession.Connection, lastHeard: Date?) -> AppSession.Connection {
        switch state {
        case .outOfReach(let seen):
            .outOfReach(lastSeen: [seen, lastHeard].compactMap({ $0 }).max())
        default:
            state
        }
    }

    /// The client's transport is ready. On the channel, the Outbox goes first, before the person sends anything new.
    private func clientConnected() {
        guard carrier == .live, store.isOpen else { return }
        Task {
            let report = await outbox.send(through: EngineOutboxCourier(session.engine))
            if !report.taken.isEmpty || !report.notSent.isEmpty || report.stopped != nil {
                log.notice("Outbox: \(report.taken.count) taken, \(report.notSent.count) not sent\(report.stopped.map { ", stopped: \($0)" } ?? "", privacy: .public)")
            }
            step(.outboxSent)
        }
    }

    /// The client let its transport go: on the channel, the Mac could not resume the session, and the next transport is
    /// a new session at the engine, whose greeting comes on it.
    private func clientLost() {
        guard carrier == .live, paired, keyring.session.state == .open, let connection, !connection.unpaired else { return }
        session.start(RecordingTransport(connection.transport(), store: store), as: connection.connection)
    }

    /// **Try again** on the connection's problem.
    func tryAgain() {
        connection?.tryAgain()
    }

    // MARK: - The end of a pairing

    /// The Mac's signed revocation: the connection has wiped the keys and the record; the store goes, what the Outbox
    /// had not sent is kept for the first screen, and the first screen comes back.
    private func revoked() {
        try? keyring.wipe()
        forget(.revoked)
    }

    private func forget(_ ending: Ending) {
        let reason: PhoneStore.Wipe = ending == .revoked ? .revoked : .unpaired
        let left = store.wipe(reason)
        step(.wiped(reason))
        unsent = left.filter(\.isPending)
        ended = ending
        watchGeneration += 1
        connection = nil
        paired = false
        attachedInSession = false
        startedInSession = false
        carrier = .none
        session.engine.forgetConversations()
        session.macName = nil
        session.start(LockedTransport(), as: .notPaired)
        onEnded?(ending)
    }

    private func step(_ step: Step) {
        steps.append(step)
        log.debug("\(String(describing: step), privacy: .public)")
    }
}

/// What the client is connected to while no session is open: nothing. It closes at once, so the client knows it reaches
/// nothing, and every request fails rather than waiting for a Mac (docs/iphone.md 4.5).
@MainActor
final class LockedTransport: EngineTransport {
    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        Task { @MainActor in handler(.closed("pi² is locked.")) }
    }

    func send(_ data: Data) {}

    func cancel() {}
}
