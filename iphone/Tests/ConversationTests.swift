import EngineKit
import Foundation
import PiModels
import SwiftUI
import Testing
import TranscriptKit
import UIKit
import WebKit
@testable import pi2

/// The conversation's screen (#687): what it does with the page's messages, what it reads of the engine, the requests
/// it makes through the session, the pictures it prepares, and the page itself loading nothing from the network.
@MainActor
struct ConversationTests {
    private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// The limit on a wait for WebKit (`thePageLoadsNothingFromTheNetwork`): there only so that a hang fails, many times
    /// the slowest start seen on CI, and well inside the CI job's thirty minutes.
    private static let patience: Double = 300

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: The page's messages (docs/iphone.md section 8)

    @Test func noMessageFromThePageBecomesARequest() throws {
        let link = try #require(URL(string: "https://example.com/a"))
        let pictured = try decode([Item].self, #"[{"id":4,"kind":"user","text":"","images":2}]"#)
        let cases: [(TranscriptAction, ConversationPageResponse)] = [
            (.ready, .sendEverything),
            (.copy("words"), .copy("words")),
            (.openLink(link), .confirmLink(link)),
            (.openChat(12, beside: false), .openConversation(12)),
            (.openChat(12, beside: true), .openConversation(12)),
            (.openChat(13, beside: false), .ignore),
            // The two reads the owner allowed: older entries, and a picture an entry holds.
            (.picture(entry: 4, index: 0), .fetchPicture(entry: 4, index: 0)),
            (.picture(entry: 4, index: 2), .ignore),
            (.picture(entry: 5, index: 0), .ignore),
            (.older, .loadOlder),
            (.fileMenu(path: "/x", code: false), .ignore),
            // A file link opens the file's screen, which asks the engine for it (#698, `files.preview`).
            (.showFile("notes/plan.md"), .previewFile("notes/plan.md")),
        ]
        for (action, expected) in cases {
            #expect(ConversationPagePolicy.response(to: action, subChats: [12], items: pictured) == expected, "\(action)")
        }
        // Everything that would act on the engine at the Mac only says where to do it.
        let acting: [TranscriptAction] = [
            .decide(inbox: "i1", decision: "once"), .answer(inbox: "i1", text: "yes"),
            .answerNeed(id: "n1", answer: .reach(allow: true)), .undo(change: 3), .fork(entry: 2),
            .retry(entry: 2, model: nil), .edit(entry: 2, text: "x"), .version(after: nil, index: 1),
            .save(text: "x", name: "a.txt"), .savePicture(entry: 2, index: 0), .openDocument(entry: 2),
            .saveDocument(entry: 2), .output("bg-3"),
        ]
        for action in acting {
            guard case .notice = ConversationPagePolicy.response(to: action, subChats: [12]) else {
                Issue.record("\(action) is not answered with a notice")
                continue
            }
        }
    }

    @Test func subChatsAreOnlyThoseTheHandOffsOpened() throws {
        let items = try decode([Item].self, """
        [{"id":1,"kind":"tool","text":"","name":"delegate","details":{"conversationId":214}},
         {"id":2,"kind":"tool","text":"","name":"bash","details":{"conversationId":999}},
         {"id":3,"kind":"assistant","text":"See conversation 777"}]
        """)
        #expect(ConversationPagePolicy.subChats(items: items, state: nil) == [214])
    }

    @Test func changesAreDrawnWithoutUndo() throws {
        let changes = try decode([ProjectChangeLine].self, """
        [{"id":1,"summary":"Made Reviewer use opus","undone":false,"canUndo":true,"noUndo":null},
         {"id":2,"summary":"Added a rule","undone":true,"canUndo":false,"noUndo":null}]
        """)
        let drawn = ConversationPagePolicy.changesWithoutUndo(changes)
        #expect(drawn.count == 2)
        #expect(drawn.allSatisfy { !$0.canUndo })
        #expect(drawn[0].noUndo == "undo it on the Mac")
        #expect(drawn[1].noUndo == nil)
        #expect(drawn.map(\.summary) == changes.map(\.summary))
    }

    @Test func paletteIsInTheFormThePageTakes() throws {
        // The page's own check (transcript.js, COLOUR).
        let colour = try Regex(#"^rgba?\(\s*\d{1,3}(?:\.\d+)?\s*,\s*\d{1,3}(?:\.\d+)?\s*,\s*\d{1,3}(?:\.\d+)?\s*(?:,\s*(?:0|1|0?\.\d+)\s*)?\)$"#)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let palette = ConversationPalette.colors(for: UITraitCollection(userInterfaceStyle: style))
            #expect(palette["appearance"] == (style == .dark ? "dark" : "light"))
            for name in ["window", "panel", "card", "card2", "line", "line2", "tx", "tx2", "tx3", "acc", "ok", "warn", "bad", "on-acc"] {
                let value = try #require(palette[name], "\(name)")
                #expect(value.wholeMatch(of: colour) != nil, "\(name): \(value)")
            }
        }
        #expect(ConversationPalette.colors(for: UITraitCollection(userInterfaceStyle: .dark))["acc"] == "rgb(139, 147, 255)")
    }

    @Test func pageGrowsWithTheTextSizeUpToTwice() {
        let standard = ConversationPageBridge.zoom(for: UITraitCollection(preferredContentSizeCategory: .large))
        let largest = ConversationPageBridge.zoom(for: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        #expect(abs(standard - 1) < 0.01)
        #expect(largest == 2)
    }

    // MARK: What the screen reads of the engine

    private static let agent = #""agent":{"model":{"provider":"demo","modelId":"demo-1"},"thinkingLevel":null,"cwd":"/p","access":"ask","agentId":"a1","parent":null}"#

    /// A conversation's state as the engine sends it, idle, with `fields` in place of its own.
    private func state(_ fields: String) throws -> ConversationState {
        let base = """
        {"busy":false,"partial":null,"retry":null,"tools":[],"failure":null,"queued":[],\(Self.agent),
         "usage":{"cost":0,"tokens":0},"context":{"used":0,"window":null},
         "compacting":false,"compactionError":null,"plan":null,"projectInstructions":null,"projectInstructionFiles":null,
         "title":null,"archived":null,"setup":null,"local":null}
        """
        var object = try #require(try JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any])
        let changes = try #require(try JSONSerialization.jsonObject(with: Data("{\(fields)}".utf8)) as? [String: Any])
        object.merge(changes) { $1 }
        return try JSONDecoder().decode(ConversationState.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func busyWithQueuedAndOutgoingMessages() throws {
        let busy = try state(#""busy":true,"queued":[{"id":41,"mode":"steer","text":"Then open a pull request"},{"id":42,"mode":"queue","text":"","attachments":[{"name":"shot.png","kind":"image","size":10}]}],"messageWaits":{"holds":["the command `npm test`"],"ends":[]}"#)
        let outgoing = [OutgoingMessage(id: "r1", summary: "And check the docs"), OutgoingMessage(id: "r2", summary: "Use the second branch", submission: 40)]
        let status = ConversationStatus.make(
            conversationID: 9, state: busy, agentName: "Orchestrator", outgoing: outgoing, connected: true,
            inbox: [], needs: [], archivedInLibrary: false, models: []
        )
        #expect(status.busy)
        #expect(status.placeholder(steer: true) == "Steer Orchestrator while it works…")
        #expect(status.placeholder(steer: false) == "Queue a follow-up for Orchestrator…")
        #expect(status.chips.map(\.label) == ["Sending", "Sent", "After the command `npm test`", "Queued until the answer"])
        #expect(status.chips.map(\.summary) == ["And check the docs", "Use the second branch", "Then open a pull request", "shot.png"])
        #expect(status.chips[2].kind == .queued(submission: 41))
        #expect(status.arrivalSteered?.contains("npm test") == true)
        #expect(status.arrivalQueued == "Orchestrator reads this once it has answered.")
        #expect(status.failure == nil)

        let away = ConversationStatus.make(
            conversationID: 9, state: busy, agentName: "Orchestrator", outgoing: [outgoing[0]], connected: false,
            inbox: [], needs: [], archivedInLibrary: false, models: []
        )
        #expect(away.chips.first?.kind == .sending(macAway: true))
        #expect(away.chips.first?.label == "Sending when your Mac is back")
    }

    @Test func failedStoppedAndArchived() throws {
        let failed = ConversationStatus.make(
            conversationID: 9, state: try state(#""failure":{"reason":"model_error","detail":"overloaded"}"#), agentName: "Forge",
            outgoing: [], connected: true, inbox: [], needs: [], archivedInLibrary: false, models: []
        )
        #expect(failed.failure == .init(message: "The model returned an error: overloaded", stopped: false, canContinue: true))
        #expect(failed.placeholder(steer: true) == "Message Forge…")

        let stopped = ConversationStatus.make(
            conversationID: 9, state: try state(#""failure":{"reason":"aborted","detail":null}"#), agentName: "Forge",
            outgoing: [], connected: true, inbox: [], needs: [], archivedInLibrary: false, models: []
        )
        #expect(stopped.failure?.stopped == true)

        let archived = ConversationStatus.make(
            conversationID: 9, state: try state(#""archived":true,"failure":{"reason":"aborted","detail":null}"#), agentName: "Forge",
            outgoing: [], connected: true, inbox: [], needs: [], archivedInLibrary: false, models: []
        )
        #expect(archived.archived == .itself)
        #expect(archived.failure?.canContinue == false)
        #expect(ConversationStatus.make(
            conversationID: 9, state: nil, agentName: nil, outgoing: [], connected: true, inbox: [], needs: [],
            archivedInLibrary: true, models: []
        ).archived == .itself)
    }

    @Test func whatWaitsIsListedForNeedsYou() throws {
        let inbox = try decode([InboxItem].self, """
        [{"id":"i1","kind":"approval","conversationId":214,"callId":"c","tool":"bash","arguments":{},"question":null,
          "title":"Run npm test","agentName":"Forge","rootConversationId":9,"createdAt":0},
         {"id":"i2","kind":"approval","conversationId":30,"callId":"c","tool":"bash","arguments":{},"question":null,
          "title":"Elsewhere","agentName":"Scout","rootConversationId":30,"createdAt":0}]
        """)
        let status = ConversationStatus.make(
            conversationID: 9, state: try state(""), agentName: "Orchestrator", outgoing: [], connected: true,
            inbox: inbox, needs: [], archivedInLibrary: false, models: []
        )
        #expect(status.waiting.map(\.text) == ["Forge needs approval: Run npm test"])
    }

    // MARK: Requests, through the session (the recording refuses them)

    @Test func requestsAreMadeAndTheirRefusalShown() async throws {
        let transport = try #require(ReplayTransport.recording())
        let session = AppSession()
        session.start(transport, as: .connected(.home))
        #expect(try await eventually { !session.engine.projects.isEmpty })
        session.engine.openConversation(9)
        #expect(try await eventually { session.engine.open[9]?.state != nil })

        let requests = ConversationRequests(engine: session.engine, conversationID: 9)
        let outcome = await requests.send("Hello", pictures: [], steer: false)
        #expect(outcome == .refused("Not sent. The recorded session (PI2_TRANSPORT=replay) does not answer submit."))
        // Nothing is left on its way.
        #expect(session.engine.outgoing[9] == nil)
        #expect(await requests.stop() == "Not stopped. The recorded session (PI2_TRANSPORT=replay) does not answer abort.")
        #expect(await requests.withdraw(41) == "Not taken back. The recorded session (PI2_TRANSPORT=replay) does not answer withdraw.")
        #expect(await requests.carryOn() == "Not continued. The recorded session (PI2_TRANSPORT=replay) does not answer continue.")
        #expect(await requests.restore(9) == "Not restored. The recorded session (PI2_TRANSPORT=replay) does not answer conversation.unarchive.")
    }

    /// A message from the phone carries at most 1 MB of typed text (#924), counted in UTF-8 bytes as the engine counts
    /// it: the composer says so in the engine's words, and a send over it is refused before any request, so the text goes
    /// back in the field.
    @Test func aMessageOverOneMegabyteIsHeldBackInTheEnginesWords() async throws {
        let head = "/work 0 1000 "
        let exactly = head + String(repeating: "t", count: TypedTextLimit.bytes - head.utf8.count)
        let overByOne = head + String(repeating: "é", count: (TypedTextLimit.bytes - head.utf8.count - 1) / 2) + "tt"
        #expect(exactly.utf8.count == 1_048_576 && overByOne.utf8.count == 1_048_577)
        #expect(overByOne.count < 600_000, "far under the limit counted in characters")
        #expect(TypedTextLimit.refusal(exactly) == nil)
        // The engine's sentences, as engine/test/devices.ts holds them.
        #expect(TypedTextLimit.refusal(overByOne) == "A message from a phone can carry at most 1 MB of typed text; this one has just over 1 MB. Shorten it, or send it from the Mac.")
        #expect(TypedTextLimit.refusal(String(repeating: "t", count: 1_258_292)) == "A message from a phone can carry at most 1 MB of typed text; this one has 1.2 MB. Shorten it, or send it from the Mac.")
        #expect(TypedTextLimit.refusal(overByOne, answer: true) == "An answer from a phone can carry at most 1 MB of typed text; this one has just over 1 MB. Shorten it, or answer on the Mac.")
        #expect(TypedTextLimit.sizeText(66 * 1024 * 1024 + 13) == "66.0 MB")
        // A half rounds up, as JavaScript's toFixed(1) does: 1.25 and 1.75 MB.
        #expect(TypedTextLimit.sizeText(1_310_720) == "1.3 MB" && TypedTextLimit.sizeText(1_835_008) == "1.8 MB")

        let transport = RecordingTransport()
        let session = AppSession()
        session.start(transport, as: .connected(.home))
        #expect(try await eventually { session.engine.status == .connected })
        let requests = ConversationRequests(engine: session.engine, conversationID: 9)
        let outcome = await requests.send(overByOne, pictures: [], steer: false)
        #expect(outcome == .refused("Not sent. A message from a phone can carry at most 1 MB of typed text; this one has just over 1 MB. Shorten it, or send it from the Mac."))
        #expect(transport.params(of: "submit") == nil, "no request is made")
        #expect(session.engine.outgoing[9] == nil)
        _ = await requests.send(exactly, pictures: [], steer: false)
        #expect(transport.params(of: "submit")?["text"] as? String == exactly, "exactly 1 MB goes")
    }

    @Test func sendingAPicturePutsItInTheRequest() async throws {
        let transport = RecordingTransport()
        let session = AppSession()
        session.start(transport, as: .connected(.home))
        #expect(try await eventually { session.engine.status == .connected })
        let picture = ConversationPicture(name: "Photo 1", data: Data([1, 2, 3]), mimeType: "image/jpeg", thumbnail: Data())
        let requests = ConversationRequests(engine: session.engine, conversationID: 9)
        _ = await requests.send("Look", pictures: [picture], steer: true)
        // The session sends conversations.shown too, on connecting: the request is found by its method.
        let params = try #require(transport.params(of: "submit"))
        #expect(params["id"] as? Int == 9)
        #expect(params["text"] as? String == "Look")
        #expect(params["mode"] as? String == "steer")
        let attachments = try #require(params["attachments"] as? [[String: Any]])
        #expect(attachments.first?["kind"] as? String == "image")
        #expect(attachments.first?["mimeType"] as? String == "image/jpeg")
        #expect(attachments.first?["data"] as? String == Data([1, 2, 3]).base64EncodedString())
    }

    @Test func aPictureIsAskedForAsTheMacAsksForIt() async throws {
        let transport = RecordingTransport()
        let session = AppSession()
        session.start(transport, as: .connected(.home))
        #expect(try await eventually { session.engine.status == .connected })
        let picture = await ConversationRequests(engine: session.engine, conversationID: 9).picture(entry: 4, index: 1)
        #expect(picture == nil)
        let params = try #require(transport.params(of: "conversation.image"))
        #expect(params["id"] as? Int == 9)
        #expect(params["entryId"] as? Int == 4)
        #expect(params["index"] as? Int == 1)
    }

    // MARK: Pictures

    @Test func aLargePhotoIsMadeSmallEnough() throws {
        let size = CGSize(width: 4000, height: 3000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            // Noise, which compresses badly, as a photo does.
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<4000 {
                UIColor(hue: .random(in: 0...1, using: &generator), saturation: 1, brightness: 1, alpha: 1).setFill()
                context.fill(CGRect(x: .random(in: 0...4000, using: &generator), y: .random(in: 0...3000, using: &generator), width: 60, height: 60))
            }
        }
        let data = try #require(image.pngData())
        let picture = try ConversationPictureReader.prepare(data, name: "Photo")
        let prepared = try #require(UIImage(data: picture.data)?.cgImage)
        #expect(max(prepared.width, prepared.height) <= ConversationPictureLimits.side)
        #expect(picture.data.count <= ConversationPictureLimits.bytes)
        #expect(picture.mimeType == "image/jpeg")
        #expect(!picture.thumbnail.isEmpty)
        #expect(throws: ConversationPictureError.self) { try ConversationPictureReader.prepare(Data("not a picture".utf8), name: "x") }
    }

    // MARK: The page (docs/iphone.md section 8)

    /// The page is in this build's bundle, and once it has drawn a conversation holding addresses, pictures and markup
    /// that point at the network, it has loaded nothing but its own files: no picture, no fetch, no navigation. A
    /// fetch tried from inside the page is refused by its content security policy.
    @Test func thePageLoadsNothingFromTheNetwork() async throws {
        let folder = try #require(TranscriptPage.folder, "the page is copied into the app's bundle")
        #expect(folder.path.hasPrefix(Bundle.main.bundlePath))

        let away = "https://pi2-test.invalid"
        let items = try decode([Item].self, """
        [{"id":1,"kind":"user","text":"Show me ![a picture](\(away)/user.png)"},
         {"id":2,"kind":"assistant","text":"Here: ![picture](\(away)/md.png) and [a link](\(away)/link) <img src=\\"\(away)/html.png\\" onerror=\\"window.injected = 1\\"> <script>window.injected = 2</script> <iframe src=\\"\(away)/frame\\"></iframe> Last line of the test."}]
        """)
        let content = ConversationPageContent(
            conversationID: 9, items: items, earlier: 0, state: try state(""),
            names: TranscriptFeed.Names(conversationId: 9, agentName: "Orchestrator", mcp: [:], agents: [], apps: [:])
        )

        let bridge = ConversationPageBridge()
        var shown = false
        bridge.onShown = { shown = true }
        let view = bridge.makeView(folder: folder)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        defer {
            view.close()
            window.isHidden = true
        }
        bridge.show(content)
        // The first web view in the test's process waits for WebKit to start its processes, and the page, though a
        // file, is loaded through the networking one: on a new simulator on CI that one took 40 and 45 seconds to start
        // (#871), on other runs a second or two. So each wait is for the thing itself, and its limit only a hang guard,
        // in two parts so that a failure says which never came; and the test stops there, rather than asking a page
        // that has not loaded what it holds.
        try #require(try await eventually(Self.patience) { view.isReady }, "the page never said it was ready")
        try #require(try await eventually(Self.patience) { shown }, "the page was ready but never showed the conversation")

        func run(_ script: String) async throws -> Any? {
            try await view.callAsyncJavaScript(script, contentWorld: .page)
        }
        let text = try await run("return document.getElementById('transcript').textContent") as? String ?? ""
        #expect(text.contains("Last line of the test."), "\(text)")
        // Markup in the text is text: nothing in it ran, and no element came of it.
        #expect(try await run("return window.injected === undefined") as? Bool == true)
        #expect(try await run("return document.querySelectorAll('iframe, main img:not([src^=\"blob:\"])').length") as? Int == 0)
        // Everything the page loaded is its own: its file and the files beside it.
        // (WebKit keeps no timing for a file's own scripts, so this lists only what came from elsewhere, if anything did.)
        let loaded = try #require(try await run("return performance.getEntriesByType('resource').map((entry) => entry.name).concat(Array.from(document.scripts, (script) => script.src), Array.from(document.styleSheets, (sheet) => sheet.href || ''))") as? [String])
        #expect(loaded.count >= 9)
        for address in loaded {
            #expect(address.hasPrefix("file://") && address.contains("/transcript/"), "\(address)")
        }
        // A fetch, even one the page tried, is refused by the policy before it leaves.
        let refused = try await run("""
            const violations = [];
            document.addEventListener('securitypolicyviolation', (event) => violations.push(event.violatedDirective));
            let failed = false;
            try { await fetch('\(away)/fetch'); } catch { failed = true; }
            await new Promise((done) => setTimeout(done, 100));
            return failed && violations.some((directive) => directive.startsWith('connect-src') || directive.startsWith('default-src'));
            """)
        #expect(refused as? Bool == true)
        // And the view goes nowhere else.
        _ = try? await run("location.href = '\(away)/away'; return true")
        try await Task.sleep(for: .milliseconds(300))
        #expect(view.url?.isFileURL == true)
    }
}

/// A transport that keeps what it is sent and answers nothing: for checking the request a screen makes.
@MainActor
private final class RecordingTransport: EngineTransport {
    var sent: [Data] = []
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        self.handler = handler
        Task { @MainActor [weak self] in self?.handler?(.ready) }
    }

    func send(_ data: Data) {
        sent.append(data)
        // Refused at once, so the request does not wait.
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = request["id"] as? Int,
              var reply = try? JSONSerialization.data(withJSONObject: ["id": id, "error": "Not answered here."]) else { return }
        reply.append(0x0A)
        Task { @MainActor [weak self] in self?.handler?(.received(reply)) }
    }

    func cancel() {
        handler = nil
    }

    /// The parameters of the first request sent with `method`, whatever else was sent before or after it.
    func params(of method: String) -> [String: Any]? {
        for data in sent {
            guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  request["method"] as? String == method else { continue }
            return request["params"] as? [String: Any] ?? [:]
        }
        return nil
    }
}
