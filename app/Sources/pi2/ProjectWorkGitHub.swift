import EngineKit
import PiModels
import SwiftUI

// What the Work tab reads of the engine's `github` event — `GitHubPull`, `GitHubUnknownWrite` and `GitHubWork` — is in
// PiModels (GitHubWork.swift, #828), shared with the iPhone app; what stays here is the tab's own reading of it through
// the client (`WorkListings`) and its views.

/// The listings as the tab reads them, each worked out once for each `github` event rather than at every look: the
/// event can hold hundreds of issues, and the tab once worked all of them out again for every row it drew (#599).
@MainActor
enum WorkListings {
    private static var github: [String: (generation: Int, work: GitHubWork)] = [:]

    static func github(_ engine: EngineClient, project: String) -> GitHubWork {
        // Read through the observed slot, so a view that asks is drawn again when the event changes.
        let value = engine.extras["github"]
        let generation = engine.extras.generation("github")
        if let kept = github[project], kept.generation == generation { return kept.work }
        let work = GitHubWork(value?["projects"]?[project])
        github[project] = (generation, work)
        return work
    }
}

/// The board's Work tab for a project whose work is a GitHub repository's issues and pull requests (#480): the pull
/// requests with their checks and what reviewing agents found, with Diff, Merge and Send Back, and the issues grouped as
/// the contract groups them.
///
/// It draws at once from what the engine last read, which the app keeps whatever tab or project is shown, and never
/// waits for `gh` (#599): a read runs behind the list, with one small spinner in its bar while it does, and the rows
/// change in place when it lands. An issue or pull request opened shows what the list knows of it at once and fills in
/// the rest as `github.show` brings it. An action shows at once as on its way, on its row and its page, and settles, or
/// is put back with the engine's words; the rest of the tab stays usable meanwhile.
struct ProjectWorkGitHub: View {
    let model: AppModel
    let project: ProjectRow

    /// The issue or pull request the person opened, by its number.
    private enum Opened: Equatable {
        case issue(Int)
        case pull(Int)

        var key: String {
            switch self {
            case .issue(let number): "issue:\(number)"
            case .pull(let number): "pull:\(number)"
            }
        }
    }

    /// One row of the list as it is laid out: a group's heading, a row, or the space between groups. The list is one lazy
    /// stack of these, so a repository with hundreds of issues draws only the rows in view.
    private enum Entry: Identifiable {
        case heading(id: String, name: String, count: Int, folded: Bool)
        case issue(WorkPiece)
        case pull(GitHubPull)
        case gap(String)

        var id: String {
            switch self {
            case .heading(let id, _, _, _): "heading:\(id)"
            case .issue(let piece): "issue:\(piece.id)"
            case .pull(let pull): "pull:\(pull.number)"
            case .gap(let id): "gap:\(id)"
            }
        }
    }

    @State private var opened: Opened? = ProjectWorkGitHub.openedInPreferences
    /// The diff `github.diff` answered, which shows in place of everything else until the person goes back.
    @State private var diff: ShownDiff?
    @State private var problem: String?
    /// The pull request whose merge waits for the person's word.
    @State private var confirmingMerge: GitHubPull?
    /// What the person is typing to send a pull request back.
    @State private var sendBackText = ""
    /// Whether the opened issue's title and text are in fields to change, and what they hold.
    @State private var editing = false
    @State private var draftTitle = ""
    @State private var draftText = ""
    @State private var noteText = ""
    /// A comment sent and not yet answered for, by the issue it is on: shown at the end of its comments, faded.
    @State private var sending: [Int: String] = [:]
    /// The findings whose words are shown in full, by the finding's id (#573).
    @State private var unfoldedFindings: Set<String> = []
    /// What the person asked for and the engine has not answered yet, by what it is for (`Opened.key`, or a write of
    /// the unknown): shown at once where it is for. While one is on its way, nothing else is sent for the same thing, so
    /// a second click writes nothing twice; the rest of the tab stays usable.
    @State private var pending: [String: WorkPending] = [:]
    /// Issues and pull requests being read whole as they are opened (`github.show`).
    @State private var filling: Set<String> = []
    @State private var refreshing = false
    /// A start the project's limit refused, to confirm or leave (8.3).
    @State private var heldStart: HeldStart?

    struct ShownDiff: Equatable {
        let number: Int
        let text: String
    }

    private var engine: EngineClient { model.engine }

    /// The row a copy was asked to open for a picture, from `WorkRowLaunch.asked` (docs/development.md, "Choosing
    /// what a copy shows"): a copy parked behind every other window cannot be clicked, so this is how a picture of an
    /// opened issue, of the merge question or of a diff is taken.
    private static var openedInPreferences: Opened? {
        guard let asked = WorkRowLaunch.asked else { return nil }
        switch asked {
        case .issue(let number): return .issue(number)
        case .pull(let number), .merge(let number), .diff(let number): return .pull(number)
        }
    }
    private var work: GitHubWork { WorkListings.github(engine, project: project.id) }
    private var repositoryName: String {
        [project.repository?.owner, project.repository?.name].compactMap { $0 }.joined(separator: "/")
    }
    /// The same workers the work list offers: an issue is given to an agent that can take it and is here to do so (#553).
    private var agents: [AgentProfile] { workAgents(engine: engine, project: project) }

    private func openIssue(_ work: GitHubWork) -> WorkPiece? {
        guard case .issue(let number)? = opened else { return nil }
        return work.issues.first { $0.id == number }
    }

    private func openPull(_ work: GitHubWork) -> GitHubPull? {
        guard case .pull(let number)? = opened else { return nil }
        return work.pulls.first { $0.number == number }
    }

    var body: some View {
        let work = self.work
        VStack(spacing: 0) {
            if let diff {
                diffPage(diff)
            } else if let pull = openPull(work) {
                pullPage(pull, work)
            } else if let issue = openIssue(work) {
                issuePage(issue, work)
            } else if let opened, filling.contains(opened.key) || work.firstRead {
                // Opened from a copy's preference before it is in the list: the frame, while it is read.
                VStack(spacing: 0) {
                    WorkPageTop(number: "", title: "", back: { self.opened = nil }) { EmptyView() }
                    WorkFilling(words: "Reading it from GitHub…").padding(WorkInset.value)
                    Spacer(minLength: 0)
                }
            } else if opened != nil {
                WorkGone(words: "This is no longer in the list.", back: { opened = nil })
            } else {
                listPage(work)
            }
            if let held = heldStart {
                HeldStartCard(
                    held: held,
                    enabled: pending["issue:\(held.piece.id)"] == nil,
                    start: { assign(held.piece, to: held.agent, confirming: held.limit) },
                    leave: { heldStart = nil }
                )
            } else if let pull = confirmingMerge {
                mergeCard(pull)
            } else if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(Theme.bad)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, WorkInset.value).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .onChange(of: work.readAt) { _, _ in PerfProbe.workTab("read landed") }
        // A read that lands while one is open can hold less of it than the page shows: read it whole again.
        .onChange(of: openIssue(work)?.partial == true || openPull(work)?.partial == true) { _, partial in
            if partial { fill(opened) }
        }
        .onAppear {
            PerfProbe.workTab("frame drawn")
            // A pull request clicked on the Dashboard opens here (#618), as one clicked in the list does.
            if let number = model.hubs.takePull(for: project.id) {
                opened = .pull(number)
                return
            }
            // A row the preference named is read whole here, as one the person clicked is by the change below.
            fill(opened)
            if case .merge? = WorkRowLaunch.asked, let pull = openPull(work) { confirmingMerge = pull }
            if case .diff? = WorkRowLaunch.asked, openPull(work) != nil { showDiff() }
        }
        .onChange(of: opened) { _, latest in
            problem = nil
            confirmingMerge = nil
            sendBackText = ""
            noteText = ""
            editing = false
            fill(latest)
        }
    }

    // MARK: - The list

    private func listPage(_ work: GitHubWork) -> some View {
        VStack(spacing: 0) {
            WorkListBar(source: repositoryName, readAt: work.readAt, reading: work.reading || refreshing) {
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.piGhost)
                    .controlSize(.small)
                    .disabled(work.reading || refreshing)
                    .help("Read the repository again now")
            }
            banner(work)
            if work.firstRead {
                WorkLoading(words: "Reading \(repositoryName) for the first time. Its issues and pull requests show here as soon as GitHub answers.")
                Spacer(minLength: 0)
            } else if work.issues.isEmpty && work.pulls.isEmpty && work.unknown.isEmpty {
                empty(work)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(work.unknown) { write in
                            unknownCard(write).padding(.horizontal, 8).padding(.bottom, 12)
                        }
                        ForEach(entries(work)) { entry in
                            entryView(entry, work)
                        }
                    }
                    .padding(.horizontal, WorkInset.value - 8).padding(.vertical, WorkInset.value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The list as it is laid out: the open pull requests first, as a section of their own, then the issues by state,
    /// then what was merged or closed in the last seven days. Each folds by its heading, as the person left it in this
    /// project (`ProjectHubs.workFolded`, #599); folded, its heading keeps its count.
    private func entries(_ work: GitHubWork) -> [Entry] {
        var entries: [Entry] = []
        func group(_ id: String, _ name: String, _ rows: [Entry]) {
            guard !rows.isEmpty else { return }
            let folded = model.hubs.workFolded(project.id, section: id)
            if !entries.isEmpty { entries.append(.gap(id)) }
            entries.append(.heading(id: id, name: name, count: rows.count, folded: folded))
            if !folded { entries += rows }
        }
        group("pulls", "Pull requests", work.openPulls.map(Entry.pull))
        for (state, name, items) in work.grouped {
            group(state, name, items.map(Entry.issue))
        }
        group("closedPulls", "Pull requests merged or closed", work.closedPulls.map(Entry.pull))
        return entries
    }

    @ViewBuilder
    private func entryView(_ entry: Entry, _ work: GitHubWork) -> some View {
        switch entry {
        case .heading(let id, let name, let count, let folded):
            WorkGroupHeading(name: name, count: count, folded: folded) {
                model.hubs.setWorkFolded(!folded, section: id, for: project.id)
            }
            .padding(.bottom, 4)
        case .issue(let issue):
            issueRow(issue, work)
        case .pull(let pull):
            pullRow(pull)
        case .gap:
            Color.clear.frame(height: 14)
        }
    }

    /// One calm line when GitHub's last read left something wrong: which it is, and that the list below is the last one
    /// read.
    @ViewBuilder
    private func banner(_ work: GitHubWork) -> some View {
        if work.troubled {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Text(troubleWords(work))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tx2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WorkInset.value).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }

    /// What went wrong, and what the list under it holds: the last listing, read before it went wrong.
    private func troubleWords(_ work: GitHubWork) -> String {
        let read = work.readAt.map { "The last read, \(LimitsFormat.ago($0, now: Date())), is below" }
            ?? "Nothing has been read yet"
        switch work.state {
        case "unreachable":
            return "GitHub cannot be reached. \(read); nothing here can change until it answers."
        case "signed_out":
            let missing = (work.error ?? "").localizedCaseInsensitiveContains("not found")
            return missing
                ? "GitHub's command-line tool gh is not installed on this Mac. \(read); nothing here can change until it is."
                : "gh is not signed in to GitHub. \(read); nothing here can change until it is."
        case "rate_limited":
            return "GitHub's rate limit is reached. \(read); nothing here can change until the hour is up."
        default:
            return "GitHub did not answer clearly. \(read); nothing here can change until it does."
        }
    }

    private func empty(_ work: GitHubWork) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(Theme.tx3)
            Text(work.troubled ? "Nothing was read" : "Nothing open").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.tx)
            Text(work.troubled
                ? "When GitHub answers, this project's issues and pull requests show here."
                : "This repository has no open issues and no open pull requests. The agents file and work on them with their work tool.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.tx2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A write whose outcome pi² could not tell: the person looks at the repository, then says whether it happened.
    private func unknownCard(_ write: GitHubUnknownWrite) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.warn)
                Text("pi² does not know whether this reached GitHub")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.tx)
            }
            Text("Its gh was cut off while it was \(write.summary), \(LimitsFormat.ago(write.at, now: Date())). Look at the repository: if it is there, say it happened; if not, say it did not. Nothing is written again until you say.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tx2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Menu {
                    Button("It Happened") { settle(write, happened: true) }
                    Button("It Did Not") { settle(write, happened: false) }
                } label: {
                    Text("Check Again")
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .disabled(pending["settle:\(write.intent)"] != nil)
                .help("Say whether the write happened, after looking at the repository")
                .accessibilityLabel("Check again whether \(write.summary) happened")
                if pending["settle:\(write.intent)"] != nil { ProgressView().controlSize(.mini) }
            }
        }
        .padding(12)
        .panel(radius: 12, border: Theme.warn.opacity(0.55))
    }

    private func issueRow(_ issue: WorkPiece, _ work: GitHubWork) -> some View {
        let key = Opened.issue(issue.id).key
        return WorkRow(
            title: issue.title, label: "Issue #\(issue.id), \(issue.title)", hint: "Open this issue",
            pending: pending[key]?.word, open: { opened = .issue(issue.id) }
        ) {
            WorkFacts(engine: engine, piece: issue)
        } trailing: {
            // Giving it to an agent is the usual next step only for work nobody has; the rest are on its page.
            if issue.state == "open", issue.holderAgentId == nil, !agents.isEmpty, pending[key] == nil {
                WorkGiveMenu(agents: agents, piece: issue, onGitHub: true, give: { assign(issue, to: $0) })
                    .disabled(work.troubled)
            }
        }
        .onAppear { PerfProbe.workTab("first row drawn") }
    }

    private func pullRow(_ pull: GitHubPull) -> some View {
        WorkRow(
            title: pull.title, label: "Pull request #\(pull.number), \(pull.title)", hint: "Open this pull request",
            pending: pending[Opened.pull(pull.number).key]?.word, open: { opened = .pull(pull.number) }
        ) {
            pullFacts(pull)
        } trailing: {
            EmptyView()
        }
        .onAppear { PerfProbe.workTab("first row drawn") }
    }

    /// A pull request's quiet facts on its row: its number, then its checks and what a reviewing agent last found, as
    /// small marks with their words on hover; a merged or closed one says which instead.
    private func pullFacts(_ pull: GitHubPull) -> some View {
        HStack(spacing: 6) {
            Text("#\(pull.number)").font(Theme.mono)
            if pull.state != "open" {
                Text(pull.state)
            } else {
                if pull.draft { Text("draft") }
                checksMark(pull)
                if let finding = pull.newestFinding {
                    Image(systemName: verdictIcon(finding.verdict))
                        .foregroundStyle(verdictColour(finding.verdict))
                        .help("\(finding.agentName) \(GitHubPull.verdictWords(finding.verdict))")
                        .accessibilityLabel("\(finding.agentName) \(GitHubPull.verdictWords(finding.verdict))")
                }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.tx3)
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private func checksMark(_ pull: GitHubPull) -> some View {
        let icon = switch pull.checks {
        case "passing": "checkmark.circle.fill"
        case "failing": "xmark.circle.fill"
        case "pending": "clock"
        default: ""
        }
        if !icon.isEmpty {
            Image(systemName: icon)
                .foregroundStyle(checksColour(pull))
                .help(pull.checksWords)
                .accessibilityLabel(pull.checksWords)
        }
    }

    private func verdictIcon(_ verdict: String) -> String {
        switch verdict {
        case "approve": "hand.thumbsup.fill"
        case "changes": "exclamationmark.bubble.fill"
        default: "text.bubble"
        }
    }

    private func verdictColour(_ verdict: String) -> Color {
        verdict == "approve" ? Theme.ok : verdict == "changes" ? Theme.warn : Theme.tx3
    }

    private func checksColour(_ pull: GitHubPull) -> Color {
        switch pull.checks {
        case "passing": Theme.ok
        case "failing": Theme.bad
        case "pending": Theme.warn
        default: Theme.tx3
        }
    }

    // MARK: - One issue, opened

    private func issuePage(_ listed: WorkPiece, _ work: GitHubWork) -> some View {
        let key = Opened.issue(listed.id).key
        let issue = listed.showing(pending[key])
        let canChange = !work.troubled && pending[key] == nil
        return VStack(spacing: 0) {
            WorkPageTop(number: "#\(issue.id)", title: issue.title, busy: filling.contains(key), back: { opened = nil }) {
                WorkStatusLine(engine: engine, piece: issue, pending: pending[key]?.word)
            }
            WorkActionBar {
                WorkActions(
                    piece: issue, agents: agents, onGitHub: true, enabled: canChange,
                    act: { action, extra in act(listed, action, extra) },
                    assign: { assign(listed, to: $0) },
                    edit: canChange && !editing && !listed.partial ? { beginEditing(listed) } : nil
                )
                openOnGitHub(listed.url)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(work.unknown) { write in
                        unknownCard(write)
                    }
                    if editing {
                        editor(listed)
                    } else if listed.partial {
                        WorkFilling(words: "Reading its text and comments from GitHub…", lines: 4)
                    } else if listed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No text.").font(.system(size: 13)).foregroundStyle(Theme.tx3)
                    } else {
                        WorkProse(text: listed.text)
                    }
                    if let result = listed.result {
                        VStack(alignment: .leading, spacing: 8) {
                            WorkSectionHeading(text: "What finishing it said was done")
                            WorkProse(text: result)
                        }
                    }
                    if !listed.partial {
                        WorkNotes(engine: engine, piece: listed, heading: "Comments", sending: sending[listed.id])
                    }
                }
                .padding(WorkInset.value)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // While the title and text are being changed, Save is the page's one primary button.
            if !editing {
                WorkNoteField(
                    piece: listed, text: $noteText, onGitHub: true, enabled: canChange,
                    add: { addNote(listed) }
                )
            }
        }
    }

    /// The title and text in fields of their own, each with one border, to change and save or leave.
    private func editor(_ issue: WorkPiece) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $draftTitle, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1...)
                .padding(8)
                .panel(radius: 8, fill: Theme.window, border: Theme.line2)
                .accessibilityLabel("Title of issue #\(issue.id)")
            TextField("Text", text: $draftText, prompt: Text("What needs doing (you can leave this empty)"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(6...)
                .padding(8)
                .panel(radius: 8, fill: Theme.window, border: Theme.line2)
                .accessibilityLabel("Text of issue #\(issue.id)")
            HStack(spacing: 8) {
                Button("Save Changes") { save(issue) }
                    .buttonStyle(.piPrimary)
                    .controlSize(.small)
                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { editing = false }
                    .buttonStyle(.piGhost)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func openOnGitHub(_ address: String?) -> some View {
        if let address, let url = URL(string: address) {
            Button("Open on GitHub", systemImage: "arrow.up.forward.square") { NSWorkspace.shared.open(url) }
                .labelStyle(.iconOnly)
                .buttonStyle(.piGhost)
                .controlSize(.small)
                .help("Open it on GitHub, in the browser")
        }
    }

    // MARK: - One pull request, opened

    private func pullPage(_ pull: GitHubPull, _ work: GitHubWork) -> some View {
        let key = Opened.pull(pull.number).key
        let canChange = !work.troubled && pending[key] == nil && pull.state == "open"
        return VStack(spacing: 0) {
            WorkPageTop(number: "#\(pull.number)", title: pull.title, busy: filling.contains(key), back: { opened = nil }) {
                pullLine(pull, pending: pending[key]?.word)
            }
            WorkActionBar {
                Button("Diff") { showDiff() }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .help("Show what this pull request changes")
                // A merged or closed one has nothing left to merge, and its page says so.
                if pull.state == "open" {
                    Button("Merge") { confirmingMerge = pull }
                        .buttonStyle(.piPrimary)
                        .controlSize(.small)
                        .disabled(!canChange)
                        .help("Merge this pull request into \(pull.base)")
                }
                Spacer(minLength: 8)
                openOnGitHub(pull.url)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(work.unknown) { write in
                        unknownCard(write)
                    }
                    if pull.state != "open" {
                        notice(pull.state == "merged"
                            ? "GitHub merged it into \(pull.base). Nothing here can merge or send it back again."
                            : "GitHub closed it without merging. Nothing here can merge or send it back again.")
                    }
                    if pull.mergeable == "no", pull.state == "open" {
                        notice("GitHub says it conflicts with \(pull.base), so it cannot be merged as it is.")
                    }
                    if pull.partial {
                        WorkFilling(words: "Reading its checks and findings from GitHub…")
                    } else {
                        failingChecksList(pull)
                        findings(pull)
                    }
                }
                .padding(WorkInset.value)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if pull.state == "open" {
                sendBackField(pull, enabled: canChange)
            }
        }
    }

    /// The pull request's one line: its branches, checks, and who opened it, saying less in a narrow board rather than
    /// cutting off what it says.
    private func pullLine(_ pull: GitHubPull, pending: String?) -> some View {
        ViewThatFits(in: .horizontal) {
            pullLineParts(pull, pending: pending, full: true)
            pullLineParts(pull, pending: pending, full: false)
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }

    private func pullLineParts(_ pull: GitHubPull, pending: String?, full: Bool) -> some View {
        HStack(spacing: 6) {
            if let pending {
                ProgressView().controlSize(.mini)
                Text(pending).foregroundStyle(Theme.tx2)
                Text("·").foregroundStyle(Theme.tx3)
            }
            Text(pull.state == "open" ? (pull.draft ? "Draft" : "Open") : pull.state == "merged" ? "Merged" : "Closed")
                .fontWeight(.medium).foregroundStyle(Theme.tx2)
            if full {
                Text("·").foregroundStyle(Theme.tx3)
                Text("\(pull.head) → \(pull.base)").foregroundStyle(Theme.tx3)
            }
            if pull.state == "open", !pull.partial {
                Text("·").foregroundStyle(Theme.tx3)
                Text(pull.checksWords).foregroundStyle(checksColour(pull))
            }
            if full, !pull.author.isEmpty {
                Text("·").foregroundStyle(Theme.tx3)
                Text("from \(pull.author)").foregroundStyle(Theme.tx3)
            }
            if let workItem = pull.work {
                Text("·").foregroundStyle(Theme.tx3)
                Text("fixes #\(workItem)").foregroundStyle(Theme.tx3)
            }
        }
        .fixedSize()
    }

    private func notice(_ words: String) -> some View {
        Text(words)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.tx2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The pull request's checks that failed, each its name opening its page on GitHub in the browser (#573). The
    /// roll-up once said only that some had failed, without which.
    @ViewBuilder
    private func failingChecksList(_ pull: GitHubPull) -> some View {
        if pull.checks == "failing" {
            VStack(alignment: .leading, spacing: 6) {
                WorkSectionHeading(text: "Checks failing", count: pull.failingChecks.isEmpty ? nil : pull.failingChecks.count)
                if pull.failingChecks.isEmpty {
                    notice("GitHub shows which of them under the pull request; pi² only knows that they failed.")
                }
                ForEach(pull.failingChecks) { check in
                    Button {
                        if let url = URL(string: check.url) { NSWorkspace.shared.open(url) }
                    } label: {
                        Label(check.name, systemImage: "xmark.circle.fill")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.bad)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(check.url.isEmpty)
                    .help(check.url.isEmpty ? "This check has no page of its own" : "Open \(check.name) on GitHub")
                    .accessibilityLabel("Failing check \(check.name)")
                }
            }
        }
    }

    /// What reviewing agents found: each verdict, who gave it and when, with its words under the verdict (#573), newest
    /// first, as comments are shown: no box around them.
    private func findings(_ pull: GitHubPull) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkSectionHeading(text: "What reviewing agents found", count: pull.findings.isEmpty ? nil : pull.findings.count)
            if pull.findings.isEmpty {
                Text("No agent has posted a finding on it yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tx3)
            }
            ForEach(pull.findings.sorted { $0.at > $1.at }) { finding in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: verdictIcon(finding.verdict)).foregroundStyle(verdictColour(finding.verdict))
                        Text(capitalised(GitHubPull.verdictWords(finding.verdict)))
                            .fontWeight(.medium)
                            .foregroundStyle(finding.verdict == "approve" ? Theme.ok : finding.verdict == "changes" ? Theme.warn : Theme.tx2)
                        Text(finding.agentName).foregroundStyle(Theme.tx2)
                        Text("·").foregroundStyle(Theme.tx3)
                        WorkAgo(date: finding.at).foregroundStyle(Theme.tx3)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12))
                    .lineLimit(1)
                    if !finding.text.isEmpty {
                        let long = finding.text.count > 280 || finding.text.components(separatedBy: "\n").count > 4
                        if long && !unfoldedFindings.contains(finding.id) {
                            // At most a few lines of a long one, ending where a line ends; the rest is one click away.
                            Text(inlineMarkdown(finding.text))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.tx)
                                .lineSpacing(3)
                                .lineLimit(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            WorkProse(text: finding.text)
                        }
                        if long {
                            Button(unfoldedFindings.contains(finding.id) ? "Show Less" : "Show All") {
                                if unfoldedFindings.contains(finding.id) {
                                    unfoldedFindings.remove(finding.id)
                                } else {
                                    unfoldedFindings.insert(finding.id)
                                }
                            }
                            .buttonStyle(.piGhost)
                            .controlSize(.small)
                            .padding(.leading, -6)
                            .accessibilityLabel(unfoldedFindings.contains(finding.id)
                                ? "Show less of the finding \(finding.agentName) posted"
                                : "Show all of the finding \(finding.agentName) posted")
                        }
                    }
                }
            }
        }
    }

    private func capitalised(_ words: String) -> String {
        words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The field for what to put right, sent with `github.sendBack`, which posts it on the pull request and hands it to
    /// the conversation that opened it (3.11). At the foot of the page, as a comment's field is on an issue's.
    private func sendBackField(_ pull: GitHubPull, enabled: Bool) -> some View {
        WorkFootField(note: pull.openedBy.map { "The reason is posted on the pull request and given to \(PullRequestOpener.words($0, conversations: engine.conversations, agents: engine.allAgents)), which opened it." }
            ?? "The reason is posted on the pull request. Nobody opened it through pi², so no agent is told.") {
            TextField("Send Back", text: $sendBackText, prompt: Text("What to put right"), axis: .vertical)
                .textFieldStyle(.plain)
                .labelsHidden()
                .lineLimit(1...4)
                .disabled(!enabled)
                .accessibilityLabel("What to put right on pull request #\(pull.number)")
                .sendsOnReturn { sendBack(pull) }
            // Merge is the page's primary button; sending back is the other way it goes.
            Button("Send Back") { sendBack(pull) }
                .buttonStyle(.piSecondary)
                .disabled(!enabled || sendBackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Asks first, saying what will be merged into what and that it cannot be undone.
    private func mergeCard(_ pull: GitHubPull) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.merge").foregroundStyle(Theme.warn)
                Text("Merge pull request #\(pull.number) into \(pull.base)?")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.tx)
            }
            Text("“\(pull.title)” goes from \(pull.head) into \(pull.base) on GitHub. It cannot be undone here: merging closes it and may close the work it fixes.\(pull.checks == "failing" ? " Its checks are failing, and GitHub may refuse it for that." : "")")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tx2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Merge") { merge(pull) }
                    .buttonStyle(.piPrimary)
                    .controlSize(.small)
                    .disabled(pending[Opened.pull(pull.number).key] != nil)
                Button("Cancel") { confirmingMerge = nil }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .panel(radius: 12, border: Theme.warn.opacity(0.55))
        .padding(.horizontal, WorkInset.value).padding(.vertical, 10)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: - The diff

    /// The app has no diff view of its own, so the engine's text shows in a plain page that scrolls, a line each.
    private func diffPage(_ diff: ShownDiff) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    self.diff = nil
                } label: {
                    Label("Pull Request", systemImage: "chevron.left")
                }
                .buttonStyle(.piGhost)
                .controlSize(.small)
                .help("Back to the pull request")
                Spacer(minLength: 4)
                Text("Diff of #\(diff.number)").font(Theme.mono).foregroundStyle(Theme.tx3)
            }
            .padding(.horizontal, WorkInset.value - 6).padding(.vertical, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : String(line))
                            .font(Theme.mono)
                            .foregroundStyle(diffColour(String(line)))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(WorkInset.value)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A diff shorter than the page starts at its top left, as a file does, rather than in the middle of it.
            .defaultScrollAnchor(.topLeading)
        }
    }

    /// A changed line tinted as code hosts tint it: taken out in red, put in in green.
    private func diffColour(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return Theme.tx3 }
        if line.hasPrefix("+") { return Theme.ok }
        if line.hasPrefix("-") { return Theme.bad }
        if line.hasPrefix("@@") { return Theme.acc }
        return Theme.tx2
    }

    // MARK: - Reading one whole

    /// Reads the opened issue or pull request whole (`github.show`) when the list holds less of it than the page shows
    /// (a closed one), when it is a pull request, whose checks change without anyone writing, or when the list was read
    /// over a minute ago. What the list knows shows meanwhile.
    private func fill(_ which: Opened?) {
        guard let which, !filling.contains(which.key) else { return }
        let work = self.work
        var params: [String: Any] = ["projectId": project.id]
        switch which {
        case .issue(let number):
            let listed = work.issues.first { $0.id == number }
            let fresh = work.readAt.map { Date().timeIntervalSince($0) < 60 } ?? false
            if listed?.partial == false && fresh { return }
            params["number"] = number
        case .pull(let number):
            params["number"] = number
            params["pull"] = true
        }
        filling.insert(which.key)
        Task {
            defer { filling.remove(which.key) }
            do {
                try await engine.call("github.show", params)
            } catch {
                if opened == which { problem = "pi² could not read it whole from GitHub: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Changes

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            do {
                try await engine.call("github.refresh", ["projectId": project.id])
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func beginEditing(_ issue: WorkPiece) {
        draftTitle = issue.title
        draftText = issue.text
        editing = true
    }

    private func save(_ issue: WorkPiece) {
        // The title is one line wherever it is shown, so a line break typed into it becomes a space.
        let title = draftTitle.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        draftTitle = title
        editing = false
        send(.issue(issue.id), WorkPending(word: "Saving"), "work.act",
             ["projectId": project.id, "id": issue.id, "action": "edit", "title": title, "text": draftText],
             // What was typed is still in the fields, which come back with the engine's words under the page.
             failed: { editing = true })
    }

    private func addNote(_ issue: WorkPiece) {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, pending[Opened.issue(issue.id).key] == nil else { return }
        noteText = ""
        sending[issue.id] = text
        send(.issue(issue.id), WorkPending(word: "Adding a comment"), "work.act",
             ["projectId": project.id, "id": issue.id, "action": "note", "text": text],
             then: { sending[issue.id] = nil },
             failed: {
                 sending[issue.id] = nil
                 // The words come back to the field, so nothing typed is lost.
                 if noteText.isEmpty { noteText = text }
             })
    }

    /// One action of the state table, as the person pressed its button: shown at once as on its way, with the state it
    /// goes to, until the engine answers.
    private func act(_ issue: WorkPiece, _ action: String, _ extra: [String: Any] = [:]) {
        send(.issue(issue.id), WorkPending.of(action, extra), "work.act",
             ["projectId": project.id, "id": issue.id, "action": action].merging(extra) { _, new in new })
    }

    /// Gives the issue to an agent, which starts it: the engine claims it and starts a sub-chat of the orchestrator's
    /// conversation in one step (3.11). Past a limit the engine refuses with its reading, and the person confirms that
    /// one start (8.3), as in the list pi² keeps.
    private func assign(_ issue: WorkPiece, to agent: AgentProfile, confirming: WorkLimit? = nil) {
        let key = Opened.issue(issue.id).key
        guard pending[key] == nil else { return }
        pending[key] = WorkPending(word: "Giving to \(agent.name)", state: "in_progress", holderAgentId: agent.id)
        var params: [String: Any] = ["projectId": project.id, "id": issue.id, "action": "assign", "agentId": agent.id]
        if let confirming { params["confirmLimit"] = confirming.id }
        Task {
            defer { pending[key] = nil }
            do {
                try await engine.call("work.act", params)
                heldStart = nil
                problem = nil
            } catch let error as EngineError {
                // The refusal of a start past a limit carries the reading (8.3); anything else is just shown.
                if let limit = WorkLimit(error.data?["limit"]) {
                    heldStart = HeldStart(piece: issue, agent: agent, limit: limit)
                } else {
                    problem = error.localizedDescription
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func settle(_ write: GitHubUnknownWrite, happened: Bool) {
        let key = "settle:\(write.intent)"
        guard pending[key] == nil else { return }
        pending[key] = WorkPending(word: "Settling")
        Task {
            defer { pending[key] = nil }
            do {
                try await engine.call("github.settle", ["projectId": project.id, "intent": write.intent, "happened": happened])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// The diff of the pull request open, or of the one the preference names.
    private func showDiff() {
        guard let pull = openPull(work) else { return }
        Task {
            do {
                let answer = try await engine.call("github.diff", ["projectId": project.id, "number": pull.number])
                diff = ShownDiff(number: pull.number, text: answer["diff"]?.stringValue ?? "")
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func merge(_ pull: GitHubPull) {
        // The card has had its answer; the engine's words show at the bottom of the tab if it refuses.
        confirmingMerge = nil
        send(.pull(pull.number), WorkPending(word: "Merging"), "github.merge", ["projectId": project.id, "number": pull.number])
    }

    private func sendBack(_ pull: GitHubPull) {
        let reason = sendBackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, pending[Opened.pull(pull.number).key] == nil else { return }
        sendBackText = ""
        send(.pull(pull.number), WorkPending(word: "Sending back"), "github.sendBack",
             ["projectId": project.id, "number": pull.number, "reason": reason],
             failed: { if sendBackText.isEmpty { sendBackText = reason } })
    }

    /// Sends one request for one issue or pull request, shown at once as on its way there (`pending`), and keeps every
    /// other write for the same one off until the engine answers: a second click writes nothing twice. What the engine
    /// says when it refuses shows at the bottom of the tab, and the page is as it was.
    private func send(
        _ which: Opened, _ shown: WorkPending, _ request: String, _ params: [String: Any],
        then done: @escaping () -> Void = {}, failed: @escaping () -> Void = {}
    ) {
        guard pending[which.key] == nil else { return }
        pending[which.key] = shown
        Task {
            defer { pending[which.key] = nil }
            do {
                try await engine.call(request, params)
                done()
                problem = nil
            } catch {
                failed()
                problem = error.localizedDescription
            }
        }
    }
}
