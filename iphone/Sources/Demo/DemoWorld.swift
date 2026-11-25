
import Foundation

/// What the demo mode's engine knows, and changes as it is answered: the recording (`Recording/demo-session.jsonl`,
/// made by `scripts/demo-recording` from the scripted demo model of a throwaway copy) read into the latest event of each
/// kind and each conversation's entries and state, all in memory. Nothing is written anywhere, so leaving the demo, or
/// quitting the app, forgets every change.
///
/// The answers in `Script/` read it and change it through `change`, `append` and `changeState`, which send the event a
/// client that changed it would get, as the engine sends it: the whole event again for a kind such as `needs`, and the
/// new entries with the conversation's state for an open conversation.
@MainActor
final class DemoWorld {
    struct Conversation {
        var items: [[String: Any]]
        var state: [String: Any]
    }

    /// Where every event and answer goes: the transport, which hands it to the client.
    var send: (Data) -> Void = { _ in }
    /// How long the scripted steps take, as a share of the time they are written with: 0 runs them at once, for tests.
    var pace: Double = 1

    /// The kinds of event in the order the recording first sent them, and the latest of each.
    private(set) var kinds: [String] = []
    private var events: [String: [String: Any]] = [:]
    private(set) var conversations: [Int: Conversation] = [:]
    /// The engine's answers the recording kept for what its events do not hold, such as a pull request's diff: each a
    /// method, the parameters it was asked with, and the result (`answer` lines, which `scripts/demo-recording` writes).
    private(set) var recordedAnswers: [(method: String, params: [String: Any], result: [String: Any])] = []
    /// The conversations the client has open, which it is sent the changes of.
    private(set) var opened: Set<Int> = []
    /// The methods the client asked for that no answer of the script takes, in order: a screen that sends one needs its
    /// answer added in `Script/` (the demo's test fails on any).
    var unanswered: [String] = []
    /// Every request the client sent, in order, with the refusal it was answered with, if any: what the demo's test reads
    /// to find a screen whose request the demo does not answer.
    var asked: [(method: String, refusal: String?)] = []
    /// What a feature's answers keep between requests, by a key of their own (such as messages waiting their turn).
    var kept: [String: Any] = [:]

    private var lastItemID = 0
    private var lastSubmissionID = 0
    private var steps: [Int: Task<Void, Never>] = [:]
    private var lastStep = 0

    /// Reads a recording. Its times are moved by how long ago it was made, so that what it shows happened just now.
    init(recording: String, now: Date = Date()) {
        var lines: [[String: Any]] = []
        var recordedAt: Double?
        for line in recording.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let recorded = object["recorded"] as? [String: Any] {
                recordedAt = (recorded["at"] as? NSNumber)?.doubleValue
            } else {
                lines.append(object)
            }
        }
        let shift = recordedAt.map { now.timeIntervalSince1970 * 1000 - $0 } ?? 0
        for var line in lines {
            if let recordedAt, shift != 0 { line = Self.moved(line, by: shift, near: recordedAt) as? [String: Any] ?? line }
            if let answer = line["answer"] as? [String: Any], let method = answer["method"] as? String {
                recordedAnswers.append((method, answer["params"] as? [String: Any] ?? [:], answer["result"] as? [String: Any] ?? [:]))
                continue
            }
            guard let kind = line["event"] as? String else { continue }
            if kind == "conversation", let id = (line["id"] as? NSNumber)?.intValue {
                let items = line["items"] as? [[String: Any]] ?? []
                conversations[id] = Conversation(items: items, state: line["state"] as? [String: Any] ?? [:])
                for item in items { lastItemID = max(lastItemID, (item["id"] as? NSNumber)?.intValue ?? 0) }
            } else {
                if events[kind] == nil { kinds.append(kind) }
                events[kind] = line
            }
        }
    }

    /// Every time in `value` within a quarter of a year before the recording was made (milliseconds since 1970, as the
    /// engine sends times), moved by `shift`.
    private static func moved(_ value: Any, by shift: Double, near recordedAt: Double) -> Any {
        switch value {
        case let object as [String: Any]:
            return object.mapValues { moved($0, by: shift, near: recordedAt) }
        case let array as [Any]:
            return array.map { moved($0, by: shift, near: recordedAt) }
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            let time = number.doubleValue
            guard time > recordedAt - 90 * 86_400_000, time < recordedAt + 86_400_000 else { return number }
            return time.rounded() == time ? NSNumber(value: Int64(time + shift.rounded())) : NSNumber(value: time + shift)
        default:
            return value
        }
    }

    // MARK: - Reading

    /// The latest event of a kind, as the client last got it.
    func event(_ kind: String) -> [String: Any]? { events[kind] }

    /// The engine's answer the recording kept to `method` asked with every parameter in `params` as it is there.
    func recordedAnswer(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        recordedAnswers.first { answer in
            answer.method == method && answer.params.allSatisfy { key, value in
                params[key].map { NSDictionary(dictionary: [key: $0]).isEqual(to: [key: value]) } ?? false
            }
        }?.result
    }

    /// Now, in milliseconds since 1970, as the engine writes times.
    var now: Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    /// Every event of the greeting, in the order the recording sent them, as a connection to the engine first gets them.
    func greeting() -> Data {
        var data = Data()
        for kind in kinds { if let event = events[kind] { data.append(Self.line(event)) } }
        return data
    }

    // MARK: - Changing

    /// Changes the latest event of `kind` and sends it whole, as the engine sends that kind again whenever it changes.
    func change(_ kind: String, _ body: (inout [String: Any]) -> Void) {
        var event = events[kind] ?? ["event": kind]
        body(&event)
        if events[kind] == nil { kinds.append(kind) }
        events[kind] = event
        send(Self.line(event))
    }

    /// Opens a conversation for the client: sends it whole, and its changes from then on.
    func open(_ id: Int) throws {
        guard let conversation = conversations[id] else { throw DemoRefusal("Unknown conversation: \(id)") }
        opened.insert(id)
        send(Self.line(["event": "conversation", "id": id, "reset": true, "items": conversation.items, "state": conversation.state, "earlier": 0, "more": false]))
    }

    func close(_ id: Int) {
        opened.remove(id)
    }

    /// A new conversation, with its first entries and its state, which the client can then open.
    func make(_ id: Int, items: [[String: Any]] = [], state: [String: Any]) {
        conversations[id] = Conversation(items: items, state: state)
    }

    /// Adds entries to a conversation and changes its state, and sends both to a client that has it open.
    func append(_ items: [[String: Any]], to id: Int, state body: (inout [String: Any]) -> Void = { _ in }) {
        guard var conversation = conversations[id] else { return }
        conversation.items.append(contentsOf: items)
        body(&conversation.state)
        conversations[id] = conversation
        guard opened.contains(id) else { return }
        send(Self.line(["event": "conversation", "id": id, "reset": false, "items": items, "state": conversation.state]))
    }

    /// Changes a conversation's state only, as while an answer is written.
    func changeState(of id: Int, _ body: (inout [String: Any]) -> Void) {
        append([], to: id, state: body)
    }

    /// A new entry's id: the engine numbers the entries of every conversation in one sequence, and the conversations too.
    func newItemID() -> Int {
        lastItemID += 1
        return lastItemID
    }

    func newSubmissionID() -> Int {
        lastSubmissionID += 1
        return lastSubmissionID
    }

    // MARK: - Time

    /// Runs `step` after `seconds` (times `pace`), as the engine does what follows an answer a moment later. Returns a
    /// number to cancel it by.
    @discardableResult
    func after(_ seconds: Double, _ step: @escaping @MainActor (DemoWorld) -> Void) -> Int {
        lastStep += 1
        let number = lastStep
        let delay = seconds * pace
        steps[number] = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.steps[number] = nil
            step(self)
        }
        return number
    }

    func cancel(_ step: Int) {
        steps.removeValue(forKey: step)?.cancel()
    }

    /// Stops every step still to come, as the demo is left.
    func stop() {
        for step in steps.values { step.cancel() }
        steps.removeAll()
        send = { _ in }
    }

    static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }
}
