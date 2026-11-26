import EngineKit
import Foundation
import PiModels

// An event is never taken for an answer (#946): the engine's `conversation.presented` and `present.draw` carry an `id`
// of their own (a conversation's number, a draw's), and a session that did not know them took them for the answer to
// whatever request had that number, which then came back as `null`. A request is made through a transport of the check's
// own, each event is played to the session with the request's number, and the request must still be waiting until its
// real answer comes.

@MainActor
final class Loopback: EngineTransport {
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?
    private(set) var sent: [Data] = []

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        self.handler = handler
        handler(.ready)
    }
    func send(_ data: Data) { sent.append(data) }
    func cancel() { handler = nil }
    func play(_ line: String) { handler?(.received(Data((line + "\n").utf8))) }
}

@MainActor
func checkEventsNotAnswers() async {
    let session = EngineSession<NoDraft>()
    let transport = Loopback()
    session.connect(transport)
    let events = [
        #"{"event":"conversation.presented","id":%d,"record":{"id":"p1","versions":[]}}"#,
        #"{"event":"present.draw","id":%d,"requestId":"present-1","conversationId":%d,"presentation":"p1","version":1,"item":0,"width":1280,"height":800}"#,
    ]
    for event in events {
        var answer: JSONValue?
        let before = transport.sent.count
        let request = Task { @MainActor in answer = try? await session.call("engine.info") }
        // The request goes out before the session waits for its answer.
        for _ in 0..<100 where transport.sent.count == before { await Task.yield() }
        guard transport.sent.count > before, let sent = transport.sent.last, let object = try? JSONSerialization.jsonObject(with: sent) as? [String: Any],
              let id = object["id"] as? Int else { fail("events: the request was not sent") }
        transport.play(event.replacingOccurrences(of: "%d", with: String(id)))
        for _ in 0..<20 { await Task.yield() }
        let name = event.contains("present.draw") ? "present.draw" : "conversation.presented"
        if answer != nil { fail("events: \(name) with the number of a waiting request was taken for its answer (\(Dump.text(answer!)))") }
        transport.play(#"{"id":\#(id),"result":{"build":"real"}}"#)
        await request.value
        if answer?["build"]?.stringValue != "real" { fail("events: after \(name), the request's real answer did not reach it") }
    }
    print("pi2-client-check: conversation.presented and present.draw are taken as events, never as the answer to a request")
}
