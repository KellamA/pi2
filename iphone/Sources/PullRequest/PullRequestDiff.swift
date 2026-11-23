import Foundation

/// A pull request's diff, as `github.diff` answers it (`gh pr diff`, cut by the engine at 2 MB with a line saying so),
/// split into its files, so that the phone lists the files with what each adds and removes and shows one file's diff at
/// a time (docs/design/iphone.md, "The Work tab, and a pull request with its diff"). The Mac shows the same text whole,
/// a line each (`ProjectWorkGitHub.diffPage`); the phone reads it into files, since a phone shows one at a time.
struct PullRequestDiff: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// `@@ -88,12 +88,31 @@ …`: where the lines below are.
            case hunk
            case added
            case removed
            case context
            /// `\ No newline at end of file`, and the like.
            case note
        }

        let kind: Kind
        /// The line without its leading `+`, `-` or space; a hunk's or a note's whole line.
        let text: String
        /// Its number in the file before the change, for a removed or unchanged line; for a hunk, where it starts.
        let old: Int?
        /// Its number in the file after the change, for an added or unchanged line; for a hunk, where it starts.
        let new: Int?
    }

    struct File: Equatable, Identifiable, Sendable {
        enum Change: Equatable, Sendable {
            case modified, added, deleted, renamed
        }

        /// The path after the change (before it, for a deleted file).
        let path: String
        /// The path before a rename.
        let oldPath: String?
        let change: Change
        /// A binary file: git shows no lines for it.
        let binary: Bool
        let additions: Int
        let removals: Int
        let lines: [Line]
        /// The engine cut the diff inside this file, which is the last: its lines stop short.
        let cut: Bool

        var id: String { path }

        /// The file's own name, for a screen's title.
        var name: String { path.split(separator: "/").last.map(String.init) ?? path }

        /// The folder it is in, or nil at the top of the repository.
        var folder: String? {
            guard let slash = path.lastIndex(of: "/") else { return nil }
            return String(path[..<slash])
        }
    }

    let files: [File]
    /// The engine's line when it cut the diff (longer than 2 MB), as it wrote it; nil when the diff is whole.
    let cutNote: String?

    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var removals: Int { files.reduce(0) { $0 + $1.removals } }

    func file(_ path: String) -> File? { files.first { $0.path == path } }

    init(files: [File], cutNote: String? = nil) {
        self.files = files
        self.cutNote = cutNote
    }

    /// Reads `gh pr diff`'s text. Anything before the first `diff --git` line is left out; a file whose header cannot be
    /// read still shows, under the path its `diff --git` line gives.
    init(text: String) {
        var files: [File] = []
        var cutNote: String?
        var builder: FileBuilder?

        func finish() {
            if let file = builder?.file() { files.append(file) }
            builder = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.hasPrefix("diff --git ") {
                finish()
                builder = FileBuilder(gitLine: line)
                continue
            }
            if line.hasPrefix("[pi² cut the diff here") {
                cutNote = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                builder?.cut = true
                continue
            }
            builder?.take(line)
        }
        finish()
        self.files = files
        self.cutNote = cutNote
    }

    /// One file's lines as they are read, header first.
    private struct FileBuilder {
        var path: String
        var oldPath: String?
        var newPath: String?
        var renamedFrom: String?
        var renamedTo: String?
        var change = File.Change.modified
        var binary = false
        var inHunks = false
        var lines: [Line] = []
        var additions = 0
        var removals = 0
        var old = 0
        var new = 0
        var cut = false

        init(gitLine: String) {
            // "diff --git a/x b/x": the two halves are the same path but for a rename, so a path with spaces is the
            // first half when both are the same length. The `---` and `+++` lines below say it plainly when there are
            // lines.
            let rest = String(gitLine.dropFirst("diff --git ".count))
            let halves = rest.count
            if halves % 2 == 1 {
                let middle = rest.index(rest.startIndex, offsetBy: halves / 2)
                if rest[middle] == " " {
                    path = Self.unprefixed(String(rest[rest.index(after: middle)...]))
                    return
                }
            }
            path = Self.unprefixed(String(rest.split(separator: " ").last ?? Substring(rest)))
        }

        mutating func take(_ line: String) {
            if !inHunks {
                if line.hasPrefix("@@") {
                    inHunks = true
                } else {
                    header(line)
                    return
                }
            }
            if line.hasPrefix("@@") {
                let (oldStart, newStart) = Self.hunkStarts(line)
                old = oldStart
                new = newStart
                lines.append(Line(kind: .hunk, text: line, old: oldStart, new: newStart))
            } else if line.hasPrefix("+") {
                additions += 1
                lines.append(Line(kind: .added, text: String(line.dropFirst()), old: nil, new: new))
                new += 1
            } else if line.hasPrefix("-") {
                removals += 1
                lines.append(Line(kind: .removed, text: String(line.dropFirst()), old: old, new: nil))
                old += 1
            } else if line.hasPrefix("\\") {
                lines.append(Line(kind: .note, text: String(line.dropFirst()).trimmingCharacters(in: .whitespaces), old: nil, new: nil))
            } else if line.hasPrefix(" ") || line.isEmpty {
                // An empty line ends the text gh printed; inside a hunk, an unchanged empty line keeps its space.
                if line.isEmpty { return }
                lines.append(Line(kind: .context, text: String(line.dropFirst()), old: old, new: new))
                old += 1
                new += 1
            }
        }

        private mutating func header(_ line: String) {
            if line.hasPrefix("new file mode") {
                change = .added
            } else if line.hasPrefix("deleted file mode") {
                change = .deleted
            } else if line.hasPrefix("rename from ") {
                renamedFrom = Self.unquoted(String(line.dropFirst("rename from ".count)))
            } else if line.hasPrefix("rename to ") {
                renamedTo = Self.unquoted(String(line.dropFirst("rename to ".count)))
            } else if line.hasPrefix("--- ") {
                let name = String(line.dropFirst(4))
                if name != "/dev/null" { oldPath = Self.unprefixed(name) }
            } else if line.hasPrefix("+++ ") {
                let name = String(line.dropFirst(4))
                if name != "/dev/null" { newPath = Self.unprefixed(name) }
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                binary = true
            }
        }

        func file() -> File {
            let renamed = renamedFrom != nil && renamedTo != nil && renamedFrom != renamedTo
            let shownPath = renamedTo ?? newPath ?? oldPath ?? path
            return File(
                path: shownPath,
                oldPath: renamed ? renamedFrom : nil,
                change: renamed && change == .modified ? .renamed : change,
                binary: binary,
                additions: additions,
                removals: removals,
                lines: lines,
                cut: cut
            )
        }

        /// "@@ -88,12 +88,31 @@ …": where the old and new lines start.
        static func hunkStarts(_ line: String) -> (Int, Int) {
            let parts = line.split(separator: " ")
            func start(_ prefix: Character) -> Int {
                guard let part = parts.first(where: { $0.first == prefix }) else { return 0 }
                let number = part.dropFirst().split(separator: ",").first.flatMap { Int($0) }
                return number ?? 0
            }
            return (start("-"), start("+"))
        }

        /// A path as git writes it in a header: maybe in quotes with escapes, and with its `a/` or `b/`.
        static func unprefixed(_ name: String) -> String {
            let plain = unquoted(name)
            if plain.hasPrefix("a/") || plain.hasPrefix("b/") { return String(plain.dropFirst(2)) }
            return plain
        }

        /// git quotes a path with unusual characters and writes its bytes as octal escapes ("caf\303\251").
        static func unquoted(_ name: String) -> String {
            guard name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") else { return name }
            var bytes: [UInt8] = []
            let characters = Array(name.dropFirst().dropLast())
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if character == "\\", index + 1 < characters.count {
                    let next = characters[index + 1]
                    if next.isNumber, index + 3 < characters.count,
                       let value = UInt8(String(characters[(index + 1)...(index + 3)]), radix: 8) {
                        bytes.append(value)
                        index += 4
                        continue
                    }
                    let escaped: Character = switch next {
                    case "n": "\n"
                    case "t": "\t"
                    default: next
                    }
                    bytes += Array(String(escaped).utf8)
                    index += 2
                    continue
                }
                bytes += Array(String(character).utf8)
                index += 1
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// How much of a diff the phone draws at once, so that a very large one stays quick and readable: a file's first
/// `firstLines` lines, then as many again at each **Show more**; and of a line, its first `lineCharacters` characters
/// (a minified file's one line can be megabytes), with how many more it has. All of it is on the Mac and on GitHub.
enum PullRequestDiffBounds {
    static let firstLines = 1_500
    static let lineCharacters = 1_000

    /// A line's text as drawn, and how many characters were left out.
    static func shown(_ text: String) -> (text: String, left: Int) {
        guard text.count > lineCharacters else { return (text, 0) }
        return (String(text.prefix(lineCharacters)), text.count - lineCharacters)
    }
}
