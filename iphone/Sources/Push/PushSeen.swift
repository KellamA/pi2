
import Foundation

/// The pushes the phone has opened in the last 25 hours, by their item's id (docs/iphone.md section 7, #689), so that one
/// handed back (by the relay, or by anyone who recorded it on its way) is not shown again as the Mac wrote it. A push
/// older than a day is refused anyway (`PushItem.oldest`), and so is one dated more than an hour ahead of the phone's
/// clock (`PushItem.newest`), so 25 hours covers every copy that could still pass, as RemoteKit's `RelayItemMemory`
/// does for the mailbox.
///
/// One empty file for each id, in the app group's container, made with `completeUntilFirstUserAuthentication`: the
/// service extension runs while the phone is locked, and making a file and finding one by its name both work then, so
/// the memory needs no file opened again. Only an id that opened, verified and was read is remembered
/// (`PushDelivery.item`), so pushes made up by someone else cannot fill it; at its bound it takes no more until some
/// are old, and an id it could not keep is only not guarded against a repeat. None without the app group (an unsigned
/// build, the simulator): nothing is remembered there, and the tests give a folder of their own.
struct PushSeen: Sendable {
    /// How long an id is kept.
    static let keptFor: TimeInterval = 25 * 60 * 60
    /// The most ids kept: far more than the engine pushes a device in a day (100 alerts and 50 background pushes an hour).
    static let most = 5_000

    let folder: URL

    static var shared: PushSeen? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PushInbox.appGroup) else { return nil }
        return PushSeen(folder: container.appending(path: "PushSeen", directoryHint: .isDirectory))
    }

    /// Whether the push `id` is opened here for the first time, remembering it if so. False only for an id remembered in
    /// the last 25 hours: a memory that cannot be read or written guards nothing, and refuses nothing.
    func firstTime(_ id: String, now: Date) -> Bool {
        // The id names the file: it must be an item's id as RemoteKit writes it (16 bytes, base64url), nothing else.
        guard id.utf8.count == 22, let bytes = PushBase64URL.decode(id), bytes.count == 16 else { return true }
        let manager = FileManager.default
        let file = folder.appending(path: id)
        if let made = try? manager.attributesOfItem(atPath: file.path)[.modificationDate] as? Date {
            if now.timeIntervalSince(made) < Self.keptFor { return false }
            try? manager.removeItem(at: file)
        }
        do {
            if !manager.fileExists(atPath: folder.path) {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                var url = folder
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            }
            var names = try manager.contentsOfDirectory(atPath: folder.path)
            // What is old goes first; then, at the bound, nothing more is taken.
            for name in names {
                let old = folder.appending(path: name)
                if let made = try? manager.attributesOfItem(atPath: old.path)[.modificationDate] as? Date, now.timeIntervalSince(made) >= Self.keptFor {
                    try? manager.removeItem(at: old)
                }
            }
            names = try manager.contentsOfDirectory(atPath: folder.path)
            guard names.count < Self.most else { return true }
            try Data().write(to: file, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            try manager.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        } catch CocoaError.fileWriteFileExists {
            return false
        } catch {
            return true
        }
        return true
    }
}
