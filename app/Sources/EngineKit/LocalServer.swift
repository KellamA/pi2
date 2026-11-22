import PiModels

// Models run on this Mac (#291): what the engine's `local.running` event lists. The views are the app's
// (LocalModelViews.swift); see docs/local-models-running.md.

/// A model running on this Mac, as the engine's `local.running` event lists it.
public struct LocalServer: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// "starting", "ready" or "stopping".
    public let status: String
    public let startedAt: Double
    public let readyAt: Double?
    public let progress: Double?
    public let stage: String?
    /// Bytes its processes hold in memory, at the engine's last look: its own and those it started.
    public let memory: Double?
    /// The conversations using it.
    public let users: [Int]
    /// When it stops for want of anyone using it, while that is counting down.
    public let stopsAt: Double?
    public let log: String
}

struct LocalRunningEvent: Decodable { let running: [LocalServer] }

extension JSONValue {
    /// This `local` event with one download's progress, from a `local.progress` event, in place of what it said.
    func replacingDownload(_ download: JSONValue) -> JSONValue {
        guard case .object(var status) = self, case .array(let downloads)? = status["downloads"], let id = download["id"] else { return self }
        status["downloads"] = .array(downloads.map { $0["id"] == id ? download : $0 })
        return .object(status)
    }
}
