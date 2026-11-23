import CryptoKit
import Foundation
import Observation

/// The open session of docs/iphone.md 4.3 and 4.5 (decision 26: "Face ID to open the app, nothing after").
///
/// Face ID is asked once, in one `LAContext`, when pi² comes to the foreground with no open session; the presence key
/// then signs under that context, with no new prompt, for every attach, resume and mailbox item until the session ends.
/// It ends after 60 seconds out of the foreground, when the phone locks, on the Lock button, on a revocation or an
/// unpairing, and with the process; the context is invalidated at that moment, and `onEnd` lets the connection tell the
/// engine (`remote.sessionEnd`).
///
/// **Whether one check signs many times** is for the owner's phone to show (4.3, the Face ID check). `Mode.chosen`
/// decides, and the session also finds out for itself: the context is set to show nothing after Face ID, so a signature
/// that would need a new prompt fails, and from then on (for this run of the app) each new connection asks Face ID
/// again, which is 4.3's fallback.
@MainActor
@Observable
final class PresenceSession: PresenceSigning {
    enum State: Equatable, Sendable {
        /// No session: the lock screen, with Open with Face ID.
        case locked
        /// Face ID is being asked.
        case opening
        case open
        case failed(SessionFailure)
    }

    enum Mode: Equatable, Sendable {
        /// One Face ID opens the session, and its context signs every presence signature until the session ends.
        case oneCheckPerSession
        /// 4.3's fallback: the first Face ID opens pi², and each presence signature (each new connection, each mailbox
        /// item) asks Face ID again in a context of its own, invalidated once it has signed.
        case checkPerConnection

        /// The one setting. The default until the owner's phone says otherwise; set to `.checkPerConnection` if the
        /// check on the phone does not answer "20 signatures, 1 Face ID check; after invalidate: refused".
        static let chosen: Mode = .oneCheckPerSession
    }

    enum EndReason: Equatable, Sendable {
        /// pi² was out of the foreground for a minute.
        case awayTooLong
        /// The phone locked.
        case phoneLocked
        /// The person pressed Lock.
        case lockButton
        /// The Mac revoked this phone, or the phone unpaired itself: its keys are wiped.
        case revoked
    }

    /// How long pi² may be out of the foreground before its session ends (4.5).
    static let awayLimit: Duration = .seconds(60)

    static let openReason = "Face ID opens pi², so that only you can answer for your Mac from this iPhone."
    static let connectReason = "Face ID connects pi² to your Mac."

    private(set) var state: State = .locked
    private(set) var mode: Mode
    /// Set when one check proved not to sign again on this phone and the session fell back to a check per connection.
    private(set) var fellBack = false
    /// Why the last session ended, for the lock screen's line.
    private(set) var lastEnd: EndReason?
    /// Called once when an open (or opening) session ends, for the connection to tell the engine.
    @ObservationIgnored var onEnd: ((EndReason) -> Void)?

    private let keys: any PresenceKeyHolding
    @ObservationIgnored private let faceID: any FaceIDGate
    private let awayLimit: Duration
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private var pass: (any FaceIDPass)?
    @ObservationIgnored private var awaySince: ContinuousClock.Instant?
    @ObservationIgnored private var awayTimer: Task<Void, Never>?
    /// Counts attempts, so a Face ID that answers after the session was ended or opened again is dropped.
    @ObservationIgnored private var attempt = 0

    init(
        keys: any PresenceKeyHolding, faceID: any FaceIDGate, mode: Mode = .chosen,
        awayLimit: Duration = PresenceSession.awayLimit, now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.keys = keys
        self.faceID = faceID
        self.mode = mode
        self.awayLimit = awayLimit
        self.now = now
    }

    // MARK: Opening and ending

    /// Asks Face ID and opens the session. Does nothing while one is opening or open.
    func open() async {
        if state == .opening || state == .open { return }
        attempt += 1
        let mine = attempt
        state = .opening
        guard (try? keys.hasPresenceKey()) == true else {
            state = .failed(.keysGone)
            return
        }
        let outcome = await faceID.check(reason: Self.openReason)
        guard mine == attempt, state == .opening else {
            if case .passed(let late) = outcome { late.invalidate() }
            return
        }
        switch outcome {
        case .cancelled:
            state = .locked
        case .failed(let failure):
            state = .failed(failure)
        case .passed(let passed):
            // A different hash of the enrolled faces means Face ID was enrolled again: `biometryCurrentSet` has made
            // the presence key and the cache key unusable for good. 3.2: a new key, used once the Mac accepts it.
            if let current = passed.stateHash, let made = (try? keys.presenceFaceIDState()) ?? nil, current != made {
                passed.invalidate()
                do {
                    _ = try keys.replacePresenceKey(faceIDState: current)
                    state = .failed(.faceIDSetUpAgain)
                } catch {
                    state = .failed(.keysGone)
                }
                return
            }
            pass = passed
            awaySince = nil
            lastEnd = nil
            state = .open
        }
    }

    /// Ends the session: invalidates its context, so the presence key cannot sign until Face ID is asked again.
    func end(_ reason: EndReason) {
        attempt += 1
        awayTimer?.cancel()
        awayTimer = nil
        let wasOpen = pass != nil || state == .open || state == .opening
        pass?.invalidate()
        pass = nil
        guard wasOpen else { return }
        state = .locked
        lastEnd = reason
        onEnd?(reason)
    }

    /// pi² went to the background. The session ends once it has been away for `awayLimit`, by a timer while iOS lets
    /// the app run, and in any case when it comes back or is asked to sign.
    func movedToBackground() {
        guard awaySince == nil else { return }
        awaySince = now()
        guard pass != nil || state == .opening else { return }
        awayTimer?.cancel()
        let limit = awayLimit
        awayTimer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self?.endIfAwayTooLong()
        }
    }

    /// pi² is in the foreground again. Answers whether a session is still open.
    @discardableResult
    func cameToForeground() -> Bool {
        awayTimer?.cancel()
        awayTimer = nil
        endIfAwayTooLong()
        awaySince = nil
        return state == .open
    }

    /// The phone is locking (`protectedDataWillBecomeUnavailable`).
    func phoneWillLock() {
        end(.phoneLocked)
    }

    private func endIfAwayTooLong() {
        guard let since = awaySince, now() - since >= awayLimit else { return }
        end(.awayTooLong)
    }

    // MARK: Signing

    nonisolated func presencePublicKeyDER() throws -> Data? {
        try keys.presencePublicKey()
    }

    nonisolated func signPresence(_ data: Data) async throws -> Data {
        try await sign(data)
    }

    private func sign(_ data: Data) async throws -> Data {
        endIfAwayTooLong()
        guard state == .open, let pass else { throw KeysError.sessionNotOpen }
        if mode == .oneCheckPerSession {
            do {
                return try keys.signPresence(data, context: pass.context)
            } catch KeysError.needsFaceIDAgain {
                // One check does not sign again on this phone: each new connection asks Face ID (4.3's fallback).
                fellBack = true
                mode = .checkPerConnection
            }
        }
        let outcome = await faceID.check(reason: Self.connectReason)
        guard case .passed(let fresh) = outcome else { throw KeysError.faceIDNotPassed }
        defer { fresh.invalidate() }
        guard state == .open else { throw KeysError.sessionNotOpen }
        return try keys.signPresence(data, context: fresh.context)
    }

    /// The cache key, read under the session's context: the store reads it once, as the session opens, keeps it in
    /// memory and forgets it in `onEnd` (3.2: the cache opens only in an open session).
    func cacheKey() throws -> SymmetricKey? {
        guard state == .open, let pass else { throw KeysError.sessionNotOpen }
        return try keys.cacheKey(context: pass.context)
    }
}
