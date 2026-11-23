import Foundation

/// The one folder the phone's store keeps its files in (docs/iphone.md 3.6), inside the app's own container, and how
/// each file is kept there:
///
/// - **`NSFileProtectionComplete`**: the folder carries it, so that anything made in it inherits it, and every file is
///   written with it too (`.completeFileProtection`), so a file is readable only while the phone is unlocked. The
///   simulator does not enforce file protection: there the attribute is set and reads back, and nothing more.
/// - **Out of backups**: the folder is marked `isExcludedFromBackup`, which iOS applies to all it holds, and each file is
///   marked as well, so that neither an iCloud backup nor a computer's holds the cache or the Outbox.
/// - **Nothing outside it**: every write is atomic within the folder, and wiping removes the folder whole.
///
/// It holds no key: what is secret in the store is sealed with the cache key (`StoreSeal`), which `Keys/` keeps.
struct StoreFolder: Sendable, Equatable {
    let url: URL

    /// The protection class of the folder and of every file in it.
    static let protection = FileProtectionType.complete
    /// How every file is written: whole or not at all, with that protection class.
    static let fileOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    init(_ url: URL) {
        self.url = url
    }

    /// `Library/Application Support/Store` in the app's container: the store's place in the app.
    static var standard: StoreFolder {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StoreFolder(support.appending(path: "Store", directoryHint: .isDirectory))
    }

    var exists: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// Makes the folder if it is not there, and marks it protected and out of backups.
    func prepare() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: Self.protection])
        try manager.setAttributes([.protectionKey: Self.protection], ofItemAtPath: url.path)
        try Self.excludeFromBackup(url)
    }

    /// Writes `data` as the file `name`, replacing it whole, protected and out of backups.
    func write(_ data: Data, as name: String) throws {
        try prepare()
        let file = url.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: file, options: Self.fileOptions)
        try Self.excludeFromBackup(file)
    }

    /// The file `name`, or nil when it is not there or cannot be read (the phone is locked, say).
    func read(_ name: String) -> Data? {
        try? Data(contentsOf: url.appending(path: name, directoryHint: .notDirectory))
    }

    func has(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: name, directoryHint: .notDirectory).path)
    }

    func remove(_ name: String) throws {
        let file = url.appending(path: name, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// The names of what the folder holds, sorted; empty when there is no folder.
    func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    /// Removes the folder and everything in it.
    func remove() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try url.setResourceValues(values)
    }
}
