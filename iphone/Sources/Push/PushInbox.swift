import Foundation

/// The service extension's own small file (docs/iphone.md 3.6, section 7): every notice it showed, kept for the app to
/// merge into its store when the phone is unlocked, since the extension runs while the phone may be locked and never
/// writes the store. One file for each notice, each made with `completeUnlessOpen`: a file of that class can be made
/// while the phone is locked but not opened again until it is unlocked, so the extension never appends to one. Out of
/// backups, as everything the phone keeps (3.6).
///
/// It lives in the app group's container, which the app and the extension share: none until #682 gives them the app
/// group, so an unsigned build keeps nothing (`shared` is nil) and the tests give a folder of their own.
struct PushInbox: Sendable {
    /// The app group the app and the service extension share; nil until #682 makes it.
    static let appGroup: String? = nil
    /// The most notices kept at once: past it a new one is not kept (the mailbox holds the need anyway, 5.3).
    static let limit = 200

    let folder: URL

    /// The extension's file in the app group's container, or nil without one.
    static var shared: PushInbox? {
        guard let group = appGroup,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return PushInbox(folder: container.appending(path: "Push", directoryHint: .isDirectory))
    }

    /// What is kept of a notice: what it showed, and what the store needs to find its card.
    struct Entry: Codable, Equatable, Sendable {
        let item: String
        let at: Int64
        let kind: String?
        let title: String
        let body: String
        let whole: Bool
        let need: String?
        let projectId: String?
        let conversationId: Int?

        init(_ notice: PushNotice) {
            item = notice.id
            at = notice.at
            kind = notice.kind?.rawValue
            title = notice.title
            body = notice.body
            whole = notice.whole
            need = notice.need
            projectId = notice.projectId
            conversationId = notice.conversationId
        }
    }

    /// Keeps a notice, in a file of its own named after its item's id. The same item twice is kept once.
    func keep(_ notice: PushNotice) throws {
        // The id names the file, so it must be an item's id as RemoteKit writes it, and nothing that could name another.
        guard (1...64).contains(notice.id.count), PushBase64URL.decode(notice.id) != nil else { return }
        let manager = FileManager.default
        if !manager.fileExists(atPath: folder.path) {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
            var url = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        }
        guard try manager.contentsOfDirectory(atPath: folder.path).count < Self.limit else { return }
        let file = folder.appending(path: "\(notice.id).json")
        do {
            try JSONEncoder().encode(Entry(notice)).write(to: file, options: [.withoutOverwriting, .completeFileProtectionUnlessOpen])
        } catch CocoaError.fileWriteFileExists {
            return
        }
    }

    /// Every notice kept, oldest first, each removed once read: for the app to merge into its store, unlocked.
    func take() throws -> [Entry] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.path) else { return [] }
        var entries: [Entry] = []
        for name in try manager.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".json") {
            let file = folder.appending(path: name)
            if let entry = try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: file)) { entries.append(entry) }
            try manager.removeItem(at: file)
        }
        return entries.sorted { ($0.at, $0.item) < ($1.at, $1.item) }
    }

    /// Removes everything kept: on unpairing and on a revocation (3.6).
    func wipe() throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }
}
