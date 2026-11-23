
import Foundation

/// What the demo mode answers, and how (docs/iphone.md 9.4; docs/iphone-app.md, "The demo mode"). `DemoTransport` hands
/// each request the screens send to the answer of its method here, which reads and changes `DemoWorld`, the recording as
/// it stands, and answers as the engine would: a result, or a refusal in the engine's words. A request no answer here
/// takes is refused with a line saying the demo does not do it, and changes nothing.
///
/// Each feature keeps its answers in a file of its own in this folder, as a table by method, and adds one line to
/// `features` below. Answers do what the engine does, in the shape it does it: they never invent a kind of result or event
/// the engine does not send.
@MainActor
enum DemoScript {
    /// Every feature's answers. A screen's issue that needs one more adds its table here, in a line of its own.
    static let features: [[String: DemoAnswer]] = [
        conversations,  // Script/ConversationAnswers.swift (#684, #687): open, close, shown, older, submit, abort, withdraw,
                        // continue, conversation.image
        needs,          // Script/NeedsAnswers.swift (#684, #686): needs.list, needs.answer, inbox.decide, inbox.answer
        library,        // Script/LibraryAnswers.swift (#685, #687): conversation.create (a chat), .pin, .archive, .unarchive,
                        // search
        projects,       // Script/ProjectAnswers.swift (#685, #688): projects.set, .rename, .archive, .startFresh, .watch
        usage,          // Script/UsageAnswers.swift (#697): usage.setBudget, limits.refresh
    ]

    /// The answers by method. Two features answering the same method is a mistake, which the tests catch.
    static let answers: [String: DemoAnswer] = features.reduce(into: [:]) { all, feature in
        all.merge(feature) { first, _ in first }
    }

    /// The methods answered more than once across `features`, for the test that none is.
    static var answeredTwice: [String] {
        var seen = Set<String>()
        return features.flatMap(\.keys).filter { !seen.insert($0).inserted }.sorted()
    }

    /// The line answering `request`, as the engine would write it.
    static func reply(to request: DemoRequest, in world: DemoWorld) -> [String: Any] {
        guard let answer = answers[request.method] else {
            world.unanswered.append(request.method)
            return ["id": request.id, "error": "The demo does not do \(request.method): nothing was changed. On a Mac paired with this iPhone, pi² does it."]
        }
        do {
            return ["id": request.id, "result": try answer(request, world)]
        } catch let refusal as DemoRefusal {
            return ["id": request.id, "error": refusal.message]
        } catch {
            return ["id": request.id, "error": error.localizedDescription]
        }
    }
}

/// One request's answer: it reads the request, changes the world (which sends the events that follow), and returns the
/// result, or throws `DemoRefusal` with the engine's words for a refusal.
typealias DemoAnswer = @MainActor (DemoRequest, DemoWorld) throws -> [String: Any]

/// A request as a screen sent it through the client: `{ id, method, params }`.
struct DemoRequest {
    let id: Int
    let method: String
    let params: [String: Any]

    init(id: Int, method: String, params: [String: Any] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// Reads one line the client sent, or nil for one that is not a request.
    init?(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = (object["id"] as? NSNumber)?.intValue, let method = object["method"] as? String else { return nil }
        self.init(id: id, method: method, params: object["params"] as? [String: Any] ?? [:])
    }

    func int(_ key: String) -> Int? { (params[key] as? NSNumber)?.intValue }
    func string(_ key: String) -> String? { params[key] as? String }

    /// The parameter `key` as a whole number, or the engine's refusal.
    func requireInt(_ key: String) throws -> Int {
        guard let value = int(key) else { throw DemoRefusal("\(key) must be a number") }
        return value
    }

    /// The parameter `key` as text, or the engine's refusal.
    func requireString(_ key: String) throws -> String {
        guard let value = string(key) else { throw DemoRefusal("\(key) must be text") }
        return value
    }
}

/// A refusal, in the words the engine uses for it.
struct DemoRefusal: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
