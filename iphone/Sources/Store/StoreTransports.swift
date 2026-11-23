import EngineKit
import Foundation

/// Carries the Mac's lines on to the session as they are, and keeps each in the phone's store as it passes, so that
/// the cache is always the last state the phone saw. `AppSession` wraps the channel's transport in it:
/// `session.start(RecordingTransport(channel, store: store), as: .connected(path))`.
@MainActor
final class RecordingTransport: EngineTransport {
    private let inner: any EngineTransport
    private let store: PhoneStore
    /// The part of a line that came without its line break yet.
    private var partial = Data()

    init(_ inner: any EngineTransport, store: PhoneStore) {
        self.inner = inner
        self.store = store
    }

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        inner.start { [weak self] event in
            if case .received(let data) = event { self?.keep(data) }
            if case .closed = event { self?.store.saveNow() }
            if case .failed = event { self?.store.saveNow() }
            handler(event)
        }
    }

    func send(_ data: Data) {
        inner.send(data)
    }

    func cancel() {
        inner.cancel()
        store.saveNow()
    }

    private func keep(_ data: Data) {
        partial.append(data)
        guard let last = partial.lastIndex(of: 0x0A) else { return }
        let whole = partial[partial.startIndex...last]
        store.take(lines: Data(whole))
        partial = Data(partial[partial.index(after: last)...])
    }
}

/// What the session is shown while the Mac is out of reach: the last state the phone saw, from its store, through the
/// same client, so every screen draws it as it was (docs/design/iphone.md, "The phone when the Mac is asleep or out of
/// reach"). `AppSession` starts it in place of the channel:
/// `session.start(CachedTransport(store.cache, outbox: outbox), as: .outOfReach(lastSeen: store.lastHeard))`.
///
/// It is ready at once and sends the state's lines; a conversation's come when it is opened, if it is kept. What the
/// person writes meanwhile goes to the Outbox when the Outbox takes it (`writes`: a message, a stop, an answer), and is
/// answered `{ "outbox": <the item's id> }`; anything else is refused with why. Nothing it is sent changes the state.
@MainActor
final class CachedTransport: EngineTransport {
    /// What happened to a request the person made while the Mac is out of reach.
    enum Write {
        /// Kept in the Outbox, under this id.
        case kept(String)
        /// Not kept, with why, in the person's words.
        case refused(String)
    }

    static let needsTheMac = "Your Mac can't be reached, and this needs it. pi² shows what it last sent; try again once it can be reached."

    private let cache: StateCache
    private let writes: @MainActor (_ method: String, _ params: [String: Any]) -> Write
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?

    init(_ cache: StateCache, writes: @escaping @MainActor (_ method: String, _ params: [String: Any]) -> Write = { _, _ in .refused(CachedTransport.needsTheMac) }) {
        self.cache = cache
        self.writes = writes
    }

    /// With the Outbox taking what it may.
    convenience init(_ cache: StateCache, outbox: Outbox) {
        self.init(cache) { [weak outbox] method, params in
            guard let outbox else { return .refused(CachedTransport.needsTheMac) }
            return outbox.write(method, params)
        }
    }

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        self.handler = handler
        let lines = cache.stateLines
        Task { @MainActor [weak self] in
            self?.handler?(.ready)
            if !lines.isEmpty { self?.handler?(.received(lines)) }
        }
    }

    func send(_ data: Data) {
        guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = request["id"] as? Int, let method = request["method"] as? String else { return }
        let params = request["params"] as? [String: Any] ?? [:]
        var reply = Data()
        switch method {
        case "conversation.open":
            if let conversation = params["id"] as? Int, let line = cache.conversationLine(conversation) {
                reply.append(line)
                reply.append(Self.line(["id": id, "result": [String: Any]()]))
            } else {
                reply.append(Self.line(["id": id, "error": "This conversation is not kept on this iPhone. It opens once your Mac can be reached."]))
            }
        case "conversation.close", "conversations.shown", "conversation.older":
            reply.append(Self.line(["id": id, "result": [String: Any]()]))
        default:
            switch writes(method, params) {
            case .kept(let item):
                reply.append(Self.line(["id": id, "result": ["outbox": item]]))
            case .refused(let why):
                reply.append(Self.line(["id": id, "error": why]))
            }
        }
        // Answered after the request is sent, as a connection would.
        Task { @MainActor [weak self] in self?.handler?(.received(reply)) }
    }

    func cancel() {
        handler = nil
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }
}
