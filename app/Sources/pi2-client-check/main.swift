import Foundation

// Checks that the app's client reads the engine as it did before its models moved into a package (docs/iphone.md
// section 8, #669) and the client itself into EngineKit (#670): a session a throwaway copy's engine sent, recorded once
// (`Fixture/session.jsonl`), is played to the client, EngineKit's `EngineSession` (`Replay`), and what every view would
// read is written out and compared with `Fixture/expected.txt`. That file was made by this program built with the models
// as they were in the app before they moved (commit 4241886: the app's `Models.swift`, `TranscriptFeed.swift`, and the
// models of `Projects.swift`, `ProjectHub.swift`, `ProjectRulesTab.swift`, `Attachments.swift` and
// `LocalModelViews.swift`, compiled into the check itself, with a copy of `EngineClient.handle`'s reading of each event).
// A model or the client changed in what it reads or works out changes the text, and the check fails at the first line
// that differs.
//
// The session: `scripts/test-copy fill --project 2` building two demo projects in a copy of a development build, with
// every conversation opened as it appeared, as the app's connection gets it. The copy's home folder is written
// `/Users/someone`, and the Mac's memory and free disk space are made up; nothing else was changed.
//
// Run it from `app/`, or pass `--fixture <folder>`. `--write` writes `expected.txt` from the models as they are now,
// which is only right when the models' reading changes on purpose: say so in the pull request that does it.

let arguments = CommandLine.arguments
let folder = arguments.firstIndex(of: "--fixture").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    ?? "Sources/pi2-client-check/Fixture"
let sessionURL = URL(fileURLWithPath: folder).appendingPathComponent("session.jsonl")
let expectedURL = URL(fileURLWithPath: folder).appendingPathComponent("expected.txt")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pi2-client-check: \(message)\n".utf8))
    exit(1)
}

guard let session = try? String(contentsOf: sessionURL, encoding: .utf8) else {
    fail("cannot read \(sessionURL.path); run it from app/ or pass --fixture <folder>")
}

let replay = Replay()
var number = 0
for line in session.split(separator: "\n", omittingEmptySubsequences: true) {
    number += 1
    replay.take(String(line), number: number)
}
replay.writeOpen()
replay.writeFormats()
replay.writeWorkReadings()
let output = replay.lines.joined(separator: "\n") + "\n"

// The session must hold what it is meant to, or the comparison proves little.
for (kind, least) in [("library", 1), ("agents", 1), ("projects", 1), ("needs", 1), ("conversation", 20), ("activity", 1), ("inbox", 1), ("work", 1)] {
    if replay.counts[kind, default: 0] < least { fail("the session has \(replay.counts[kind, default: 0]) \(kind) events, fewer than \(least)") }
}
if !replay.unread.isEmpty { fail("the client could not read \(replay.unread.count) lines: \(replay.unread.prefix(10).joined(separator: ", "))") }

if arguments.contains("--write") {
    do { try output.write(to: expectedURL, atomically: true, encoding: .utf8) } catch { fail("cannot write \(expectedURL.path): \(error)") }
    print("pi2-client-check: wrote \(expectedURL.path), \(replay.lines.count) lines from \(number) engine lines")
    exit(0)
}

guard let expected = try? String(contentsOf: expectedURL, encoding: .utf8) else { fail("cannot read \(expectedURL.path)") }
if expected != output {
    let want = expected.split(separator: "\n", omittingEmptySubsequences: false)
    let got = output.split(separator: "\n", omittingEmptySubsequences: false)
    var shown = 0
    for index in 0..<max(want.count, got.count) where shown < 10 {
        let a = want.indices.contains(index) ? Array(want[index]) : Array("(nothing)")
        let b = got.indices.contains(index) ? Array(got[index]) : Array("(nothing)")
        guard a != b else { continue }
        // Where the two first differ, with some of what comes before: a line can be thousands of characters long.
        let first = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
        let from = max(0, first - 160)
        let around = { (line: [Character]) in (from > 0 ? "…" : "") + String(line[min(from, line.count)..<min(line.count, first + 160)]) }
        FileHandle.standardError.write(Data("line \(index + 1), character \(first + 1)\n  expected: \(around(a))\n  now:      \(around(b))\n".utf8))
        shown += 1
    }
    fail("the client reads the session differently from before (\(want.count) lines expected, \(got.count) now); the first differences are above")
}
let kinds = replay.counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
print("pi2-client-check: \(number) engine lines replayed (\(kinds)); all \(replay.lines.count) lines of what the client keeps match")
