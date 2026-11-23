import EngineKit
import PiModels
import SwiftUI

/// A project's work list, as the Mac's Work tab has it: the list in its states (open, in progress, waiting, blocked,
/// done) behind a segmented control, a piece of work with its text, its notes and Give to an agent, and filing
/// (docs/design/iphone.md, "The Work tab, and a pull request with its diff"). The hub's Work tab draws it inline
/// (`RouteView(.work(project: id), placement: .inline)`); a piece of work opens as a screen of its own
/// (`.work(project: id, item: n)`), and a pull request in the list opens with `.pullRequest(project:number:)`.
///
/// Everything it shows is read from the session's client, from the `work` event for the list pi² keeps or the `github`
/// event for an attached repository, as the Mac reads them; every change is a request through the same client
/// (`WorkRequests`).
struct WorkView: View {
    /// The project's id, as `ProjectRow.id`.
    let projectID: String
    /// The piece of work it opens on, by its number; nil for the list.
    let itemID: Int?

    @Environment(AppSession.self) private var session

    init(projectID: String, itemID: Int? = nil) {
        self.projectID = projectID
        self.itemID = itemID
    }

    var body: some View {
        let engine = session.engine
        if let project = engine.workProject(projectID) {
            let shown = WorkShown(engine: engine, project: project)
            if let itemID {
                WorkItemScreen(project: project, listing: shown.listing, agents: shown.agents, itemID: itemID,
                               initialHeld: shown.held(itemID), sample: shown.sample)
            } else {
                WorkListScreen(project: project, listing: shown.listing, agents: shown.agents, sample: shown.sample)
            }
        } else {
            WorkMissing(waiting: engine.status != .connected || !engine.hasLoadedLibrary)
        }
    }
}

/// What the screens are given to draw: the project's listing and agents, from the client; in a debug build asked for a
/// sample (`PI2_WORK_SAMPLE`), a plainly labelled sample listing in place of the Mac's.
private struct WorkShown {
    let listing: WorkListing
    let agents: [AgentProfile]
    let sample: String?
    private let heldSample: Bool

    @MainActor
    init(engine: EngineSession<MessageField>, project: ProjectRow) {
        let listing = engine.workListing(project)
        let agents = engine.workAgents(project)
        self.agents = agents
        #if DEBUG
        if let sample = WorkSample.current,
           let replaced = WorkSample.listing(sample, project: project, agents: agents, real: listing) {
            self.listing = replaced
            self.sample = sample
            heldSample = sample == "held"
            return
        }
        #endif
        self.listing = listing
        sample = nil
        heldSample = false
    }

    /// Debug builds only: the sample start the project's limit held, for the piece shown.
    func held(_ itemID: Int) -> WorkHeldStart? {
        #if DEBUG
        guard heldSample, let item = listing.item(itemID), let agent = agents.first else { return nil }
        return WorkSample.heldStart(item: item, agent: agent)
        #else
        return nil
        #endif
    }
}

/// What the screen shows when the project is not among the Mac's: while the engine's lists are still coming, a wait;
/// once they have come, that the Mac has no such project.
private struct WorkMissing: View {
    let waiting: Bool

    var body: some View {
        if waiting {
            ProgressView("Waiting for your Mac…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No such project", systemImage: "questionmark.folder",
                description: Text("Your Mac has no project by this name now. It may have been deleted.")
            )
        }
    }
}
