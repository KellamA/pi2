import Foundation
import os

/// The widgets' file (docs/iphone-app.md, "The extensions"): one `WidgetsSnapshot` as JSON, which the app writes and
/// the widgets extension reads, in the app group both share. It is not the phone's store, which stays the app's alone.
///
/// - **Where**: `Library/Application Support/Widgets/widgets.json` in the app group's container (`appGroup`). An
///   unsigned build has no app group (no entitlement reaches it), so `standard` has no folder there: the app writes
///   nothing, and the widgets draw what they draw with no snapshot, which says to open pi².
/// - **Protected** until the phone is first unlocked after starting (`completeUntilFirstUserAuthentication`), so that a
///   widget on the Lock Screen can still be drawn, its content marked `privacySensitive`; out of backups.
/// - **Not drawn** once it is older than `WidgetsSnapshot.keptFor`, of another version, or unreadable.
struct WidgetsFile: Sendable {
    /// The app group the app and its extensions share. #682 (the owner's) makes it, with an entitlements file for the app
    /// and for the widgets extension that names it; docs/iphone.md does not name it yet, and this is the name proposed.
    static let appGroup = "group.dev.pi2.ios"
    static let name = "widgets.json"

    /// The folder the file is in; nil when there is none, as in an unsigned build.
    let folder: URL?

    init(folder: URL?) {
        self.folder = folder
    }

    /// The file in the app group's container, or none when this build has no app group.
    static var standard: WidgetsFile {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        return WidgetsFile(folder: container?.appending(path: "Library/Application Support/Widgets", directoryHint: .isDirectory))
    }

    var url: URL? { folder?.appending(path: Self.name, directoryHint: .notDirectory) }

    private static let log = Logger(subsystem: "dev.pi2.ios", category: "widgets")

    /// The snapshot to draw at `now`, or nil: no folder, no file, unreadable, of another version, or too old.
    func read(now: Date = Date()) -> WidgetsSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let snapshot = try? decoder.decode(WidgetsSnapshot.self, from: data),
              snapshot.version == WidgetsSnapshot.currentVersion,
              now.timeIntervalSince(snapshot.heardAt) <= WidgetsSnapshot.keptFor else { return nil }
        return snapshot
    }

    /// Writes the snapshot in one step, so that a widget never reads half of one. Does nothing without a folder.
    func write(_ snapshot: WidgetsSnapshot) throws {
        guard let folder, var url else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Removes the file, when the store is wiped or the phone is unpaired. Nothing there is not a failure.
    func remove() {
        guard let url else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            Self.log.error("The widgets' file could not be removed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
