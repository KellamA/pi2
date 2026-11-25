import Foundation
import PiModels

// What agents presented (#946): `PresentationRecord` reads `presented.list` as engine/src/presented.ts sends it, every
// field of a version and an item, a page's snapshot in each of its states, a question with each kind of answer, and the
// network switch with its changes; it ignores fields it does not know; and a record it cannot read is left out of the
// list, not the list's end. Written as the engine's records are (`PresentedDocShape`), with nothing the app adds.

func checkPresented() {
    let list = """
        {"items": [
          {"id": "p1", "later": {"field": true}, "versions": [
            {"version": 1, "callId": "call-a", "createdAt": 1760000000000, "title": "Sign-in screen", "future": 1,
             "items": [
               {"label": "A", "caption": "Light", "kind": "picture", "name": "shots/a.png", "mimeType": "image/png",
                "sha256": "\(String(repeating: "a", count: 64))", "bytes": 1234, "files": 1, "width": 640, "height": 480,
                "snapshot": null, "drawn": null},
               {"label": "B", "caption": null, "kind": "page", "name": "mock/index.html", "mimeType": "text/html",
                "sha256": "\(String(repeating: "b", count: 64))", "bytes": 4096, "files": 3, "width": 1280, "height": 1900,
                "snapshot": {"state": "drawn", "sha256": "\(String(repeating: "c", count: 64))"},
                "drawn": {"loadMs": 412, "blank": false, "console": ["console log: hi"], "blocked": ["https://example.com/x.js"]}},
               {"label": "C", "caption": null, "kind": "page", "name": "two/index.html", "mimeType": "text/html",
                "sha256": "\(String(repeating: "d", count: 64))", "bytes": 10, "files": 1, "width": null, "height": null,
                "snapshot": {"state": "pending"}, "drawn": null},
               {"label": "D", "caption": null, "kind": "page", "name": "three/index.html", "mimeType": "text/html",
                "sha256": "\(String(repeating: "e", count: 64))", "bytes": 10, "files": 1, "width": null, "height": null,
                "snapshot": {"state": "failed", "reason": "it did not finish loading"}, "drawn": null}
             ],
             "question": {"text": "Which one?", "choices": [{"id": "c1", "label": "Use A"}, {"id": "c2", "label": "Neither"}],
                          "words": true, "need": "inbox-7", "answer": null},
             "network": {"allowed": true, "changes": [{"allow": true, "at": 1760000001000}]}},
            {"version": 2, "callId": "call-b", "createdAt": 1760000002000, "title": "Sign-in, again",
             "items": [{"label": "A", "caption": null, "kind": "picture", "name": "a.svg", "mimeType": "image/svg+xml",
                        "sha256": "\(String(repeating: "f", count: 64))", "bytes": 99, "files": 1, "width": null, "height": null,
                        "snapshot": null, "drawn": null}],
             "question": {"text": "Q", "choices": [{"id": "c1", "label": "Use A"}], "words": true, "need": "n12", "answer": {"chose": "Use A"}},
             "network": {"allowed": false, "changes": []}}
          ]},
          {"id": "x1", "versions": []},
          {"id": "p2", "versions": [{"version": 1, "callId": "c", "createdAt": 1, "title": "t", "items": [
             {"label": "A", "caption": null, "kind": "page", "name": "p.html", "mimeType": "text/html", "sha256": "", "bytes": 1,
              "files": 1, "width": null, "height": null, "snapshot": {"state": "drawing"}, "drawn": null}],
             "question": null, "network": {"allowed": false, "changes": []}}]},
          {"id": "p3", "versions": [{"version": 1, "callId": "c3", "createdAt": 1, "title": "t", "items": [],
             "question": {"text": "Q", "choices": [], "words": true, "need": "n1", "answer": {"ended": "messaged"}},
             "network": {"allowed": false, "changes": []}},
            {"version": 2, "callId": "c4", "createdAt": 2, "title": "t", "items": [],
             "question": {"text": "Q", "choices": [], "words": true, "need": "n2", "answer": {"words": "Bigger, please"}},
             "network": {"allowed": false, "changes": []}}]},
          "not a record"
        ]}
        """
    let records = PresentationRecord.list(from: Data(list.utf8))
    func expect(_ condition: Bool, _ what: String) { if !condition { fail("presented: \(what)") } }
    expect(records.map(\.id) == ["p1", "p3"], "the list should keep p1 and p3 and leave out x1, p2 and the string, not \(records.map(\.id))")
    guard let p1 = records.first, let v1 = p1.version(1), let v2 = p1.version(2) else { fail("presented: p1 has not both versions") }
    expect(p1.latest?.version == 2, "p1's newest version is 2")
    expect(v1.callId == "call-a" && v1.title == "Sign-in screen" && v1.createdAt == 1_760_000_000_000 && v1.items.count == 4, "v1's fields")
    let a = v1.items[0], b = v1.items[1]
    expect(a.kind == .picture && a.label == "A" && a.caption == "Light" && a.name == "shots/a.png" && a.mimeType == "image/png"
        && a.bytes == 1234 && a.files == 1 && a.width == 640 && a.height == 480 && a.snapshot == nil && a.drawn == nil, "a picture's fields")
    expect(b.kind == .page && b.caption == nil && b.snapshot == .drawn(sha256: String(repeating: "c", count: 64)) && b.height == 1900, "a drawn page")
    expect(b.drawn == PresentedDrawn(loadMs: 412, blank: false, console: ["console log: hi"], blocked: ["https://example.com/x.js"]), "a page's findings")
    expect(v1.items[2].snapshot == .pending && v1.items[2].width == nil, "a pending page")
    expect(v1.items[3].snapshot == .failed(reason: "it did not finish loading"), "a failed page")
    expect(v1.question?.need == "inbox-7" && v1.question?.choices.map(\.id) == ["c1", "c2"] && v1.question?.isOpen == true, "an open question")
    expect(v1.network == PresentedNetwork(allowed: true, changes: [.init(allow: true, at: 1_760_000_001_000)]), "the network switch and its change")
    expect(v2.question?.answer == .chose("Use A") && v2.network.allowed == false, "an answered question, the network off")
    expect(records[1].versions.map(\.question?.answer) == [.ended("messaged"), .words("Bigger, please")], "an ended question and one answered in words")

    // What the app sends the page is the record again, as the engine's shape: read back, it is the same.
    guard let encoded = try? JSONEncoder().encode(["items": records]) else { fail("presented: the records cannot be written") }
    expect(PresentationRecord.list(from: encoded) == records, "records written and read again are not the same")
    guard let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any], let first = (object["items"] as? [[String: Any]])?.first,
          let version = (first["versions"] as? [[String: Any]])?.first, let items = version["items"] as? [[String: Any]] else {
        fail("presented: the records written are not the engine's shape")
    }
    expect((items[1]["snapshot"] as? [String: Any])?["state"] as? String == "drawn", "a snapshot is written with its state")
    expect(((version["question"] as? [String: Any])?["choices"] as? [[String: Any]])?.first?["label"] as? String == "Use A", "a question's choices are written")

    // Not a list at all, or none: nothing, never a failure.
    expect(PresentationRecord.list(from: Data("[]".utf8)).isEmpty && PresentationRecord.list(from: Data("{\"items\": 3}".utf8)).isEmpty, "a list that is not one")
    expect(PresentationRecord.isID("p1") && PresentationRecord.isID("p123456789") && !PresentationRecord.isID("p0") && !PresentationRecord.isID("p01")
        && !PresentationRecord.isID("p1234567890") && !PresentationRecord.isID("p") && !PresentationRecord.isID("p١") && !PresentationRecord.isID("q1"), "presentation ids")
    let ref = PresentationRef(conversation: 42, presentation: "p1")
    expect(ref.conversationId == "42" && ref.conversation == 42 && ref == PresentationRef(conversationId: "42", presentation: "p1"), "a presentation's reference")
    print("pi2-client-check: presented records read as the engine sends them (\(records.count) of 5 kept)")
}
