#if PI2_DEVELOPMENT
import BrowserKit
import Foundation

/// One answer, held by the running app (never carried over to a reopened copy).
@MainActor
enum TestCopyPanels {
    private static var location: (home: URL, checkout: URL)?
    private static var next: [String]?

    static func install(engine: EngineClient) {
        guard let copy = TestCopyControl.location(engine: engine) else { return }
        location = copy
        FilePanels.testAnswer = answer
    }

    /// A missing leaf might be a valid Save destination. Check the actual panel's rules when it opens.
    static func choose(_ paths: [String]) -> [String: String] {
        guard paths.allSatisfy({ checked($0, allowNewFile: true) != nil }) else {
            return ["error": "use a path in the copy's data folder, the conversation's scratch folder, or this checkout's app/build, with an existing parent and no symlinks or '..' components"]
        }
        next = paths
        return ["result": paths.isEmpty ? "Armed the next panel to cancel" : "Armed the next panel with \(paths.count) path(s)"]
    }

    private static func answer(_ name: String, _ kind: FilePanels.Kind) -> [URL] {
        let pending = next
        next = nil
        var urls: [URL] = []
        var reason = pending == nil ? "unarmed" : "explicit"
        if let pending, !pending.isEmpty {
            reason = "invalid"
            switch kind {
            case .open(let selection, let multiple):
                let matches = pending.compactMap { path -> URL? in
                    guard let url = checked(path, allowNewFile: false) else { return nil }
                    // An app bundle, for example, is treated as a file by AppKit.
                    let directory = url.hasDirectoryPath && (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
                    guard directory ? selection != .files : selection != .folders else { return nil }
                    return url
                }
                if matches.count == pending.count, multiple || matches.count == 1 { urls = matches }
            case .save:
                if pending.count == 1, let url = checked(pending[0], allowNewFile: true), !url.hasDirectoryPath { urls = [url] }
            }
        }
        var record: [String: Any] = ["panel": name, "paths": urls.map(\.path), "result": urls.isEmpty ? "cancelled" : "chosen"]
        if urls.isEmpty { record["reason"] = reason }
        if let home = location?.home { append(record, at: home) }
        return urls
    }

    /// Get the path spelling without querying anything outside a known root. macOS's `/tmp` is `/private/tmp`.
    private static func absolute(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        let parts = path.split(separator: "/").filter { $0 != "." }
        guard !parts.contains("..") else { return nil }
        let clean = "/" + parts.joined(separator: "/")
        return clean.hasPrefix("/tmp/") ? "/private" + clean : clean
    }

    private static func checked(_ input: String, allowNewFile: Bool) -> URL? {
        guard let location, let path = absolute(input) else { return nil }
        let support = location.home.deletingLastPathComponent().path
        let checkout = location.checkout.path
        // The trusted prefixes are the bundle's checkout, the app's Application Support and macOS's private tmp.
        // Inspect each component below them without following a link, even if its target would be allowed.
        if let url = walk(path, below: support, through: [location.home.lastPathComponent], allowNewFile: allowNewFile) { return url }
        if let url = walk(path, below: checkout, through: ["app", "build"], allowNewFile: allowNewFile) { return url }
        let uid = getuid()
        let base = "pi2-\(uid)"
        guard let value = ProcessInfo.processInfo.environment["PI2_TEST_COPY_SCRATCH"], let scratch = absolute(value),
              scratch.range(of: #"^/private/tmp/"# + base + #"/scratch-[0-9a-f]{8}/[1-9][0-9]*$"#, options: .regularExpression) != nil else { return nil }
        let parts = scratch.split(separator: "/").dropFirst(2).map(String.init)
        return walk(path, below: "/private/tmp", through: parts, allowNewFile: allowNewFile, privateTo: uid)
    }

    private static func walk(_ path: String, below prefix: String, through directories: [String],
                             allowNewFile: Bool, privateTo uid: uid_t? = nil) -> URL? {
        let root = prefix + "/" + directories.joined(separator: "/")
        guard path == root || path.hasPrefix(root + "/") else { return nil }
        let rest = path.dropFirst(root.count).split(separator: "/").map(String.init)
        let components = directories + rest
        var current = prefix
        for (index, name) in components.enumerated() {
            current += "/" + name
            let last = index == components.count - 1
            let inRoot = index < directories.count
            var info = stat()
            if lstat(current, &info) != 0 {
                guard allowNewFile, last, !inRoot, errno == ENOENT else { return nil }
                return URL(fileURLWithPath: current, isDirectory: false)
            }
            let type = info.st_mode & S_IFMT
            if inRoot, let uid, info.st_uid != uid || info.st_mode & 0o077 != 0 { return nil }
            if type == S_IFDIR {
                if last { return URL(fileURLWithPath: current, isDirectory: true) }
            } else {
                guard type == S_IFREG, last, !inRoot else { return nil }
                return URL(fileURLWithPath: current, isDirectory: false)
            }
        }
        return nil
    }

    /// A fixture in the data folder must not redirect the log to a file outside the copy.
    private static func append(_ record: [String: Any], at home: URL) {
        guard var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        var info = stat()
        guard lstat(home.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
        let log = home.appendingPathComponent("file-panels.jsonl").path
        let fd = open(log, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return }
        line.append(UInt8(ascii: "\n"))
        try? handle.write(contentsOf: line)
    }
}
#endif
