import MenuKit
import SwiftUI

/// The parts of a piece of work the Work tab draws the same way for both kinds of list (docs/projects.md, 3.11): who has
/// it and when it last changed, where it is, the actions the state table gives the person, its comments and the field for
/// another. A project's work is the list pi² keeps or an attached repository's issues, and only the words differ — "work"
/// and "notes" against "issue" and "comments" — so both tabs draw them here rather than each drawing its own (#480).

/// The agents a piece of work can be given to: the project's workers, not its orchestrator, which hands work out rather
/// than takes it, and none an agent has removed through the work tool, which is no longer here to do it. Both kinds of
/// list give work from this one list, in the order the Agents tab of the board shows them (#553).
@MainActor
func workAgents(engine: EngineClient, project: ProjectRow) -> [AgentProfile] {
    engine.allAgents
        .filter { $0.projectId == project.id && $0.id != project.orchestratorId && $0.removedAt == nil }
        .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
}

/// "Forge · sub-chat 17 · 5 min ago", or "Nobody · 5 min ago": who has it and when it last changed.
struct WorkHolderLine: View {
    let engine: EngineClient
    let piece: WorkPiece

    var body: some View {
        HStack(spacing: 5) {
            if let agentId = piece.holderAgentId {
                AgentAvatar(agent: engine.agent(agentId), size: 12)
                Text(engine.agent(agentId)?.name ?? agentId).foregroundStyle(Theme.tx2)
                if let chat = piece.holderConversation {
                    Text("· sub-chat \(chat)").foregroundStyle(Theme.tx3)
                    // The branch its sub-chat works on, as Branches shows it (#596): the tracker already knows it.
                    if let branch = engine.branches[chat]?.branch {
                        Text("·").foregroundStyle(Theme.tx3)
                        Text(branch).foregroundStyle(Theme.tx3)
                    }
                }
            } else {
                Text("Nobody").foregroundStyle(Theme.tx3)
            }
            Text("·").foregroundStyle(Theme.tx3)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(LimitsFormat.ago(piece.updatedAt, now: context.date)).foregroundStyle(Theme.tx3)
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }
}

/// Where it is, who holds it, where it is worked on, and what class of model it needs. The state is said here too: a
/// waiting or blocked piece has a holder who is not working on it.
struct WorkStatusLine: View {
    let engine: EngineClient
    let piece: WorkPiece

    var body: some View {
        HStack(spacing: 6) {
            Text(ProjectWork.name(of: piece.state)).fontWeight(.medium).foregroundStyle(Theme.tx2)
            Text("·").foregroundStyle(Theme.tx3)
            if let agentId = piece.holderAgentId {
                AgentAvatar(agent: engine.agent(agentId), size: 12)
                Text(engine.agent(agentId)?.name ?? agentId).foregroundStyle(Theme.tx2)
                if let chat = piece.holderConversation {
                    Text("· sub-chat \(chat)").foregroundStyle(Theme.tx3)
                    if let branch = engine.branches[chat]?.branch {
                        Text("· \(branch)").foregroundStyle(Theme.tx3).help("The branch its sub-chat works on")
                    }
                }
            } else {
                Text("Nobody has this yet").foregroundStyle(Theme.tx3)
            }
            Text("·").foregroundStyle(Theme.tx3)
            switch piece.modelClass {
            case "local": Text("needs a local model").foregroundStyle(Theme.tx3)
            case "cloud": Text("needs a cloud model").foregroundStyle(Theme.tx3)
            default: Text("not classified").foregroundStyle(Theme.tx3)
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }
}

/// The menu of the project's agents, on a row and in the opened piece. Giving work to one starts it: the engine claims it
/// and starts a sub-chat of the orchestrator's conversation in one step.
struct WorkGiveMenu: View {
    let agents: [AgentProfile]
    let piece: WorkPiece
    /// True for an attached repository's issues, which the tab calls "issues" rather than "work".
    var onGitHub = false
    let give: (AgentProfile) -> Void

    private var noun: String { onGitHub ? "issue" : "work" }

    var body: some View {
        Menu {
            // Each agent's whole name, with its face before it as the row and the state line show it (#553). A native
            // menu draws a row as a text and one picture, so the avatar is drawn into a picture first (#597).
            MenuChoices(agents.map(MenuChoice.init(agent:))) { choice in
                if let agent = agents.first(where: { $0.id == choice.id }) { give(agent) }
            }
        } label: {
            Text("Give to")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("Give this \(noun) to an agent, which starts it working on it")
        .accessibilityLabel("Give \(noun) #\(piece.id) to an agent")
    }
}

/// The actions the state table allows the person from this piece's state (docs/projects.md, 3.11), each with the table's
/// own word for it. On GitHub they are all undone there, not by Undo (5.9).
struct WorkActions: View {
    let piece: WorkPiece
    let agents: [AgentProfile]
    /// True for an attached repository's issues, which the tab calls "issues" rather than "work".
    var onGitHub = false
    /// False while nothing here can be changed: GitHub cannot be reached, or a write of the tab's is on its way.
    var enabled = true
    let act: (_ action: String, _ extra: [String: Any]) -> Void
    let assign: (AgentProfile) -> Void

    private var noun: String { onGitHub ? "issue" : "work" }
    private var held: Bool { ["in_progress", "waiting", "blocked"].contains(piece.state) }

    var body: some View {
        HStack(spacing: 8) {
            if piece.state == "open", !agents.isEmpty {
                WorkGiveMenu(agents: agents, piece: piece, onGitHub: onGitHub, give: assign)
            }
            if held {
                Button("Release") { act("release", [:]) }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .help("Let go of this \(noun): it goes back to open, with nobody on it")
            }
            if ["waiting", "blocked"].contains(piece.state) {
                Button("Resume") { act("resume", [:]) }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .help("Carry on with this \(noun): it goes back to in progress")
            }
            Menu {
                Button("Local model") { act("classify", ["class": "local"]) }
                Button("Cloud model") { act("classify", ["class": "cloud"]) }
                Button("Not classified") { act("classify", ["class": NSNull()]) }
            } label: {
                Text("Classify")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Say what class of model this \(noun) needs")
            .accessibilityLabel("Classify \(noun) #\(piece.id)")
            // Closing work is the final action, so it sits apart from the ones taken while the work carries on.
            Spacer(minLength: 8)
            if held || piece.state == "open" {
                Menu {
                    Button("Close as Done") { act("close", ["as": "done"]) }
                    Button("Close as Dropped") { act("close", ["as": "dropped"]) }
                } label: {
                    Text("Close")
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help(onGitHub ? "Close this issue on GitHub: done, or dropped as not worth doing"
                    : "Close this \(noun): done, or dropped as not worth doing")
                .accessibilityLabel("Close \(noun) #\(piece.id)")
            }
            if ["done", "dropped"].contains(piece.state) {
                Button("Reopen") { act("reopen", [:]) }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    // A repository's issue keeps its result on GitHub, so reopening it here does not clear one.
                    .help(onGitHub ? "Open this issue again on GitHub" : "Open this \(noun) again: its result is cleared")
            }
        }
        .disabled(!enabled)
    }
}

/// The piece's comments, in the order they were added, each with who wrote it and when.
struct WorkNotes: View {
    let engine: EngineClient
    let piece: WorkPiece
    var heading = "Notes"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !piece.notes.isEmpty {
                Text(heading).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tx3)
            }
            ForEach(Array(piece.notes.enumerated()), id: \.offset) { _, note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.tx)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    noteLine(note)
                }
            }
        }
    }

    private func noteLine(_ note: WorkPiece.Note) -> some View {
        let who = note.agentId.map { engine.agent($0)?.name ?? $0 } ?? "You"
        // The time is kept current as the row's is, since the page stays open while a note ages.
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            Text("\(who) · \(LimitsFormat.ago(note.at, now: context.date))")
                .font(.caption)
                .foregroundStyle(Theme.tx3)
        }
    }
}

/// The field for another comment on the opened piece, and what it is called in this list.
struct WorkNoteField: View {
    let piece: WorkPiece
    @Binding var text: String
    /// True for an attached repository's issues, whose comments are called comments.
    var onGitHub = false
    var enabled = true
    let add: () -> Void

    private var field: String { onGitHub ? "comment" : "note" }
    private var noun: String { onGitHub ? "issue" : "work" }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("Add a \(field)", text: $text, prompt: Text("Add a \(field) to this \(noun)"), axis: .vertical)
                .labelsHidden()
                .lineLimit(1...3)
                .accessibilityLabel("New \(field) on \(noun) #\(piece.id)")
                .sendsOnReturn { add() }
            Button("Add", action: add)
                .buttonStyle(.piPrimary)
                .controlSize(.small)
                .disabled(!enabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .panel(radius: 12, border: Theme.line2)
    }
}

/// A piece that was open but is no longer in the list.
struct WorkGone: View {
    /// What this list calls the piece that has gone.
    var words = "This piece of work is no longer in the list."
    let back: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(Theme.tx3)
            Text(words).font(.system(size: 12.5)).foregroundStyle(Theme.tx2)
            Button("All Work", action: back)
                .buttonStyle(.piSecondary)
                .controlSize(.small)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An assignment the project's limit refused, to confirm or leave (docs/projects.md, 8.3): the same card for both lists,
/// since the admission check is the same one and the person's answer is the same.
struct HeldStartCard: View {
    let held: HeldStart
    var enabled = true
    let start: () -> Void
    let leave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Text("Past the project's \(held.limit.name)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.tx)
            }
            Text("Starting \(held.agent.name) on “\(held.piece.title)” goes past it: \(held.limit.reason). Work already running carries on. Start it anyway?")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tx2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Start Anyway", action: start)
                    .buttonStyle(.piPrimary)
                    .controlSize(.small)
                    .disabled(!enabled)
                Button("Leave It", action: leave)
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .panel(radius: 12, border: Theme.warn.opacity(0.55))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
