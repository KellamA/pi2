import CryptoKit
import Foundation

/// Where the engine's socket is reached: `engine.sock` in the data folder.
///
/// macOS limits a Unix socket's path to 103 bytes, and Network traps on a longer one. So for a data folder with a long
/// path (only possible with PI2_HOME) the socket is reached through a short link to the folder instead:
/// `/tmp/pi2-<uid>/<first 16 hex digits of the SHA-256 of the folder's path>`, the path resolved and in Unicode NFC.
/// The socket file itself stays in the data folder. The engine works out the same path in engine/src/socket.ts; keep
/// the two in step.
enum EngineSocket {
    /// The longest socket path macOS accepts: `sun_path` holds 104 bytes, including the closing zero.
    static let maxPathLength = 103

    /// The path to connect to for the engine whose data folder is `home`. Makes the short link if needed.
    static func path(for home: URL, linkRoot: String = "/tmp/pi2-\(getuid())") throws -> String {
        // Composed (NFC), as the engine has it: URL gives decomposed accents, and the hash is of the exact bytes.
        let folder = resolved(home.path).precomposedStringWithCanonicalMapping
        let direct = (folder as NSString).appendingPathComponent("engine.sock")
        if direct.utf8.count <= maxPathLength { return direct }
        let digest = SHA256.hash(data: Data(folder.utf8)).map { String(format: "%02x", $0) }.joined()
        let link = (linkRoot as NSString).appendingPathComponent(String(digest.prefix(16)))
        let short = (link as NSString).appendingPathComponent("engine.sock")
        guard short.utf8.count <= maxPathLength else { throw failure("The socket path is too long, even through \(link).") }

        // The links live in a folder only this user can write to, so nobody else can point one at their own engine.
        mkdir(linkRoot, 0o700)
        var root = stat()
        guard lstat(linkRoot, &root) == 0, root.st_mode & S_IFMT == S_IFDIR, root.st_uid == getuid(), root.st_mode & 0o077 == 0 else {
            throw failure("\(linkRoot) must be a folder of this user's that nobody else can open.")
        }
        if target(of: link) != folder {
            // The app and the engine may both make it at once; whichever is second finds the right link already there.
            unlink(link)
            if symlink(folder, link) != 0 {
                let code = errno
                if !(code == EEXIST && target(of: link) == folder) {
                    throw failure("Could not link \(link) to the data folder: \(String(cString: strerror(code))).")
                }
            }
        }
        return short
    }

    /// The path with `.`, `..` and repeated or trailing slashes taken out, as Node's `path.resolve` gives it. Not
    /// `standardizedFileURL`, which also drops a leading `/private` and so would name a different link.
    static func resolved(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func target(of link: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: link)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "pi2.EngineSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
