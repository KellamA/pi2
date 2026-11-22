import Foundation

/// How a session reaches the engine: on the Mac, its Unix socket (`UnixSocketTransport`); on the phone, the channel to
/// pi² Remote (docs/iphone.md 5.1, built in `iphone/`). It carries the engine's lines both ways as bytes, and the session
/// finds the lines in what comes.
@MainActor
public protocol EngineTransport: AnyObject {
    /// Starts connecting. `handler` is told once when the transport is ready, then of every piece of bytes that comes, and
    /// once when it failed or closed.
    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void)
    /// Sends one request, a line of JSON ending with a line break.
    func send(_ data: Data)
    /// Stops it, as the session lets it go.
    func cancel()
}

public enum EngineTransportEvent {
    case ready
    case received(Data)
    /// It could not connect, or can no longer: why, for the host's log.
    case failed(String)
    /// The other end closed it, or reading from it failed: why, for the host's log.
    case closed(String)
}
