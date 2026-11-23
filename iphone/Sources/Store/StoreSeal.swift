import CryptoKit
import Foundation

/// How the store's secret parts are sealed on disk: AES-256-GCM with the cache key (docs/iphone.md 3.2), which `Keys/`
/// keeps in the Keychain with `biometryCurrentSet` and reads only under the authentication context Face ID evaluated
/// for the session (4.5). So the cache and the Outbox open only in a session Face ID opened, and a thief with the
/// passcode reads nothing. The authenticated data names the part and the store's version, so one sealed file cannot be
/// put in another's place, nor read by a store of another version as if it were its own.
enum StoreSeal {
    static func seal(_ data: Data, part: String, version: Int, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(data, using: key, authenticating: label(part, version))
        guard let combined = box.combined else { throw StoreError("The store could not seal its \(part).") }
        return combined
    }

    static func open(_ data: Data, part: String, version: Int, key: SymmetricKey) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: label(part, version))
        } catch {
            throw StoreError("The store's \(part) cannot be opened with this cache key.")
        }
    }

    private static func label(_ part: String, _ version: Int) -> Data {
        Data("pi2-store-v\(version)/\(part)".utf8)
    }
}

struct StoreError: LocalizedError, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
