
import Foundation
import RemoteKit
import Synchronization

/// A channel over one link (docs/iphone.md 5.2): RemoteKit's handshake, the phone first, then RemoteKit's frames in
/// transport messages, the same on every path. The phone pads every frame to 256 bytes.
///
/// Sealing and writing go through one queue, so that messages leave in the order their nonces were taken: two lines
/// sealed by two tasks and sent as each task got there would reach the Mac out of order, which fails the channel.
final class OpenChannel: Sendable {
    let channel: Channel
    let link: any MessageLink
    let path: AppSession.Path
    private let order = Mutex(())
    private let outgoing = Inbox<Data>()
    /// How many of the Mac's transport messages it opened, and the length of the last: for the log, when one fails.
    private let opened = Mutex((count: 0, last: 0))

    private init(channel: Channel, link: any MessageLink, path: AppSession.Path) {
        self.channel = channel
        self.link = link
        self.path = path
        let outgoing = outgoing
        Task {
            while let message = await outgoing.next() {
                do {
                    try await link.send(message)
                } catch {
                    link.close()
                    return
                }
            }
        }
    }

    /// Runs `handshake` over `link`: this side's message, then the Mac's within `limit`. A link that closes, a message
    /// that does not read, or none in time ends it, and the link is closed.
    static func open(_ handshake: ChannelHandshake, over link: any MessageLink, path: AppSession.Path, within limit: Duration = .seconds(10)) async throws -> OpenChannel {
        do {
            try await link.send(try handshake.writeMessage())
            guard let answer = try await link.inbox.next(within: limit) else { throw LinkError.closed }
            try handshake.readMessage(answer)
            let channel = try handshake.channel()
            channel.padding = Frame.paddingBlock
            return OpenChannel(channel: channel, link: link, path: path)
        } catch {
            link.close()
            throw error
        }
    }

    func send(line: Data) throws {
        try order.withLock { _ in
            for message in try channel.seal(line: line) { outgoing.push(message) }
        }
    }

    func send(_ line: ControlLine) throws {
        try send(line: line.line)
    }

    func sendAck(_ count: UInt64) throws {
        try order.withLock { _ in outgoing.push(try channel.sealAck(count)) }
    }

    func sendPing() throws {
        try order.withLock { _ in outgoing.push(try channel.sealPing()) }
    }

    /// Ends the channel with `bye`, then closes the link once what was queued has gone.
    func close() {
        try? order.withLock { _ in outgoing.push(try channel.sealBye()) }
        outgoing.finish()
        let link = link
        Task {
            // The writer drains what is queued; a short wait lets the bye leave before the link goes.
            try? await Task.sleep(for: .milliseconds(200))
            link.close()
        }
    }

    /// Closes the link at once, without `bye`: after the channel failed, or the Mac's word was not believed.
    func drop() {
        outgoing.finish()
        link.close()
    }

    /// The next thing the Mac sent: nil once the link closed, or the channel ended or failed. A message that does not
    /// open fails the channel for good (RemoteKit's `Channel`), and the link is dropped.
    func next(within limit: Duration? = nil) async throws -> ChannelEvent? {
        while true {
            let message: Data?
            if let limit { message = try await link.inbox.next(within: limit) } else { message = await link.inbox.next() }
            guard let message else { return nil }
            do {
                opened.withLock { $0 = ($0.count + 1, message.count) }
                // A part of a longer line gives nothing yet.
                if let event = try channel.open(message) { return event }
            } catch {
                drop()
                let (count, last) = opened.withLock { $0 }
                throw OpenChannelFailure(after: count, length: last, error: error)
            }
        }
    }

    /// The next whole line, skipping pings and acks: nil once the channel ends.
    func nextLine(within limit: Duration) async throws -> Data? {
        let deadline = ContinuousClock.now + limit
        while true {
            let left = deadline - .now
            guard left > .zero else { throw LinkError.timedOut }
            switch try await next(within: left) {
            case let .line(line): return line
            case .ack, .ping: continue
            case .bye, nil: return nil
            }
        }
    }
}

/// A transport message that did not open: which one it was, by count and length, for the log.
struct OpenChannelFailure: Error, CustomStringConvertible {
    let after: Int
    let length: Int
    let error: any Error
    var description: String { "message \(after), \(length) bytes: \(error)" }
}
