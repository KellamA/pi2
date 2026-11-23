import Foundation

/// What the store keeps unsealed, beside its sealed parts: its version, and the dates and the number it must read
/// without the cache key. The seven days without the Mac (docs/iphone.md 3.6) are counted from `lastHeard` at every
/// launch, Face ID or not, so the wipe does not wait for the person to open pi². It holds no text of the person's or
/// the Mac's: dates and a number. It is protected and out of backups as every file of the store is (`StoreFolder`).
struct StoreManifest: Codable, Equatable, Sendable {
    static let file = "manifest.json"

    /// The store's version, which `StoreMigrations` reads first.
    var version: Int
    /// When the phone last heard from its Mac: any line from it, on any path.
    var lastHeard: Date?
    /// When the Outbox last changed, so that an Outbox untouched for seven days goes with the cache, without its key.
    var outboxChangedAt: Date?
    /// The highest number of a Mac's state the phone has shown (5.3, RemoteKit's `StateNumbers.shown`): a state with a
    /// lower one is refused, so a relay cannot hand back an old one, after a restart too.
    var shownState: Int64?

    init(version: Int = StoreMigrations.current, lastHeard: Date? = nil, outboxChangedAt: Date? = nil, shownState: Int64? = nil) {
        self.version = version
        self.lastHeard = lastHeard
        self.outboxChangedAt = outboxChangedAt
        self.shownState = shownState
    }

    static func read(_ folder: StoreFolder) -> StoreManifest? {
        guard let data = folder.read(file) else { return nil }
        return try? decoder.decode(StoreManifest.self, from: data)
    }

    func write(_ folder: StoreFolder) throws {
        try folder.write(try Self.encoder.encode(self), as: Self.file)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
