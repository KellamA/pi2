import Foundation

/// The store's versions, and how a store of an older one is brought up to this build's.
///
/// Version 1 is the first: the manifest, the sealed cache and the sealed Outbox. Each later version adds one step to
/// `steps`, from the version before it, and raises `current`. What the store keeps is a copy of what the Mac holds, and
/// what the person wrote while it was away, so a store this build cannot read is never guessed at: it is wiped, as
/// one written by a newer build (after the app was put back to an older one) is, and the Mac sends its state again.
enum StoreMigrations {
    static let current = 1

    /// What to do with the folder as it was found.
    enum Plan: Equatable {
        /// Nothing there: start a new store.
        case fresh
        /// Written by this version.
        case upToDate
        /// Written by an older version: these steps, in order, then it is this version's.
        case migrate(from: Int)
        /// Not a store this build can read: wipe it, with why.
        case discard(String)
    }

    /// One step from version `n` to `n + 1`, by `n`. Each is given the folder, and may read and write what it holds
    /// unsealed; a step that needs the sealed parts runs when the store is next opened with its key.
    static let steps: [Int: @Sendable (StoreFolder) throws -> Void] = [:]

    static func plan(_ manifest: StoreManifest?, folder: StoreFolder) -> Plan {
        guard let manifest else {
            return folder.names().isEmpty ? .fresh : .discard("The store has no manifest it can read.")
        }
        if manifest.version == current { return .upToDate }
        if manifest.version > current { return .discard("The store was written by a newer build (version \(manifest.version)).") }
        guard manifest.version >= 1, (manifest.version..<current).allSatisfy({ steps[$0] != nil }) else {
            return .discard("The store's version \(manifest.version) has no way to this build's \(current).")
        }
        return .migrate(from: manifest.version)
    }

    /// Runs the steps from `version` to `current` on the folder.
    static func migrate(_ folder: StoreFolder, from version: Int) throws {
        for step in version..<current {
            guard let run = steps[step] else { throw StoreError("No step from the store's version \(step).") }
            try run(folder)
        }
    }
}
