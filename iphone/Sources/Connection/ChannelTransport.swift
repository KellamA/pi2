
import EngineKit
import Foundation

/// The engine's lines over the channel (docs/iphone.md 5.6): the `EngineTransport` EngineKit's client reads, so every
/// screen works over the channel as it does over the replay, unchanged.
///
/// One transport is one session at the engine (5.8). It is ready once the phone is attached, and stays so across a
/// resume on a new channel, by either path, with no new greeting; the lines the Mac had not sent before the drop come
/// after. When the session cannot be resumed (`resume: false`, `refused` with `resume`, the session ended), it closes,
/// as a connection to an engine that restarted does, and `RemoteConnection.transport()` gives the next session's.
@MainActor
final class ChannelTransport: EngineTransport {
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?
    private weak var connection: RemoteConnection?
    private var attached = false
    /// The Mac's lines that came before the client started reading.
    private var held: [Data] = []
    private(set) var ended: String?
    /// The count of the engine's lines this session has had, for `attach`'s `received` and the channel's `ack`.
    private(set) var received: UInt64 = 0
    /// The client's lines sent on the present channel that the Mac has not counted yet (its `ack`, 5.8), oldest first,
    /// each with its place among the channel's lines: the Mac counts a channel's lines from its start.
    private var uncounted: [(place: UInt64, line: Data)] = []
    private var sentOnChannel: UInt64 = 0

    init(connection: RemoteConnection) {
        self.connection = connection
    }

    // MARK: - EngineTransport

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        if let ended {
            handler(.closed(ended))
            return
        }
        self.handler = handler
        guard attached else { return }
        handler(.ready)
        let lines = held
        held = []
        for line in lines { handler(.received(line)) }
    }

    func send(_ data: Data) {
        guard ended == nil else { return }
        var line = data
        while line.last == 0x0A { line.removeLast() }
        guard !line.isEmpty else { return }
        connection?.send(line: line, from: self)
    }

    func cancel() {
        handler = nil
        connection?.cancelled(self)
    }

    // MARK: - From the connection

    var isAttached: Bool { attached }

    /// The session was attached: the client may send from now on.
    func becameAttached() {
        guard !attached, ended == nil else { return }
        attached = true
        handler?(.ready)
    }

    /// One of the engine's lines, as the channel brought it.
    func deliver(_ line: Data) {
        guard ended == nil else { return }
        received += 1
        var withBreak = line
        withBreak.append(0x0A)
        if let handler, attached { handler(.received(withBreak)) } else { held.append(withBreak) }
    }

    /// A new channel carries the session: the Mac counts its lines from none.
    func channelStarted() {
        sentOnChannel = 0
        uncounted = []
    }

    /// `line` went into the present channel's queue, whole: the next of the channel's lines the Mac counts.
    func went(_ line: Data) {
        sentOnChannel += 1
        uncounted.append((sentOnChannel, line))
    }

    /// The Mac's ack: it had the present channel's first `count` lines.
    func counted(_ count: UInt64) {
        uncounted.removeAll { $0.place <= count }
    }

    /// The present channel ended. The lines on it the Mac had not counted may never have reached it: a channel that drops
    /// mid-line loses the rest of the line, and the Mac takes only whole lines. Their calls fail as unanswered
    /// (`EngineTransportEvent.cut`), so that a message is sent again with its request id, on the next channel, as after a
    /// reconnect; were they left, nothing would answer them until the session ended (#939). A line the Mac had, and had not
    /// yet counted (it counts within a second), is among them: the engine takes a message sent again with its request id
    /// once, and a request of another kind answers its caller that it may not have arrived.
    func channelEnded() {
        let lines = uncounted
        uncounted = []
        guard ended == nil, attached, let handler else { return }
        let ids = lines.compactMap { (try? JSONSerialization.jsonObject(with: $0.line) as? [String: Any])?["id"] as? Int }
        if !ids.isEmpty { handler(.cut(ids)) }
    }

    /// The session is over: the client hears that the connection closed, and asks for the next transport.
    func end(_ why: String) {
        guard ended == nil else { return }
        ended = why
        let handler = handler
        self.handler = nil
        handler?(.closed(why))
    }
}
