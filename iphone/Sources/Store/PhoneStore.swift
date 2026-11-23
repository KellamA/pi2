import CryptoKit
import Foundation
import Observation
import os

/// The phone's store (docs/iphone.md 3.6, 12.1: P23's): what the phone keeps of its Mac between launches, and nothing
/// else. One folder in the app's container (`StoreFolder`), protected, out of backups, holding:
///
/// | File | What | Sealed | Kept |
/// |---|---|---|---|
/// | `manifest.json` | the version, when the Mac was last heard from, when the Outbox last changed, the highest state number shown | no: dates and a number | while paired |
/// | `cache.sealed` | the last state the Mac sent, and its newest conversations (`StateCache`) | with the cache key | until 7 days without the Mac |
/// | `outbox.sealed` | what the person wrote that the Mac has not taken (`OutboxItem`) | with the cache key | until taken, removed, or 7 days untouched |
///
/// **The cache key behind the session.** The sealed parts open only with the cache key (`StoreSeal`), which `Keys/`
/// reads under the authentication context Face ID evaluated for the session: `open(key:)` when the session opens,
/// `close()` when it ends, which forgets the key and everything read with it. No key is stored here.
///
/// **Wiped**: by `wipe(_:)`, in one call that leaves no file of the store behind, on unpairing, on a revocation signed
/// by the Mac, and on the person's request; and by `sweep()`, at every launch and return to the foreground, once seven
/// days pass without the Mac. Deleting the app deletes its container, and the store with it.
@MainActor
@Observable
final class PhoneStore {
    /// How long the store keeps the Mac's state without hearing from it (decision 31).
    static let keptWithoutMac: TimeInterval = 7 * 86_400
    /// How long the cache waits to be written after it changes: the engine sends many lines a second while an answer
    /// streams, and the cache need not be written for each.
    static let cacheDelay: Duration = .seconds(2)

    static let cacheFile = "cache.sealed"
    static let outboxFile = "outbox.sealed"

    /// Why the store was wiped.
    enum Wipe: String, Sendable {
        /// The person unpaired this iPhone (its Settings, or pairing with another Mac).
        case unpaired
        /// The Mac said, signed by its identity key, that this phone is revoked.
        case revoked
        /// The person asked for the store to be emptied.
        case asked
        /// Seven days passed without the Mac.
        case expired
        /// The store could not be read: written by another build, or sealed with a cache key that is gone (Face ID was
        /// enrolled again, which makes a new one).
        case unreadable
    }

    let folder: StoreFolder
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let log = Logger(subsystem: "dev.pi2.ios", category: "store")

    /// What is unsealed: read at once, at every launch.
    private(set) var manifest: StoreManifest
    /// Whether the store is open: the session's cache key was given, and the sealed parts read.
    private(set) var isOpen = false
    /// The last state the Mac sent. Empty while closed.
    @ObservationIgnored private(set) var cache = StateCache()
    /// What the person wrote that the Mac has not taken, oldest first. Empty while closed.
    private(set) var outbox: [OutboxItem] = []
    /// Why the store was last wiped, while this launch lasts, for a screen that says so.
    private(set) var lastWipe: Wipe?

    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private var pendingCache: Task<Void, Never>?
    @ObservationIgnored private var cacheDirty = false

    /// Reads the manifest and brings the folder to this build's version, or wipes what it cannot read. Needs no key.
    init(folder: StoreFolder = .standard, now: @escaping @MainActor () -> Date = { Date() }) {
        self.folder = folder
        self.now = now
        let found = StoreManifest.read(folder)
        manifest = found ?? StoreManifest()
        switch StoreMigrations.plan(found, folder: folder) {
        case .fresh, .upToDate:
            break
        case .migrate(let version):
            do {
                try StoreMigrations.migrate(folder, from: version)
                manifest.version = StoreMigrations.current
                try manifest.write(folder)
            } catch {
                wipe(.unreadable, because: error.localizedDescription)
            }
        case .discard(let why):
            wipe(.unreadable, because: why)
        }
    }

    // MARK: - Dates

    /// When the phone last heard from its Mac: the date beside the last state.
    var lastHeard: Date? { manifest.lastHeard }

    /// The Mac was heard from at `date`: any line from it, on any path. Kept with the next write of the cache. Only in
    /// an open session, the only time the phone hears from its Mac (every channel attaches under Face ID, 4.3).
    func heard(at date: Date? = nil) {
        guard isOpen else { return }
        let date = date ?? now()
        if (manifest.lastHeard ?? .distantPast) < date { manifest.lastHeard = date }
        cacheDirty = true
        scheduleCache()
    }

    /// Wipes what has gone seven days without the Mac: the cache once the Mac has not been heard from for seven days,
    /// and the Outbox once it has not changed for seven days. Needs no key, so the session's owner calls it at every
    /// launch and every return to the foreground, before Face ID. Returns what it wiped.
    @discardableResult
    func sweep() -> Set<StorePart> {
        let limit = now().addingTimeInterval(-Self.keptWithoutMac)
        let hasCache = folder.has(Self.cacheFile) || !cache.isEmpty
        let hasOutbox = folder.has(Self.outboxFile) || !outbox.isEmpty
        var wiped: Set<StorePart> = []
        // A part with no date was never written by a session that heard the Mac: it has nothing to wait for.
        if hasCache, (manifest.lastHeard ?? .distantPast) < limit { wiped.insert(.cache) }
        if hasOutbox, (manifest.outboxChangedAt ?? .distantPast) < limit { wiped.insert(.outbox) }
        guard !wiped.isEmpty else { return [] }
        if (!hasCache || wiped.contains(.cache)) && (!hasOutbox || wiped.contains(.outbox)) {
            // Nothing would be left: the whole store goes, its folder too.
            wipe(.expired)
            return wiped
        }
        if wiped.contains(.cache) {
            cache = StateCache()
            cacheDirty = false
            try? folder.remove(Self.cacheFile)
            manifest.shownState = nil
            try? manifest.write(folder)
            log.notice("The cache was wiped: seven days without the Mac.")
        }
        if wiped.contains(.outbox) {
            outbox = []
            try? folder.remove(Self.outboxFile)
            manifest.outboxChangedAt = nil
            try? manifest.write(folder)
            log.notice("The Outbox was wiped: seven days untouched.")
        }
        return wiped
    }

    // MARK: - Opening

    /// What opening found.
    struct Opened: Equatable, Sendable {
        /// Parts that could not be read with this key, and were wiped.
        var unreadable: Set<StorePart> = []
    }

    /// Opens the store with the session's cache key: reads the cache and the Outbox. A part sealed with another key
    /// (the cache key is made anew when Face ID is enrolled again) cannot be read and is wiped, and said so.
    @discardableResult
    func open(key: SymmetricKey) -> Opened {
        sweep()
        self.key = key
        isOpen = true
        var opened = Opened()
        if let data = folder.read(Self.cacheFile) {
            do {
                cache = try Self.decoder.decode(StateCache.self, from: StoreSeal.open(data, part: StorePart.cache.rawValue, version: manifest.version, key: key))
                cache.prune(at: now())
            } catch {
                opened.unreadable.insert(.cache)
                cache = StateCache()
                try? folder.remove(Self.cacheFile)
                manifest.shownState = nil
            }
        }
        if let data = folder.read(Self.outboxFile) {
            do {
                outbox = try Self.decoder.decode([OutboxItem].self, from: StoreSeal.open(data, part: StorePart.outbox.rawValue, version: manifest.version, key: key))
            } catch {
                opened.unreadable.insert(.outbox)
                outbox = []
                try? folder.remove(Self.outboxFile)
                manifest.outboxChangedAt = nil
            }
        }
        if !opened.unreadable.isEmpty {
            lastWipe = .unreadable
            try? manifest.write(folder)
            log.notice("Parts of the store could not be opened with this cache key and were wiped: \(opened.unreadable.map(\.rawValue).sorted().joined(separator: ", "), privacy: .public)")
        }
        return opened
    }

    /// Ends the session's hold on the store: writes what waits, then forgets the key and everything read with it.
    func close() {
        saveNow()
        key = nil
        isOpen = false
        cache = StateCache()
        outbox = []
    }

    // MARK: - The cache

    /// Takes the engine's lines (whole lines, each ending with a line break, or several) as the Mac sent them.
    func take(lines: Data) {
        let date = now()
        if isOpen {
            for line in lines.split(separator: 0x0A, omittingEmptySubsequences: true) {
                cache.take(Data(line), at: date)
            }
        }
        heard(at: date)
    }

    /// A state's number from the Mac (5.3): true when it is newer than any shown, or the same, and so may be shown;
    /// false when it is older, and must be refused.
    func takeState(number: Int64) -> Bool {
        guard isOpen else { return false }
        if let shown = manifest.shownState, number < shown { return false }
        if manifest.shownState != number {
            manifest.shownState = number
            try? manifest.write(folder)
        }
        return true
    }

    // MARK: - The Outbox's storage (Outbox/ decides what goes in it)

    /// Replaces the Outbox and writes it at once: what the person wrote is never left to a timer.
    func setOutbox(_ items: [OutboxItem]) throws {
        guard let key else { throw StoreError("Open pi² with Face ID first.") }
        let data = try StoreSeal.seal(Self.encoder.encode(items), part: StorePart.outbox.rawValue, version: manifest.version, key: key)
        if items.isEmpty {
            try folder.remove(Self.outboxFile)
        } else {
            try folder.write(data, as: Self.outboxFile)
        }
        outbox = items
        manifest.outboxChangedAt = now()
        try manifest.write(folder)
    }

    // MARK: - Writing

    /// Writes the cache and the manifest now, if they changed: when the app leaves the foreground, and before the
    /// session closes.
    func saveNow() {
        pendingCache?.cancel()
        pendingCache = nil
        guard cacheDirty else { return }
        cacheDirty = false
        do {
            if let key, isOpen, !cache.isEmpty {
                let data = try StoreSeal.seal(Self.encoder.encode(cache), part: StorePart.cache.rawValue, version: manifest.version, key: key)
                try folder.write(data, as: Self.cacheFile)
            }
            try manifest.write(folder)
        } catch {
            log.error("The store could not write the cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleCache() {
        guard pendingCache == nil else { return }
        pendingCache = Task { [weak self] in
            try? await Task.sleep(for: Self.cacheDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingCache = nil
            self.saveNow()
        }
    }

    // MARK: - Wiping

    /// Wipes the store: every file of it, the folder itself, and what was read into memory, in one call. Returns the
    /// Outbox's items that had not been taken, so that a revocation can show what was not sent before it is gone (3.6):
    /// they are no longer on disk, only in what this returns. Unpaired or revoked, the store is also closed, so nothing
    /// more is written for the pairing; otherwise a session that had it open keeps it open, empty.
    @discardableResult
    func wipe(_ reason: Wipe) -> [OutboxItem] {
        wipe(reason, because: nil)
    }

    @discardableResult
    private func wipe(_ reason: Wipe, because why: String?) -> [OutboxItem] {
        let unsent = outbox
        if reason == .revoked || reason == .unpaired {
            // Nothing more is kept for this pairing, even if a line still comes.
            key = nil
            isOpen = false
        }
        pendingCache?.cancel()
        pendingCache = nil
        cacheDirty = false
        cache = StateCache()
        outbox = []
        manifest = StoreManifest()
        lastWipe = reason
        do {
            try folder.remove()
        } catch {
            // Each file, then, so that what can go goes.
            for name in folder.names() { try? folder.remove(name) }
            try? folder.remove()
            log.error("The store's folder could not be removed whole: \(error.localizedDescription, privacy: .public)")
        }
        log.notice("The store was wiped (\(reason.rawValue, privacy: .public))\(why.map { ": \($0)" } ?? "", privacy: .public)")
        return unsent
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

/// The store's sealed parts.
enum StorePart: String, CaseIterable, Sendable {
    case cache
    case outbox
}
