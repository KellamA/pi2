
// What the app's bridge takes from the page about presentations (#946; docs/design/presenting.md, "The transcript
// page"): `presentedImage`, `expand`, `choose` and `answer` for a `present` question. The page is untrusted input, so each
// is checked twice, as the bridge does: its shape (`TranscriptAction(message:)`), and then whether this conversation has
// what it names (`TranscriptAction.PresentedChecks`): a presentation, version and item of its own records, a need that
// is a `present` question of those records still open and still waiting in this conversation, a choice among that
// question's ids. Each refusal is tried, and what the real page posts for the mockups' conversation passes.

import AppKit
import PiModels
import TranscriptKit
import WebKit

/// Records as the engine sends them: p1 with a picture, p2 with two versions, the second asking, the first answered.
let bridgeRecords = """
    {"items": [
      {"id": "p1", "versions": [{"version": 1, "callId": "a1", "createdAt": 1, "title": "Alone", "question": null,
        "network": {"allowed": false, "changes": []},
        "items": [{"label": "A", "caption": null, "kind": "picture", "name": "a.png", "mimeType": "image/png", "sha256": "\(String(repeating: "a", count: 64))",
                   "bytes": 10, "files": 1, "width": 4, "height": 4, "snapshot": null, "drawn": null}]}]},
      {"id": "p2", "versions": [
        {"version": 1, "callId": "a2", "createdAt": 2, "title": "Three", "network": {"allowed": false, "changes": []},
         "question": {"text": "Old", "choices": [{"id": "c1", "label": "Use A"}], "words": true, "need": "n-answered", "answer": {"chose": "Use A"}},
         "items": [
           {"label": "A", "caption": null, "kind": "picture", "name": "a.png", "mimeType": "image/png", "sha256": "\(String(repeating: "b", count: 64))", "bytes": 10, "files": 1, "width": 4, "height": 4, "snapshot": null, "drawn": null},
           {"label": "B", "caption": null, "kind": "page", "name": "b/index.html", "mimeType": "text/html", "sha256": "\(String(repeating: "c", count: 64))", "bytes": 10, "files": 1, "width": null, "height": null, "snapshot": {"state": "pending"}, "drawn": null}]},
        {"version": 2, "callId": "a3", "createdAt": 3, "title": "Three", "network": {"allowed": false, "changes": []},
         "question": {"text": "Which?", "choices": [{"id": "c1", "label": "Use A"}, {"id": "c2", "label": "Use B"}], "words": true, "need": "n-open", "answer": null},
         "items": [
           {"label": "A", "caption": null, "kind": "picture", "name": "a.png", "mimeType": "image/png", "sha256": "\(String(repeating: "b", count: 64))", "bytes": 10, "files": 1, "width": 4, "height": 4, "snapshot": null, "drawn": null},
           {"label": "B", "caption": null, "kind": "page", "name": "b/index.html", "mimeType": "text/html", "sha256": "\(String(repeating: "d", count: 64))", "bytes": 10, "files": 1, "width": 1280, "height": 900, "snapshot": {"state": "drawn", "sha256": "\(String(repeating: "e", count: 64))"}, "drawn": null}]}
      ]}
    ]}
    """

@MainActor
func presentingBridge(folder: URL) async {
    let records = Dictionary(uniqueKeysWithValues: PresentationRecord.list(from: Data(bridgeRecords.utf8)).map { ($0.id, $0) })
    // n-open waits in this conversation; n-elsewhere is a decision waiting in another, n-answered waits no more.
    let checks = TranscriptAction.PresentedChecks(records: records, waiting: ["n-open", "n-answered", "q-other"])
    let action = { (body: [String: Any]) in TranscriptAction(message: body) }
    let passes = { (body: [String: Any]) in action(body).map(checks.allows) == true }

    await group("the bridge takes a presented picture, Expand, a choice and words only for what this conversation has") {
        check("records read", records.keys.sorted() == ["p1", "p2"], "\(records.keys.sorted())")
        check("a picture of p1", passes(["type": "presentedImage", "presentation": "p1", "version": 1, "item": 0]))
        check("a page's snapshot of p2's version 2", passes(["type": "presentedImage", "presentation": "p2", "version": 2, "item": 1]))
        check("Expand of p2's version 1, its second item", passes(["type": "expand", "presentation": "p2", "version": 1, "item": 1]))
        check("a choice of the open question", action(["type": "choose", "need": "n-open", "choice": "c2"]) == .choose(need: "n-open", choice: "c2") && passes(["type": "choose", "need": "n-open", "choice": "c2"]))
        check("words for the open question", action(["type": "answer", "need": "n-open", "text": "Neither"]) == .answerPresented(need: "n-open", text: "Neither") && passes(["type": "answer", "need": "n-open", "text": "Neither"]))
        check("words of 20,000 characters", passes(["type": "answer", "need": "n-open", "text": String(repeating: "w", count: 20_000)]))
        check("today's answer to an Inbox question is still read as before", action(["type": "answer", "inbox": "q1", "text": "Yes"]) == .answer(inbox: "q1", text: "Yes"))
    }

    await group("the bridge refuses what is not shaped as the contract says") {
        let shapes: [(String, [String: Any])] = [
            ("no presentation", ["type": "presentedImage", "version": 1, "item": 0]),
            ("a presentation that is not p and a number", ["type": "presentedImage", "presentation": "x1", "version": 1, "item": 0]),
            ("p0", ["type": "expand", "presentation": "p0", "version": 1, "item": 0]),
            ("p01", ["type": "expand", "presentation": "p01", "version": 1, "item": 0]),
            ("a presentation with another digit", ["type": "expand", "presentation": "p١", "version": 1, "item": 0]),
            ("a presentation that is a number", ["type": "expand", "presentation": 1, "version": 1, "item": 0]),
            ("a version of 0", ["type": "presentedImage", "presentation": "p1", "version": 0, "item": 0]),
            ("a version that is a fraction", ["type": "presentedImage", "presentation": "p1", "version": 1.5, "item": 0]),
            ("a version that is text", ["type": "presentedImage", "presentation": "p1", "version": "1", "item": 0]),
            ("a version that is true", ["type": "presentedImage", "presentation": "p1", "version": true, "item": 0]),
            ("an item below 0", ["type": "expand", "presentation": "p1", "version": 1, "item": -1]),
            ("an item past the sixth", ["type": "expand", "presentation": "p1", "version": 1, "item": 6]),
            ("an item that is a huge number", ["type": "expand", "presentation": "p1", "version": 1, "item": 1e300]),
            ("a choice with no need", ["type": "choose", "choice": "c1"]),
            ("a choice that is a number", ["type": "choose", "need": "n-open", "choice": 1]),
            ("an empty choice", ["type": "choose", "need": "n-open", "choice": ""]),
            ("a choice with a line break", ["type": "choose", "need": "n-open", "choice": "c1\n"]),
            ("a need of over 200 characters", ["type": "choose", "need": String(repeating: "n", count: 201), "choice": "c1"]),
            ("words that are empty", ["type": "answer", "need": "n-open", "text": "  \n"]),
            ("words past the 20,000 characters the engine takes", ["type": "answer", "need": "n-open", "text": String(repeating: "w", count: 20_001)]),
            ("an answer naming both a need and an Inbox item", ["type": "answer", "need": "n-open", "inbox": "q1", "text": "Yes"]),
        ]
        for (name, body) in shapes { check("refused: \(name)", action(body) == nil, "read as \(String(describing: action(body)))") }
    }

    await group("the bridge refuses what this conversation does not have") {
        let refused: [(String, [String: Any])] = [
            ("a presentation it has not", ["type": "presentedImage", "presentation": "p3", "version": 1, "item": 0]),
            ("a version it has not", ["type": "presentedImage", "presentation": "p1", "version": 2, "item": 0]),
            ("an item it has not", ["type": "presentedImage", "presentation": "p1", "version": 1, "item": 1]),
            ("Expand of a presentation it has not", ["type": "expand", "presentation": "p9", "version": 1, "item": 0]),
            ("Expand of an item it has not", ["type": "expand", "presentation": "p2", "version": 2, "item": 2]),
            ("a choice for a need that is no question of its records", ["type": "choose", "need": "q-other", "choice": "c1"]),
            ("a choice for a need not waiting in this conversation", ["type": "choose", "need": "n-elsewhere", "choice": "c1"]),
            ("a choice for a question already answered", ["type": "choose", "need": "n-answered", "choice": "c1"]),
            ("a choice not among the question's", ["type": "choose", "need": "n-open", "choice": "c3"]),
            ("a choice that is another question's label", ["type": "choose", "need": "n-open", "choice": "Use A"]),
            ("words for a need that is no question of its records", ["type": "answer", "need": "q-other", "text": "Yes"]),
            ("words for a question already answered", ["type": "answer", "need": "n-answered", "text": "Yes"]),
        ]
        for (name, body) in refused {
            check("refused: \(name)", action(body) != nil && !passes(body), action(body) == nil ? "not even read" : "allowed")
        }
        // The same question, waiting no more as the engine's list has it, is refused although its record is still open.
        let gone = TranscriptAction.PresentedChecks(records: records, waiting: [])
        check("refused: a choice once the need has left the engine's list", !gone.allows(.choose(need: "n-open", choice: "c1")))
        // A conversation with no records refuses everything about presentations, and nothing else.
        let none = TranscriptAction.PresentedChecks(records: [:], waiting: ["n-open"])
        check("refused: anything about a presentation in a conversation with none", !none.allows(.presentedImage(presentation: "p1", version: 1, item: 0))
            && !none.allows(.expand(presentation: "p1", version: 1, item: 0)) && !none.allows(.choose(need: "n-open", choice: "c1")))
        check("and other actions are not its to judge", none.allows(.ready) && none.allows(.older))
    }

    await group("what the real page posts for the mockups' conversation passes the bridge's checks") {
        let page = PresentingPage(folder: folder, layout: .wide, width: wideWidth, appearance: .darkAqua, zoom: 1)
        defer { page.close() }
        guard await page.load() else { return }
        // The records and the waiting question exactly as the page was sent them.
        guard let sent = try? JSONSerialization.jsonObject(with: Data(presentingConversation().utf8)) as? [String: Any],
              let presented = sent["presented"], let data = try? JSONSerialization.data(withJSONObject: presented) else {
            check("the conversation sent has records", false)
            return
        }
        let fixture = TranscriptAction.PresentedChecks(
            records: Dictionary(uniqueKeysWithValues: PresentationRecord.list(from: data, key: "records").map { ($0.id, $0) }), waiting: ["q-present-1"])
        check("the conversation's records are read", fixture.records.count == 2, "\(fixture.records.keys.sorted())")
        _ = await js(page.view, "document.querySelectorAll('.card.present')[2].querySelector('.expand').click()")
        _ = await js(page.view, "document.querySelectorAll('.card.present')[2].querySelectorAll('.card-buttons button')[1].click()")
        _ = await until("the page posts them", { page.posted.contains { $0["type"] as? String == "choose" } })
        let posted = page.posted
        let read = posted.compactMap { TranscriptAction(message: $0) }
        check("every message it posted is read", read.count == posted.count, "\(posted.count) posted, \(read.count) read")
        let kinds = Set(posted.compactMap { $0["type"] as? String })
        check("among them presentedImage, expand and choose", kinds.isSuperset(of: ["presentedImage", "expand", "choose"]), "\(kinds.sorted())")
        let refused = read.filter { !fixture.allows($0) }
        check("and each passes", refused.isEmpty, "refused \(refused)")
    }
}
