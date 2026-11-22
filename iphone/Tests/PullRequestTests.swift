import Foundation
import PiModels
import Testing
@testable import pi2

/// A pull request (#695): the requests its buttons make, as the Mac's Work tab makes them; the `github` event read as
/// the Mac reads it; `gh pr diff`'s text read into files and lines; how much of a large diff is drawn; and what the
/// screen shows of the recorded session, whose projects have no repository.
@MainActor
struct PullRequestTests {
    /// A request's parameters as JSON with sorted keys, to compare with what the Mac sends.
    private func json(_ request: PullRequestRequest) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: request.arguments, options: [.sortedKeys]), as: UTF8.self)
    }

    private func value(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: - The requests, as the Mac makes them

    @Test func eachRequestIsTheMacs() throws {
        let cases: [(PullRequestRequest, String, String)] = [
            (.refresh(project: "p-1"), "github.refresh", #"{"projectId":"p-1"}"#),
            (.diff(project: "p-1", number: 7), "github.diff", #"{"number":7,"projectId":"p-1"}"#),
            (.merge(project: "p-1", number: 7), "github.merge", #"{"number":7,"projectId":"p-1"}"#),
            (.sendBack(project: "p-1", number: 7, reason: "Keep the key's name"), "github.sendBack",
             #"{"number":7,"projectId":"p-1","reason":"Keep the key's name"}"#),
            (.settle(project: "p-1", intent: "i-1", happened: false), "github.settle", #"{"happened":false,"intent":"i-1","projectId":"p-1"}"#),
        ]
        for (request, method, params) in cases {
            #expect(request.method == method)
            #expect(try json(request) == params, "\(method)")
        }
    }

    // MARK: - The github event

    @Test func theListingIsReadAsTheMacReadsIt() throws {
        let event = try value("""
        {"event":"github","projects":{"p-1":{"state":"ok","readAt":1700000000000,"reading":true,"issues":[],
         "pulls":[{"number":7,"title":"Fold","url":"u","head":"b","base":"main","author":"a","state":"open","draft":true,
          "checks":"failing","failingChecks":[{"name":"App","url":"c"}],"mergeable":"no",
          "findings":[{"agentName":"Scout","verdict":"changes","at":1700000060000,"url":"f","text":"No"},
                      {"agentName":"Forge","verdict":"approve","at":1700000120000,"url":"g","text":"Yes"}],
          "openedBy":{"conversationId":31},"work":5},
          {"number":6,"title":"Old","url":"","head":"o","base":"main","author":"","state":"closed","draft":false,
           "checks":"none","failingChecks":[],"mergeable":"unknown","findings":[],"openedBy":null,"work":null,"partial":true}],
         "unknown":[{"intent":"i-1","summary":"merging pull request #6","at":1700000000000}]}}}
        """)
        let listing = try #require(PullRequestListing.of(event, project: "p-1"))
        #expect(PullRequestListing.of(event, project: "p-2") == nil)
        #expect(listing.reading && !listing.troubled && !listing.firstRead)
        let pull = try #require(listing.pull(7))
        #expect(pull.stateWords == "Draft")
        #expect(pull.checksWords == "1 check failing")
        #expect(pull.failingChecks.map(\.name) == ["App"])
        #expect(pull.openedBy == 31 && pull.work == 5 && pull.mergeable == "no")
        #expect(pull.findingsNewestFirst.map(\.agentName) == ["Forge", "Scout"])
        let closed = try #require(listing.pull(6))
        #expect(closed.partial && closed.stateWords == "Closed" && closed.openedBy == nil)
        #expect(listing.unknown.map(\.summary) == ["merging pull request #6"])
    }

    @Test func aReadThatWentWrongSaysWhat() throws {
        let unreachable = PullRequestListing(try value(#"{"state":"unreachable","readAt":0,"pulls":[]}"#))
        #expect(unreachable.troubled && !unreachable.firstRead)
        #expect(unreachable.troubleWords()?.hasPrefix("GitHub cannot be reached from your Mac. Nothing has been read yet") == true)
        let missing = PullRequestListing(try value(#"{"state":"signed_out","error":"gh: command not found","pulls":[]}"#))
        #expect(missing.troubleWords()?.contains("gh is not installed") == true)
        let loading = PullRequestListing(try value(#"{"state":"loading","pulls":[]}"#))
        #expect(loading.firstRead && loading.troubleWords() == nil)
    }

    // MARK: - The diff, in files

    @Test func theDiffIsReadIntoItsFiles() throws {
        let diff = PullRequestDiff(text: PullRequestSamples.diffText)
        #expect(diff.files.map(\.path) == ["app/Sources/pi2/ProjectHub.swift", "docs/projects.md", "changelog.d/5-hub.md", "docs/pictures/hub-folded.png"])
        #expect(diff.files.map(\.change) == [.modified, .added, .renamed, .modified])
        #expect(diff.files[2].oldPath == "changelog.d/5.md" && diff.files[2].lines.isEmpty)
        #expect(diff.files[3].binary)
        #expect(diff.cutNote == nil)

        let hub = diff.files[0]
        #expect(hub.additions == 10 && hub.removals == 1)
        #expect(hub.name == "ProjectHub.swift" && hub.folder == "app/Sources/pi2")
        let first = try #require(hub.lines.first)
        #expect(first.kind == .hunk && first.old == 88 && first.new == 88)
        #expect(hub.lines[1] == .init(kind: .context, text: "    var body: some View {", old: 88, new: 88))
        #expect(hub.lines[2] == .init(kind: .removed, text: "        HStack { conversation; board }", old: 89, new: nil))
        #expect(hub.lines[3] == .init(kind: .added, text: "        HStack(spacing: 0) {", old: nil, new: 89))
        #expect(hub.lines.last == .init(kind: .note, text: "No newline at end of file", old: nil, new: nil))
        // An unchanged empty line keeps its place, and the second hunk starts where its header says.
        #expect(hub.lines.contains(.init(kind: .context, text: "", old: 91, new: 98)))
        #expect(hub.lines.contains(.init(kind: .hunk, text: "@@ -140,6 +147,8 @@ struct ProjectHub: View {", old: 140, new: 147)))
        #expect(diff.additions == 13 && diff.removals == 1)
    }

    @Test func aDiffTheEngineCutSaysSo() {
        let text = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -old
        +new
        [pi² cut the diff here: it is longer than 2 MB. gh pr diff 7 --repo o/r shows all of it.]
        """
        let diff = PullRequestDiff(text: text)
        #expect(diff.files.count == 1 && diff.files[0].cut)
        #expect(diff.cutNote?.hasPrefix("pi² cut the diff here") == true)
        #expect(diff.files[0].lines.count == 3)
    }

    @Test func pathsWithSpacesQuotesAndDeletionsAreRead() {
        let text = """
        diff --git a/My Notes/a b.md b/My Notes/a b.md
        deleted file mode 100644
        --- a/My Notes/a b.md
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
        diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
        index 1..2 100644
        Binary files "a/caf\\303\\251.txt" and "b/caf\\303\\251.txt" differ
        diff --git a/x y b/x y
        old mode 100644
        new mode 100755
        """
        let diff = PullRequestDiff(text: text)
        #expect(diff.files.map(\.path) == ["My Notes/a b.md", "café.txt", "x y"])
        #expect(diff.files[0].change == .deleted && diff.files[0].removals == 2)
        #expect(diff.files[1].binary)
        #expect(diff.files[2].lines.isEmpty && diff.files[2].change == .modified)
    }

    @Test func aLargeDiffIsBounded() throws {
        let diff = PullRequestDiff(text: PullRequestSamples.largeDiffText)
        let file = try #require(diff.files.first)
        #expect(file.additions == 4_000)
        #expect(file.lines.count > PullRequestDiffBounds.firstLines)
        let long = file.lines[2].text
        let (shown, left) = PullRequestDiffBounds.shown(long)
        #expect(shown.count == PullRequestDiffBounds.lineCharacters)
        #expect(left == long.count - PullRequestDiffBounds.lineCharacters)
        #expect(PullRequestDiffBounds.shown("short").text == "short")
        #expect(PullRequestDiffBounds.shown("short").left == 0)
    }

    @Test func voiceOverSaysWhatHappenedToALine() {
        #expect(PullRequestDiffLine.label(.init(kind: .added, text: "  x = 1", old: nil, new: 12)) == "Added, line 12: x = 1")
        #expect(PullRequestDiffLine.label(.init(kind: .removed, text: "", old: 3, new: nil)) == "Removed, line 3: empty")
        #expect(PullRequestDiffLine.label(.init(kind: .hunk, text: "@@ -1 +40 @@", old: 1, new: 40)) == "Changes from line 40")
        let file = PullRequestDiff(text: PullRequestSamples.diffText).files[2]
        #expect(PullRequestLook.fileLabel(file) == "changelog.d/5-hub.md, Renamed from changelog.d/5.md, 0 added, 0 removed")
    }

    // MARK: - Samples, which only a debug build has

    @Test func everySampleIsAPullRequestTheScreenCanDraw() throws {
        for name in ["open", "failing", "running", "merged", "closed", "trouble", "unknown", "large", "nodiff"] {
            let sample = try #require(PullRequestSamples(name, now: Date()), "\(name)")
            #expect(sample.listing.pull(7) != nil, "\(name)")
        }
        #expect(PullRequestSamples("nodiff", now: Date())?.diff == nil)
        #expect(PullRequestSamples("trouble", now: Date())?.listing.troubled == true)
        #expect(PullRequestSamples("nonsense", now: Date()) == nil)
    }

    // MARK: - Against the recorded session

    @Test func theRecordingsProjectsHaveNoPullRequestsAndItsEngineRefusesTheDiff() async throws {
        let session = AppSession()
        session.start(try #require(ReplayTransport.recording()), as: .connected(.home))
        #expect(try await eventually { !session.engine.projects.isEmpty && session.engine.hasLoadedLibrary && session.engine.status == .connected })
        let demo = try #require(session.engine.projects.first { $0.name == "Demo project" })

        // Its work is kept by pi²: no repository, so no pull request, and the screen says so rather than waiting.
        let source = PullRequestSource(session.engine, project: demo.id, number: 7, store: PullRequestStore())
        if PullRequestSamples.current == nil {
            #expect(source.state == .noRepository("Demo project"))
            #expect(!source.readsDiff)
            #expect(PullRequestSource(session.engine, project: "p-none", number: 7, store: PullRequestStore()).state == .noProject)
        }

        // Asked anyway, the recording refuses the diff, and the store keeps its words for the screen.
        let store = PullRequestStore()
        let key = PullRequestStore.Key(project: demo.id, number: 7)
        store.readDiff(key, through: session.engine)
        #expect(store.diffs[key] == .reading)
        #expect(try await eventually { if case .refused = store.diffs[key] { true } else { false } })
        if case .refused(let words)? = store.diffs[key] { #expect(words.contains("github.diff")) }

        // So does a merge: shown as on its way, then the engine's words, and nothing pending.
        store.send(.merge(project: demo.id, number: 7), for: key, shown: "Merging", through: session.engine)
        #expect(store.pending[key] == "Merging")
        #expect(try await eventually { store.pending[key] == nil })
        #expect(store.problems[key]?.contains("github.merge") == true)

        // A second send while one is on its way is not sent.
        store.send(.sendBack(project: demo.id, number: 7, reason: "a"), for: key, shown: "Sending back", through: session.engine)
        store.send(.merge(project: demo.id, number: 7), for: key, shown: "Merging", through: session.engine)
        #expect(store.pending[key] == "Sending back")
        #expect(try await eventually { store.pending[key] == nil })
        #expect(store.problems[key]?.contains("github.sendBack") == true)
    }
}
