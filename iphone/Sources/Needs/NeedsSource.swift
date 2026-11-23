import EngineKit
import PiModels

/// What the cards are drawn from: the engine's list of what needs the person (`needs`), the Inbox's items for the
/// approvals and held questions in it (`inbox`), and the projects, for their names. Read from the session's client as
/// the Mac's views read it; a debug build may add sample cards (`NeedsSamples`) to draw kinds the recording lacks.
@MainActor
struct NeedsSource {
    let needs: [NeedItem]
    let inbox: [InboxItem]
    let projects: [ProjectRow]

    init(needs: [NeedItem], inbox: [InboxItem], projects: [ProjectRow]) {
        self.needs = needs
        self.inbox = inbox
        self.projects = projects
    }

    init(_ engine: EngineSession<MessageField>) {
        var needs = engine.needs
        var inbox = engine.inbox
        #if DEBUG
        if let samples = NeedsSamples.current {
            if samples.only { needs = [] }
            needs += samples.needs
            inbox += samples.inbox
        }
        #endif
        self.init(needs: needs, inbox: inbox, projects: engine.projects)
    }

    /// The cards of one project, or of every one, newest first; two asked at the same moment keep the engine's order.
    func shown(in projectID: String?) -> [NeedItem] {
        needs.enumerated()
            .filter { projectID == nil || $0.element.projectId == projectID }
            .sorted { a, b in a.element.createdAt != b.element.createdAt ? a.element.createdAt > b.element.createdAt : a.offset < b.offset }
            .map(\.element)
    }

    func need(_ id: String) -> NeedItem? {
        needs.first { $0.id == id }
    }

    /// The Inbox's item for an approval or a question, which shares its id; nil for every other kind.
    func item(for need: NeedItem) -> InboxItem? {
        guard need.kind == "approval" || need.kind == "question" else { return nil }
        return inbox.first { $0.id == need.id && $0.kind == need.kind }
    }

    func projectName(_ id: String?) -> String? {
        id.flatMap { id in projects.first { $0.id == id }?.name }
    }
}
