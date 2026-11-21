import MenuKit
import SwiftUI

/// The parts of the Work tab both kinds of list draw the same way (docs/projects.md, 3.11): the list's bar, its groups
/// and rows, the top of an opened piece with its one line of where it is, the bar of its actions, its text, its comments
/// and the field for another. A project's work is the list pi² keeps or an attached repository's issues, and only the
/// words differ — "work" and "notes" against "issue" and "comments" — so both tabs draw them here rather than each
/// drawing its own (#480). The page has the manner of the Notes and Rules tabs: one inset, light headings, rows with no
/// card around them, one border on a field, and at most one primary button in view (#599).

/// The agents a piece of work can be given to: the project's workers, not its orchestrator, which hands work out rather
/// than takes it, and none an agent has removed through the work tool, which is no longer here to do it. Both kinds of
/// list give work from this one list, in the order the Agents tab of the board shows them (#553).
@MainActor
func workAgents(engine: EngineClient, project: ProjectRow) -> [AgentProfile] {
    engine.allAgents
        .filter { $0.projectId == project.id && $0.id != project.orchestratorId && $0.removedAt == nil }
        .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
}

/// The one inset the Work tab's parts share, as the Notes and Rules tabs' do.
enum WorkInset {
    static let value: CGFloat = 12
}

/// "5 min ago", kept current while the page stays open.
struct WorkAgo: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(LimitsFormat.ago(date, now: context.date))
        }
    }
}

/// A row's quiet facts, after its title: its number, who has it as a small face (the name on hover), and when it last
/// changed.
struct WorkFacts: View {
    let engine: EngineClient
    let piece: WorkPiece

    var body: some View {
        HStack(spacing: 6) {
            Text("#\(piece.id)").font(Theme.mono)
            if let agentId = piece.holderAgentId {
                AgentAvatar(agent: engine.agent(agentId), size: 14)
                    .help(holder(agentId))
                    .accessibilityLabel(holder(agentId))
                    .accessibilityHidden(false)
            }
            WorkAgo(date: piece.updatedAt)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.tx3)
        .lineLimit(1)
        .fixedSize()
    }

    /// "Forge has it, in sub-chat 17, on fix-the-thing": who, and where it is worked on, with the branch its sub-chat
    /// works on as Branches shows it (#596), which the opened page says in its line.
    private func holder(_ agentId: String) -> String {
        var words = "\(engine.agent(agentId)?.name ?? agentId) has it"
        if let chat = piece.holderConversation {
            words += ", in sub-chat \(chat)"
            if let branch = engine.branches[chat]?.branch { words += ", on \(branch)" }
        }
        return words
    }
}

/// Where it is, who holds it, where it is worked on, and what class of model it needs, on one line: the state is said
/// here too, since a waiting or blocked piece has a holder who is not working on it. A change on its way shows here at
/// once (`pending`), before the engine answers. In a narrow board the line says less rather than cut off what it says.
struct WorkStatusLine: View {
    let engine: EngineClient
    let piece: WorkPiece
    /// A change on its way, in a word: "Closing…".
    var pending: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(full: true)
            line(full: false)
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }

    private func line(full: Bool) -> some View {
        HStack(spacing: 6) {
            if let pending {
                ProgressView().controlSize(.mini)
                Text(pending).foregroundStyle(Theme.tx2)
                Text("·").foregroundStyle(Theme.tx3)
            }
            Text(ProjectWork.name(of: piece.state)).fontWeight(.medium).foregroundStyle(Theme.tx2)
            Text("·").foregroundStyle(Theme.tx3)
            if let agentId = piece.holderAgentId {
                AgentAvatar(agent: engine.agent(agentId), size: 14)
                Text(engine.agent(agentId)?.name ?? agentId).foregroundStyle(Theme.tx2)
                if full, let chat = piece.holderConversation {
                    Text("in sub-chat \(chat)").foregroundStyle(Theme.tx3)
                    // The branch its sub-chat works on, as Branches shows it (#596): the tracker already knows it.
                    if let branch = engine.branches[chat]?.branch {
                        Text("on \(branch)").foregroundStyle(Theme.tx3).help("The branch its sub-chat works on")
                    }
                }
            } else {
                Text(full ? "Nobody has it" : "Nobody").foregroundStyle(Theme.tx3)
            }
            Text("·").foregroundStyle(Theme.tx3)
            switch piece.modelClass {
            case "local": Text(full ? "needs a local model" : "local model").foregroundStyle(Theme.tx3)
            case "cloud": Text(full ? "needs a cloud model" : "cloud model").foregroundStyle(Theme.tx3)
            default: Text("not classified").foregroundStyle(Theme.tx3)
            }
            if full {
                Text("·").foregroundStyle(Theme.tx3)
                WorkAgo(date: piece.updatedAt).foregroundStyle(Theme.tx3)
            }
        }
        .fixedSize()
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
    /// Puts the title and text in fields to change; nil where they cannot be changed.
    var edit: (() -> Void)?

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
            if let edit {
                Button("Edit", systemImage: "pencil", action: edit)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.piGhost)
                    .controlSize(.small)
                    .help("Change the title and text of this \(noun)")
                    .accessibilityLabel("Edit \(noun) #\(piece.id)")
            }
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

/// The piece's comments, in the order they were added, each under who wrote it and when, quietly; its text drawn as the
/// piece's own is. A comment the person has sent and the engine has not answered for yet shows at its end, faded.
struct WorkNotes: View {
    let engine: EngineClient
    let piece: WorkPiece
    var heading = "Notes"
    /// What the person has just sent, on its way.
    var sending: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !piece.notes.isEmpty || sending != nil {
                WorkSectionHeading(text: heading, count: piece.notes.count)
            }
            ForEach(Array(piece.notes.enumerated()), id: \.offset) { _, note in
                VStack(alignment: .leading, spacing: 4) {
                    byline(note.agentId) { WorkAgo(date: note.at) }
                    WorkProse(text: note.text)
                }
            }
            if let sending {
                VStack(alignment: .leading, spacing: 4) {
                    byline(nil) {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("sending")
                        }
                    }
                    WorkProse(text: sending)
                }
                .opacity(0.6)
            }
        }
    }

    /// Who wrote it, with their face when it is an agent, and when.
    private func byline<When: View>(_ agentId: String?, @ViewBuilder when: () -> When) -> some View {
        HStack(spacing: 6) {
            if let agentId {
                AgentAvatar(agent: engine.agent(agentId), size: 14)
                Text(engine.agent(agentId)?.name ?? agentId).fontWeight(.medium).foregroundStyle(Theme.tx2)
            } else {
                Text("You").fontWeight(.medium).foregroundStyle(Theme.tx2)
            }
            Text("·").foregroundStyle(Theme.tx3)
            when().foregroundStyle(Theme.tx3)
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }
}

/// The field for another comment on the opened piece, at the foot of the page as the Notes tab's field is: one border,
/// the field's own being left out, and the one primary button in view.
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
        WorkFootField {
            TextField("Add a \(field)", text: $text, prompt: Text("Add a \(field) to this \(noun)"), axis: .vertical)
                .textFieldStyle(.plain)
                .labelsHidden()
                .lineLimit(1...4)
                .disabled(!enabled)
                .accessibilityLabel("New \(field) on \(noun) #\(piece.id)")
                .sendsOnReturn { add() }
            Button("Add", action: add)
                .buttonStyle(.piPrimary)
                .disabled(!enabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// A field at the foot of the page, under a line, as the Notes and Rules tabs have theirs: the field and its button in
/// one panel.
struct WorkFootField<Content: View>: View {
    /// A line under the panel, saying what the field does.
    var note: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                content
            }
            .padding(WorkInset.value)
            .panel(radius: 12, border: Theme.line2)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.tx3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, WorkInset.value)
            }
        }
        .padding(.horizontal, WorkInset.value).padding(.top, 8).padding(.bottom, WorkInset.value)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
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

// MARK: - The list

/// The bar over the list: where the list comes from, when it was read, and, while a read runs behind it, one small
/// spinner; the list's one action at its end. The list under it is what was read last, at once, whatever the read does.
struct WorkListBar<Trailing: View>: View {
    /// "KellamA/pi2", or what the list kept by pi² calls itself.
    let source: String
    var icon = "chevron.left.forwardslash.chevron.right"
    /// When the list was last read; nil for a list kept by pi², which needs no reading.
    var readAt: Date?
    /// A read under way behind the list.
    var reading = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10.5))
            Text(source).foregroundStyle(Theme.tx2).lineLimit(1)
            if let readAt {
                Text("·")
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("read \(LimitsFormat.ago(readAt, now: context.date))").lineLimit(1)
                }
                .layoutPriority(-1)
            }
            if reading {
                ProgressView()
                    .controlSize(.mini)
                    .help("Reading it again from GitHub")
                    .accessibilityLabel("Reading it again from GitHub")
            }
            Spacer(minLength: 8)
            trailing
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.tx3)
        .padding(.horizontal, WorkInset.value)
        .frame(height: 38)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// A heading over a part of the page, light, with how many it holds.
struct WorkSectionHeading: View {
    let text: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.tx3)
            if let count {
                Text(String(count)).font(.system(size: 11.5)).foregroundStyle(Theme.tx3).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Which sections of the Work tab's list are folded before the person says (#599): Done, as the owner asked, and the
/// pull requests merged or closed, which are the pull requests' Done and as long. Every other section starts open. Both kinds of list name their sections the same way: a state of the
/// table in docs/projects.md, 3.11, or `pulls` and `closedPulls`. What the person chooses is kept by project
/// (`ProjectHubs.workFolded`).
enum WorkFolds {
    static let foldedAtFirst: Set<String> = ["done", "closedPulls"]
}

/// A section's heading in the list: a small chevron, its name and how many it holds, light. A click on it folds the
/// section or unfolds it, and so do Space and Return when it has the keyboard's focus, and the Left and Right arrows, as
/// a disclosure does; folded, the heading stays with its count, which follows what the section gains.
struct WorkGroupHeading: View {
    let name: String
    let count: Int
    let folded: Bool
    let toggle: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(folded ? 0 : 90))
                .foregroundStyle(Theme.tx3)
                .frame(width: 10)
            WorkSectionHeading(text: name, count: count)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .contentShape(.rect)
        .background(focused ? Theme.card : Color.clear, in: .rect(cornerRadius: 6))
        .onTapGesture(perform: toggle)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.space, .return, .leftArrow, .rightArrow]) { press in
            switch press.key {
            case .leftArrow: if !folded { toggle() }
            case .rightArrow: if folded { toggle() }
            default: toggle()
            }
            return .handled
        }
        .help(folded ? "Show this section" : "Fold this section")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(count)")
        .accessibilityValue(folded ? "folded" : "open")
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityHint(folded ? "Shows this section" : "Folds this section")
        .accessibilityAction(.default, toggle)
    }
}

/// One row of the list, on one line: the title first, where it can be read, then its quiet facts; the row's usual next
/// step at its end, where it has one. No card around it: the row lights up under the pointer. A change on its way shows
/// in place of the facts, so the row says at once what was asked of it.
struct WorkRow<Facts: View, Trailing: View>: View {
    let title: String
    let label: String
    let hint: String
    var pending: String?
    let open: () -> Void
    @ViewBuilder let facts: Facts
    @ViewBuilder let trailing: Trailing

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tx)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let pending {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text(pending)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tx2)
                        .fixedSize()
                    } else {
                        facts
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityLabel(label)
            .accessibilityHint(hint)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 30)
        .background(hovered ? Theme.card : Color.clear, in: .rect(cornerRadius: 6))
        .onHover { hovered = $0 }
    }
}

/// The page's frame while a list is read for the first time, with nothing read yet to show: the bar, and the groups'
/// places with rows still to come, calm, rather than an empty tab or a list that says there is nothing.
struct WorkLoading: View {
    let words: String
    var groups = ["Pull requests", "Open", "In progress"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(words).font(.system(size: 12.5)).foregroundStyle(Theme.tx2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                VStack(alignment: .leading, spacing: 4) {
                    WorkSectionHeading(text: group).padding(.horizontal, 8)
                    ForEach(0..<(index == 0 ? 1 : 3), id: \.self) { row in
                        WorkPlaceholder(width: [0.7, 0.55, 0.62][row % 3]).frame(height: 30)
                    }
                }
            }
        }
        .padding(WorkInset.value)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A quiet bar where text is still to come, a share of the width.
struct WorkPlaceholder: View {
    var width: CGFloat = 0.6

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.card2)
                .frame(width: max(0, (geometry.size.width - 16) * width), height: 9)
                .frame(maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 8)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - One piece, opened

/// The top of an opened piece: the way back and its number, its title, and the one line of where it is. It stays put
/// above what scrolls, with the bar of its actions under it.
struct WorkPageTop<Line: View>: View {
    let number: String
    let title: String
    /// The rest of it is being read: one small spinner by its number.
    var busy = false
    let back: () -> Void
    @ViewBuilder let line: Line

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: back) {
                    Label("All Work", systemImage: "chevron.left")
                }
                .buttonStyle(.piGhost)
                .controlSize(.small)
                .help("Back to the list")
                Spacer(minLength: 4)
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                        .help("Reading it from GitHub")
                        .accessibilityLabel("Reading it from GitHub")
                }
                Text(number).font(Theme.mono).foregroundStyle(Theme.tx3)
            }
            .padding(.leading, -6)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.tx)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            line
        }
        .padding(.horizontal, WorkInset.value).padding(.top, 8).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The bar of an opened piece's actions, under its top, which stays put while its text scrolls.
struct WorkActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.horizontal, WorkInset.value).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// Where the rest of an opened piece is still being read: what the list knew shows already, and this keeps the place
/// of what is to come.
struct WorkFilling: View {
    let words: String
    var lines = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(words).font(.system(size: 12)).foregroundStyle(Theme.tx3)
            }
            ForEach(0..<lines, id: \.self) { line in
                WorkPlaceholder(width: line == lines - 1 ? 0.5 : 0.92).frame(height: 14).padding(.horizontal, -8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Text written in Markdown, as an issue's or a comment's is, drawn as the conversation draws an answer's words
/// (`MessageText`: bold, italics, code and links, with code blocks set apart), and with the blocks an issue's text has —
/// headings, lists and quotes — drawn as such rather than left as typed. HTML comments, which GitHub does not show, are
/// left out.
struct WorkProse: View {
    let text: String

    private enum Block {
        case paragraph(String)
        case heading(String, level: Int)
        case item(String, marker: String, depth: Int)
        case quote(String)
        case code(String)
    }

    private var blocks: [Block] {
        let cleaned = text.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        for line in cleaned.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else if let match = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flush()
                blocks.append(.heading(String(match.2), level: match.1.count))
            } else if let match = line.firstMatch(of: /^(\s*)([-*+]|\d+[.)])\s+(.*)$/) {
                flush()
                let marker = String(match.2)
                blocks.append(.item(String(match.3), marker: marker.first?.isNumber == true ? marker : "•", depth: match.1.count / 2))
            } else if let match = trimmed.firstMatch(of: /^>\s?(.*)$/) {
                flush()
                blocks.append(.quote(String(match.1)))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let words):
                    prose(words)
                case .heading(let words, let level):
                    Text(inlineMarkdown(words))
                        .font(.system(size: level <= 2 ? 14 : 13, weight: .semibold))
                        .foregroundStyle(Theme.tx)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                case .item(let words, let marker, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(Theme.tx3).font(.system(size: 13))
                        prose(words)
                    }
                    .padding(.leading, CGFloat(depth) * 14)
                case .quote(let words):
                    prose(words, colour: Theme.tx2)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.line2).frame(width: 2) }
                case .code(let lines):
                    Text(lines)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.tx)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .panel(radius: 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func prose(_ words: String, colour: Color = Theme.tx) -> some View {
        Text(inlineMarkdown(words))
            .font(.system(size: 13))
            .foregroundStyle(colour)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
