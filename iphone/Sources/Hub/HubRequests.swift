import EngineKit
import Foundation
import Observation
import os
import PiModels

/// The requests a project's hub and the Dashboard's pages send, each made as the Mac app makes it, through the same
/// client (`session.engine`), so that they work as they are the day a Mac answers them. Each answers nil once the engine
/// has taken the request, or the engine's own words when it refused it or could not be reached, for the screen to say
/// where it was asked. Nothing here answers for the engine.
@MainActor
enum HubRequests {
    /// The project's switch for reports waking the orchestrator (docs/projects.md, 3.10), as the Mac's Now tab sets it
    /// (`ProjectNowTab.wakeBinding`: `projects.set`).
    static func setWake(_ engine: EngineSession<MessageField>, project: String, on: Bool) async -> String? {
        await failure { try await engine.call("projects.set", ["id": project, "settings": ["wakeOnReports": on]]) }
    }

    /// Stops a run where it is, and the command it is running, as the Mac's working row's Stop does (`WorkingRow.stop`:
    /// `abort`). Its conversation stays as it is and can be continued.
    static func stop(_ engine: EngineSession<MessageField>, conversation: Int) async -> String? {
        await failure { try await engine.call("abort", ["id": conversation]) }
    }

    /// Makes the conversation with the orchestrator of a project that has none yet, as the Mac's hub does as it opens
    /// (`ProjectHubs.startConversation`: `projects.startFresh`). The `projects` event then names it.
    static func startConversation(_ engine: EngineSession<MessageField>, project: String) async -> String? {
        await failure { try await engine.call("projects.startFresh", ["id": project]) }
    }

    /// Sends the project's orchestrator a message, as the Mac's strip under a Dashboard column does (`HubStrip.send`):
    /// steered into the answer it is writing, if it is writing one, else queued.
    static func message(_ engine: EngineSession<MessageField>, _ text: String, to project: ProjectRow) async -> String? {
        guard let id = project.conversation else { return "The conversation with the orchestrator has not started yet." }
        let busy = engine.conversations.first { $0.id == id }?.busy == true
        switch await engine.submit(text, to: id, steer: busy) {
        case .sent: return nil
        case .refused, .unconfirmed: return engine.lastError ?? "The message was not sent."
        }
    }

    /// Whether a request sent now goes to the Mac (or the demo, or the recording): connected, and the client's transport
    /// ready. While the phone reaches for the Mac it shows its store's last state, which refuses what needs the Mac with
    /// a line saying so (`CachedTransport`): a request the hub sends by itself, not tapped, waits for this.
    nonisolated static func isLive(_ connection: AppSession.Connection, engineConnected: Bool) -> Bool {
        switch connection {
        case .connected, .demo: engineConnected
        case .notPaired, .connecting, .outOfReach: false
        }
    }

    static func isLive(_ session: AppSession) -> Bool {
        isLive(session.connection, engineConnected: session.engine.status == .connected)
    }

    /// The engine's words when `request` fails, nil when it is answered.
    private static func failure(_ request: () async throws -> Void) async -> String? {
        do {
            try await request()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// What the phone has told the engine it shows of a project, through `projects.watch` (docs/projects.md, 4.2, 10.3), as
/// the Mac's `ProjectTabWatch` does: while a hub's Now tab shows, the engine reads the project's GitHub listing again.
/// The engine keeps one watch for each connection, so every send names the project last shown and all of its tabs on
/// screen; a tab that goes tells the engine what is left. The Work tab (#694) says so through the same `shows` and
/// `hides`. A refusal changes nothing on screen: the watch only keeps a listing fresh.
///
/// The engine keeps the watch with the connection and forgets it with it, and a send made while the phone was still
/// reaching for the Mac, showing its store's last state, is refused there. So the watch follows the client's connection
/// (`follow`): each time it reaches the Mac, on a new transport or after none, what shows is sent again. Tried against
/// a copy (#688, #941), a hub or a Work screen opened at launch was otherwise never watched once the Mac was reached.
@MainActor
final class HubTabWatch {
    static let shared = HubTabWatch()

    private var shown: [String: Set<HubTab>] = [:]
    private var order: [String] = []
    /// The last send, so that the requests reach the engine in the order they were made.
    private var sending: Task<Void, Never>?
    /// The client whose connection the watch follows, and what it was when last looked at.
    private weak var followed: EngineSession<MessageField>?
    private var reached: Reach?

    func shows(_ project: String, tab: HubTab, engine: EngineSession<MessageField>) {
        follow(engine)
        var tabs = shown[project] ?? []
        guard !tabs.contains(tab) else { return }
        tabs.insert(tab)
        shown[project] = tabs
        order.removeAll { $0 == project }
        order.append(project)
        send(engine)
    }

    func hides(_ project: String, tab: HubTab, engine: EngineSession<MessageField>) {
        guard var tabs = shown[project], tabs.contains(tab) else { return }
        tabs.remove(tab)
        shown[project] = tabs
        send(engine)
    }

    /// Sends the watch as it stands, if any tab shows: to a connection that has just reached the Mac.
    func resend(_ engine: EngineSession<MessageField>) {
        guard shown.values.contains(where: { !$0.isEmpty }) else { return }
        send(engine)
    }

    /// Whether the client reaches the Mac, and on which transport: a new one is a new session at the engine.
    struct Reach: Equatable {
        let live: Bool
        let transport: ObjectIdentifier?

        @MainActor init(_ engine: EngineSession<MessageField>) {
            if let session = engine.host as? AppSession {
                live = HubRequests.isLive(session)
            } else {
                live = engine.status == .connected
            }
            transport = engine.transport.map { ObjectIdentifier($0) }
        }

        /// Whether the watch is to be sent again on going from `before` to this: the Mac reached, or reached anew.
        func sendsAgain(after before: Reach?) -> Bool {
            live && (before?.live != true || before?.transport != transport)
        }
    }

    /// Follows `engine`'s connection from now on, as long as it lasts.
    private func follow(_ engine: EngineSession<MessageField>) {
        guard followed !== engine else { return }
        followed = engine
        reached = Reach(engine)
        track(engine)
    }

    private func track(_ engine: EngineSession<MessageField>) {
        withObservationTracking {
            _ = Reach(engine)
        } onChange: { [weak self] in
            Task { @MainActor in self?.connectionChanged() }
        }
    }

    private func connectionChanged() {
        guard let engine = followed else { return }
        let now = Reach(engine)
        if now.sendsAgain(after: reached) { resend(engine) }
        reached = now
        track(engine)
    }

    /// What the next `projects.watch` says: the newest project that still has a tab on screen, with every tab of it that
    /// does, or none.
    var parameters: [String: Any] {
        if let project = order.last(where: { !(shown[$0] ?? []).isEmpty }) {
            return ["projectId": project, "tabs": (shown[project] ?? []).map(\.rawValue).sorted()]
        }
        return ["projectId": NSNull(), "tabs": [String]()]
    }

    private func send(_ engine: EngineSession<MessageField>) {
        let params = parameters
        let before = sending
        let log = log
        sending = Task {
            _ = await before?.value
            // The engine keeps no trace of a watch, and a device's log leaves out what only reads (docs/iphone.md 4.2),
            // so the phone's own log says what it asked and how it was answered.
            let tabs = (params["tabs"] as? [String] ?? []).joined(separator: ",")
            do {
                try await engine.call("projects.watch", params)
                log.notice("projects.watch [\(tabs, privacy: .public)]: answered")
            } catch {
                log.notice("projects.watch [\(tabs, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private let log = Logger(subsystem: "dev.pi2.ios", category: "hub")
}
