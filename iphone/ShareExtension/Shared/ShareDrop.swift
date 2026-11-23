import Foundation

/// The folder the share extension and the app hand things to each other in: `Share/` in the app group's shared
/// container (docs/iphone-app.md, "The extensions"). The app writes the list of where a share can go
/// (`destinations.json`); the extension writes each message it makes as a draft (`Drafts/<id>.json`), which the app
/// sends (`SharePickup`). The extension also keeps which destination was chosen last (`last.json`).
///
/// - **Protected**: every file is written whole (`atomic`) with `NSFileProtectionComplete`, readable only while the
///   phone is unlocked, as the share sheet and the app in front both are; and out of backups.
/// - **Not sealed**: neither the extension nor the app's background can read the cache key, so what is here is kept as
///   the store keeps its files, without the store's seal: names of projects and conversations, and what the person
///   shared, until the app has sent it.
/// - **Wiped with the store**: the app removes the folder whole whenever the store is wiped (`wipe()`).
///
/// An unsigned build has no app group (no entitlement reaches it), so `inAppGroup()` is nil there; the extension then
/// says the Mac's projects are not known yet. A test gives the folder itself.
struct ShareDrop: Sendable, Equatable {
    /// The app group the app and its extensions share. Not made yet: #682 makes it, with the entitlements of the app,
    /// the share extension, the widgets and the notification service, and the contract names it.
    static let appGroup = "group.dev.pi2.ios"

    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    /// The folder in the app group's container, or nil without one (an unsigned build).
    static func inAppGroup(_ manager: FileManager = .default) -> ShareDrop? {
        manager.containerURL(forSecurityApplicationGroupIdentifier: appGroup).map {
            ShareDrop(folder: $0.appending(path: "Share", directoryHint: .isDirectory))
        }
    }

    static let options: Data.WritingOptions = [.atomic, .completeFileProtection]
    private var drafts: URL { folder.appending(path: "Drafts", directoryHint: .isDirectory) }
    private var destinationsFile: URL { folder.appending(path: "destinations.json", directoryHint: .notDirectory) }
    private var lastFile: URL { folder.appending(path: "last.json", directoryHint: .notDirectory) }

    // MARK: - Where a share can go

    /// Writes the list, replacing the last one. The app's to call.
    func writeDestinations(_ destinations: ShareDestinations) throws {
        try write(try Self.encoder.encode(destinations), to: destinationsFile)
    }

    /// The list the app last wrote, if there is one it wrote within the last seven days.
    func destinations(at date: Date) -> ShareDestinations? {
        guard let data = try? Data(contentsOf: destinationsFile),
              let list = try? Self.decoder.decode(ShareDestinations.self, from: data), list.isFresh(at: date) else { return nil }
        return list
    }

    /// The conversation a share went to last, to choose again.
    var lastConversation: Int? {
        guard let data = try? Data(contentsOf: lastFile) else { return nil }
        return try? Self.decoder.decode(Int.self, from: data)
    }

    func rememberLast(_ conversation: Int) {
        try? write(try Self.encoder.encode(conversation), to: lastFile)
    }

    // MARK: - Drafts

    /// Keeps a new draft for the app, or says why not, in the person's words.
    func add(_ draft: ShareDraft) throws {
        guard all().filter({ $0.state == .waiting }).count < ShareLimits.drafts else {
            throw ShareError("pi² already holds \(ShareLimits.drafts) shares waiting to go to your Mac. Open pi² so it can send them, then share this again.")
        }
        do {
            try write(draft)
        } catch {
            throw ShareError("This could not be kept for pi² to send: \(error.localizedDescription)")
        }
    }

    /// Writes a draft, replacing the one with its id.
    func write(_ draft: ShareDraft) throws {
        try write(try Self.encoder.encode(draft), to: file(draft.id))
    }

    /// Every draft, oldest first; a file that cannot be read (half written, or the phone locked) is passed over.
    func all() -> [ShareDraft] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: drafts.path)) ?? []
        return names.compactMap { name -> ShareDraft? in
            guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil,
                  let data = try? Data(contentsOf: drafts.appending(path: name, directoryHint: .notDirectory)) else { return nil }
            return try? Self.decoder.decode(ShareDraft.self, from: data)
        }
        .sorted { ($0.writtenAt, $0.id) < ($1.writtenAt, $1.id) }
    }

    /// The drafts not sent, with why: for the app to show until the person dismisses them.
    var notSent: [ShareDraft] {
        all().filter { $0.state != .waiting }
    }

    func remove(_ id: String) {
        guard UUID(uuidString: id) != nil else { return }
        try? FileManager.default.removeItem(at: file(id))
    }

    /// Removes the folder whole: what the app calls whenever the phone's store is wiped.
    func wipe() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ id: String) -> URL {
        drafts.appending(path: "\(id).json", directoryHint: .notDirectory)
    }

    // MARK: - Files

    private func write(_ data: Data, to file: URL) throws {
        let manager = FileManager.default
        let parent = file.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        try data.write(to: file, options: Self.options)
        for url in [folder, parent, file] {
            var url = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    // Dates as JSONEncoder writes them by default, which read back exactly.
    private static var encoder: JSONEncoder { JSONEncoder() }
    private static var decoder: JSONDecoder { JSONDecoder() }
}

/// Why something could not be shared, in the person's words.
struct ShareError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
