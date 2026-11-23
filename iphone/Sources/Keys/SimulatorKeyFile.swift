#if targetEnvironment(simulator)
import Foundation
import LocalAuthentication
import Security
import os

/// Where the simulator keeps the phone's items when its Keychain refuses them. An unsigned simulator build has no
/// application identifier, and every Keychain call then answers errSecMissingEntitlement (-34018), so the keys a debug
/// build makes there in software (docs/iphone.md 10) would last no longer than the process. This keeps them in one
/// file in the app's own container, protected `complete` and kept out of backups, as a development build of the Mac
/// keeps its keys in a file in its data folder (3.2). Compiled only for the simulator: a phone build has no such path.
///
/// What it does not do: an item under Face ID is read only when a context is given, which the session gives only once
/// Face ID passed, but nothing here checks that the context was evaluated, as the Keychain does on a phone.
final class SimulatorKeyFile: KeychainStore, @unchecked Sendable {
    private let url: URL
    private let lock = OSAllocatedUnfairLock()

    init(url: URL) {
        self.url = url
    }

    static var inAppContainer: SimulatorKeyFile {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SimulatorKeyFile(url: folder.appendingPathComponent("simulator-keys.plist"))
    }

    /// The Keychain if it takes this build's items, else this file.
    static func orKeychain() -> any KeychainStore {
        let probe = SecItemCopyMatching(
            [kSecClass as String: kSecClassGenericPassword, kSecMatchLimit as String: kSecMatchLimitOne] as CFDictionary, nil
        )
        return probe == errSecMissingEntitlement ? inAppContainer : SystemKeychain()
    }

    private func load() throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        return try PropertyListDecoder().decode([String: Data].self, from: data)
    }

    private func save(_ items: [String: Data]) throws {
        if items.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListEncoder().encode(items).write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = url
        try marked.setResourceValues(values)
    }

    func write(_ data: Data, as item: KeyItem) throws {
        try lock.withLock {
            var items = try load()
            items[item.rawValue] = data
            try save(items)
        }
    }

    func read(_ item: KeyItem, context: LAContext?) throws -> Data? {
        if item.protection == .whenPasscodeSetUnderFaceID, context == nil { throw KeysError.sessionNotOpen }
        return try lock.withLock { try load()[item.rawValue] }
    }

    func delete(_ item: KeyItem) throws {
        try lock.withLock {
            var items = try load()
            items[item.rawValue] = nil
            try save(items)
        }
    }

    func names() throws -> [String] {
        try lock.withLock { try load().keys.sorted() }
    }

    func deleteEverything() throws {
        try lock.withLock {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}
#endif
