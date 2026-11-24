
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

    /// The session is over: the client hears that the connection closed, and asks for the next transport.
    func end(_ why: String) {
        guard ended == nil else { return }
        ended = why
        let handler = handler
        self.handler = nil
        handler?(.closed(why))
    }
}
