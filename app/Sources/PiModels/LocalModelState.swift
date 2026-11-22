import Foundation

/// What a conversation whose model runs on this Mac is told of it: whether it is loading, loaded, stopped or failed.
public struct LocalModelState: Codable, Equatable, Sendable {
    public let name: String
    /// "starting", "ready", "stopping", "stopped" or "failed".
    public let status: String
    /// Since when it is in that state (milliseconds since 1970), when known.
    public let since: Double?
    /// How far loading has got, 0 to 1, when the engine says.
    public let progress: Double?
    /// What the engine says it is doing while it loads, in its own words ("mapping the experts").
    public let stage: String?
    /// Why it could not start, or why it stopped, when it failed.
    public let error: String?
    /// The last lines of its log, when it failed.
    public let lines: [String]?
    public let log: String?
}
