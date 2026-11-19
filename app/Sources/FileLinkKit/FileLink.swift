import Darwin
import Foundation
import UniformTypeIdentifiers

/// A file or folder on this Mac that an agent linked in its answer, or wrote as code (#451): which path it names, what
/// is there once the path is made whole, and what a click and the link's menu do with it.
///
/// The page draws links from their text alone and looks at nothing on disk; everything here happens only when the
/// person clicks or right-clicks one. A path is made whole first (`..`, symbolic links), and on the way it never steps
/// onto a volume that is not this Mac's own (a network share, or an automounted folder such as `/home` or `/net`, which
/// looking inside would mount), so a link can neither show nor mount anything elsewhere. A click shows the file in Finder
/// and never opens it; Open is in the menu only, and only for a file that is not a program, script or application.
public enum FileLink {
    /// The longest target taken, as the page takes it.
    static let longest = 4096

    // MARK: Which path

    /// The absolute path a link's target names, before anything on disk is looked at; nil when it names no file on this
    /// Mac. Taken: an absolute path, `~` or a path starting with `~/`, a `file:` address with no host but `localhost`,
    /// and a relative path when the conversation has a `folder`. The page draws only these as file links, and this
    /// checks them again, since what the page sends is not trusted.
    public static func path(of target: String, folder: String?, home: String) -> String? {
        let text = target.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.utf16.count <= longest,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        if text.lowercased().hasPrefix("file:") {
            return fileAddress(text)
        }
        if text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil || text.hasPrefix("//") { return nil }
        if text == "~" { return home }
        if text.hasPrefix("~/") { return home + text.dropFirst(1) }
        if text.hasPrefix("/") { return text }
        // A fragment, a query, or another person's home folder (~name) is not a path pi² follows.
        if let first = text.first, "#?~".contains(first) { return nil }
        guard let folder, folder.hasPrefix("/") else { return nil }
        return (folder.hasSuffix("/") ? folder : folder + "/") + text
    }

    /// The path of a `file:` address on this Mac: `file:///path` or `file://localhost/path`, percent-escapes decoded.
    private static func fileAddress(_ text: String) -> String? {
        let rest = text.dropFirst("file:".count)
        guard rest.hasPrefix("//") else { return nil }
        let afterSlashes = rest.dropFirst(2)
        let slash = afterSlashes.firstIndex(of: "/") ?? afterSlashes.endIndex
        let host = afterSlashes[..<slash].lowercased()
        guard host.isEmpty || host == "localhost" else { return nil }
        var path = String(afterSlashes[slash...])
        // A query or fragment is not part of the file's name.
        if let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<end]) }
        guard let decoded = path.removingPercentEncoding, decoded.hasPrefix("/"), !decoded.hasPrefix("//"),
              !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        return decoded
    }

    // MARK: What is there

    public enum Kind: String, Equatable, Sendable {
        case file
        /// A folder Finder opens.
        case folder
        /// A folder Finder shows as one item: an application, a document package.
        case package
    }

    public enum Resolution: Equatable, Sendable {
        /// Something is there: the path made whole, and what it is.
        case found(String, Kind)
        /// Nothing is there, or the path cannot be followed (a loop of links, a file where a folder should be). The path
        /// is the one asked for, with `.` and `..` worked out by its text.
        case missing(String)
        /// The path leads onto a network or automounted volume, which pi² does not look into.
        case elsewhere(String)

        /// The path to show the person or put on the pasteboard.
        public var path: String {
            switch self {
            case .found(let path, _), .missing(let path), .elsewhere(let path): return path
            }
        }
    }

    /// The mount points pi² does not step onto: every volume that is not local, and every automounter's folder, under
    /// the names macOS gives them and the names they also have through the data volume's firm links. Read from the
    /// kernel's list as it is (`MNT_NOWAIT`), which asks none of those volumes anything.
    public static func farMounts() -> Set<String> {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        defer { free(buffer) }
        guard count > 0, let buffer else { return [] }
        var far = Set<String>()
        for index in 0..<Int(count) {
            var info = buffer[index]
            let type = cString(&info.f_fstypename)
            guard info.f_flags & UInt32(MNT_LOCAL) == 0 || type == "autofs" else { continue }
            let point = cString(&info.f_mntonname)
            far.insert(point)
            let data = "/System/Volumes/Data"
            if point.hasPrefix(data + "/") { far.insert(String(point.dropFirst(data.count))) } else if point != "/" { far.insert(data + point) }
        }
        return far
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Makes an absolute path whole, one name at a time from `/`, following symbolic links and `..` as the file system
    /// does, and says what is there. It stops before any of `far` (by default, `farMounts()`), never looking at one.
    public static func resolve(_ path: String, far: Set<String>? = nil) -> Resolution {
        guard path.hasPrefix("/") else { return .missing(path) }
        let far = far ?? farMounts()
        let asked = tidy(path)
        var resolved: [String] = []
        var rest: [String] = names(path).reversed()
        var links = 0
        var info = stat()
        while let name = rest.popLast() {
            if name == ".." {
                _ = resolved.popLast()
                continue
            }
            let candidate = "/" + (resolved + [name]).joined(separator: "/")
            if far.contains(candidate) { return .elsewhere(asked) }
            guard lstat(candidate, &info) == 0 else { return .missing(asked) }
            if info.st_mode & S_IFMT == S_IFLNK {
                links += 1
                guard links <= 32, let target = readLink(candidate), !target.isEmpty else { return .missing(asked) }
                if target.hasPrefix("/") { resolved = [] }
                rest.append(contentsOf: names(target).reversed())
                continue
            }
            // Only a folder has anything inside it.
            if !rest.isEmpty, info.st_mode & S_IFMT != S_IFDIR { return .missing(asked) }
            resolved.append(name)
        }
        let whole = "/" + resolved.joined(separator: "/")
        if far.contains(whole) { return .elsewhere(asked) }
        guard lstat(whole, &info) == 0 else { return .missing(asked) }
        // Belt and braces: a volume the list above did not have when it was read.
        var volume = statfs()
        if statfs(whole, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) == 0 { return .elsewhere(asked) }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .found(whole, .file) }
        let package = (try? URL(fileURLWithPath: whole).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        return .found(whole, package ? .package : .folder)
    }

    /// A path's names, without the empty ones and `.`.
    private static func names(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
    }

    /// An absolute path with `.` and `..` worked out by its text alone, for saying what was asked for.
    static func tidy(_ path: String) -> String {
        var out: [String] = []
        for name in names(path) {
            if name == ".." { _ = out.popLast() } else { out.append(name) }
        }
        return "/" + out.joined(separator: "/")
    }

    private static func readLink(_ path: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            pointer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pointer.count) { readlink(path, $0, pointer.count - 1) }
        }
        guard length >= 0 else { return nil }
        return String(decoding: buffer[0..<length], as: UTF8.self)
    }

    // MARK: Opening

    /// Endings of files that run something, install something, mount something or change a setting when opened, whatever
    /// type macOS takes them for: Open is never offered for these.
    static let neverOpened: Set<String> = [
        "app", "appex", "xpc", "framework", "bundle", "plugin", "kext", "prefpane", "saver", "qlgenerator", "mdimporter", "osax",
        "action", "workflow", "wflow", "shortcut", "service",
        "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish", "py", "pyc", "rb", "pl", "php", "js", "mjs",
        "cjs", "ts", "lua", "tcl", "scpt", "scptd", "applescript", "jar", "class", "exe", "msi", "bat", "cmd", "com", "ps1", "vbs",
        "wsf", "dylib", "so", "bin", "run", "out", "pkg", "mpkg", "dmg", "sparseimage", "sparsebundle", "iso", "img", "cdr", "toast",
        "mobileconfig", "configprofile", "provisionprofile", "webloc", "inetloc", "fileloc", "url", "afploc", "ftploc", "desktop",
        "appimage", "lnk",
    ]

    /// Types that run something or are part of a program: Open is never offered for one.
    static let programTypes: [UTType] = [.application, .executable, .script, .shellScript, .bundle, .diskImage]

    /// Whether the menu's Open may open what is at `path` (made whole) with its default application, as a double-click in
    /// Finder would: a file, or a document package, that is not a program, script or application, and not a file that
    /// may be run (an executable one that is not a document).
    public static func mayOpen(_ path: String, kind: Kind) -> Bool {
        guard kind != .folder else { return false }
        let url = URL(fileURLWithPath: path)
        if neverOpened.contains(url.pathExtension.lowercased()) { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if let type, programTypes.contains(where: { type.conforms(to: $0) }) { return false }
        guard kind == .file else { return true }
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        // A file anyone may run, that macOS does not take for a document (a script with no ending, say), is refused; a
        // document on a disk that marks every file runnable is not.
        if info.st_mode & 0o111 != 0, !(type?.conforms(to: .content) ?? false) { return false }
        return true
    }

    // MARK: What a click and the menu do

    /// What a click on a file link does.
    public enum Show: Equatable, Sendable {
        /// Show it selected in its folder in Finder.
        case reveal(String)
        /// Open the folder in Finder.
        case openFolder(String)
        /// Nothing to show: say why in the conversation.
        case notice(String)
    }

    public static func show(_ resolution: Resolution, home: String) -> Show {
        switch resolution {
        case .found(let path, .folder): return .openFolder(path)
        case .found(let path, _): return .reveal(path)
        case .missing, .elsewhere: return .notice(notice(resolution, home: home) ?? "")
        }
    }

    /// What the conversation says when a link leads nowhere pi² will show; nil when it leads somewhere.
    public static func notice(_ resolution: Resolution, home: String) -> String? {
        switch resolution {
        case .found: return nil
        case .missing(let path): return "There is no file or folder at \(abbreviated(path, home: home)). It may have been moved or deleted."
        case .elsewhere(let path): return "\(abbreviated(path, home: home)) is on a network volume, and pi² shows only files on this Mac."
        }
    }

    /// A path with the home folder written `~`, as the person knows it.
    public static func abbreviated(_ path: String, home: String) -> String {
        guard home.count > 1 else { return path }
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    public enum MenuItem: String, CaseIterable, Sendable {
        case showInFinder = "Show in Finder"
        case open = "Open"
        case copyPath = "Copy Path"
    }

    /// The items a right-click puts at the top of the menu. A file link always has Show in Finder (which says so when
    /// nothing is there) and Copy Path; a path written as code has them only when something is there, since most code
    /// that starts with a slash is not a path. Open only for what `mayOpen` allows.
    public static func menu(_ resolution: Resolution, code: Bool) -> [MenuItem] {
        switch resolution {
        case .found(let path, let kind):
            return mayOpen(path, kind: kind) ? [.showInFinder, .open, .copyPath] : [.showInFinder, .copyPath]
        case .missing, .elsewhere:
            return code ? [] : [.showInFinder, .copyPath]
        }
    }
}
