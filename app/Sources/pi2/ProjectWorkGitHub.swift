import SwiftUI

/// A pull request of the attached repository, as the `github` event sends it (docs/projects.md, 3.11): its branches, its
/// checks as one state, what reviewing agents found, and whether GitHub would merge it.
struct GitHubPull: Identifiable, Equatable {
    /// One finding a reviewing agent posted through `work` `review`: the verdict, who gave it and when, and the
    /// finding's own words, the summary the reviewing agent wrote (#573).
    struct Finding: Equatable, Identifiable {
        let agentName: String
        /// "approve", "changes" or "comment".
        let verdict: String
        let at: Date
        let url: String
        /// The finding's own words, as the reviewing agent wrote them.
        let text: String
        var id: String { "\(agentName)|\(at.timeIntervalSince1970)|\(url)" }
    }

    /// One of the pull request's checks that failed, with its page on GitHub (#573).
    struct FailingCheck: Equatable, Identifiable {
        let name: String
        let url: String
        var id: String { "\(name)|\(url)" }
    }

    let number: Int
    let title: String
    let url: String
    /// The head branch as GitHub names it: "branch", or "owner:branch" from a fork.
    let head: String
    let base: String
    let author: String
    /// "open", "merged" or "closed".
    let state: String
    let draft: Bool
    /// "passing", "failing", "pending" or "none".
    let checks: String
    /// The checks that failed, each with its page on GitHub; empty when none fail (#573).
    let failingChecks: [FailingCheck]
    /// "yes", "no" or "unknown".
    let mergeable: String
    let findings: [Finding]
    /// The sub-chat that opened it through pi², which Send back hands it to; nil when nobody opened it here.
    let openedBy: Int?
    /// The work item it fixes, from "Fixes #N" in its text.
    let work: Int?

    var id: Int { number }

    init?(_ value: JSONValue?) {
        guard let value, let number = value["number"]?.intValue, let title = value["title"]?.stringValue else { return nil }
        var draft = false
        if case .bool(let isDraft)? = value["draft"] { draft = isDraft }
        self.number = number
        self.title = title
        url = value["url"]?.stringValue ?? ""
        head = value["head"]?.stringValue ?? ""
        base = value["base"]?.stringValue ?? ""
        author = value["author"]?.stringValue ?? ""
        state = value["state"]?.stringValue ?? "open"
        self.draft = draft
        checks = value["checks"]?.stringValue ?? "none"
        failingChecks = (value["failingChecks"]?.arrayValue ?? []).compactMap { check in
            guard let name = check["name"]?.stringValue else { return nil }
            return FailingCheck(name: name, url: check["url"]?.stringValue ?? "")
        }
        mergeable = value["mergeable"]?.stringValue ?? "unknown"
        findings = (value["findings"]?.arrayValue ?? []).compactMap { finding in
            guard let agentName = finding["agentName"]?.stringValue else { return nil }
            var at = 0.0
            if case .number(let milliseconds)? = finding["at"] { at = milliseconds }
            return Finding(
                agentName: agentName,
                verdict: finding["verdict"]?.stringValue ?? "comment",
                at: Date(timeIntervalSince1970: at / 1000),
                url: finding["url"]?.stringValue ?? "",
                text: finding["text"]?.stringValue ?? ""
            )
        }
        openedBy = value["openedBy"]?["conversationId"]?.intValue
        work = value["work"]?.intValue
    }

    /// The newest finding, which is what the pull request's row says about what a reviewing agent found.
    var newestFinding: Finding? { findings.max { $0.at < $1.at } }

    /// "approved", "asked for changes" or "left a finding": the words for a verdict.
    static func verdictWords(_ verdict: String) -> String {
        switch verdict {
        case "approve": "approved"
        case "changes": "asked for changes"
        default: "left a finding"
        }
    }

    /// "2 checks failing", "1 check failing", "Checks passing", "Checks running", "No checks": the pull request's
    /// checks, the failing ones counted (#573).
    var checksWords: String {
        switch checks {
        case "passing": "Checks passing"
        case "failing": "\(failingChecks.count) \(failingChecks.count == 1 ? "check" : "checks") failing"
        case "pending": "Checks running"
        default: "No checks"
        }
    }
}

/// A write of pi²'s whose outcome GitHub could not be told (`unknown`, docs/projects.md, 3.11): `gh` was cut off while
/// it was writing, so the person looks at the repository and says whether it happened (`github.settle`).
struct GitHubUnknownWrite: Identifiable, Equatable {
    let intent: String
    let summary: String
    let at: Date

    var id: String { intent }

    init?(_ value: JSONValue?) {
        guard let value, let intent = value["intent"]?.stringValue else { return nil }
        var at = 0.0
        if case .number(let milliseconds)? = value["at"] { at = milliseconds }
        self.intent = intent
        summary = value["summary"]?.stringValue ?? "a write"
        self.at = Date(timeIntervalSince1970: at / 1000)
    }
}

/// The open project's repository, from the `github` event's `projects` (docs/projects.md, 4.3): the issues as work, the
/// pull requests, how the last read went, and the writes whose outcome pi² could not tell.
struct GitHubWork {
    /// "ok", "loading", "signed_out", "unreachable" or "rate_limited".
    let state: String
    let error: String?
    let readAt: Date?
    let issues: [WorkPiece]
    let pulls: [GitHubPull]
    let unknown: [GitHubUnknownWrite]

    init(_ value: JSONValue?) {
        state = value?["state"]?.stringValue ?? "loading"
        error = value?["error"]?.stringValue
        var read = 0.0
        if case .number(let milliseconds)? = value?["readAt"] { read = milliseconds }
        readAt = read > 0 ? Date(timeIntervalSince1970: read / 1000) : nil
        issues = (value?["issues"]?.arrayValue ?? []).compactMap(WorkPiece.init)
        pulls = (value?["pulls"]?.arrayValue ?? []).compactMap(GitHubPull.init)
        unknown = (value?["unknown"]?.arrayValue ?? []).compactMap(GitHubUnknownWrite.init)
    }

    /// GitHub's last read left something wrong: the list stays as it was read, and nothing can be changed until it is
    /// read again.
    var troubled: Bool { state == "signed_out" || state == "unreachable" || state == "rate_limited" }

    /// The issues in the order the state table lists them (3.11), in the groups that have something in them, each
    /// newest-changed first, as the list kept by pi² groups its work.
    var grouped: [(state: String, name: String, items: [WorkPiece])] {
        ProjectWork.groups.compactMap { group in
            let inState = issues.filter { $0.state == group.state }.sorted { $0.updatedAt > $1.updatedAt }
            return inState.isEmpty ? nil : (group.state, group.name, inState)
        }
    }
}

/// The board's Work tab for a project whose work is a GitHub repository's issues and pull requests (#480): the issues
/// grouped as the contract groups them, and the pull requests with their checks, what a reviewing agent found, and Diff,
/// Merge and Send Back.
struct ProjectWorkGitHub: View {
    let model: AppModel
    let project: ProjectRow

    /// The issue or pull request the person opened, by its number.
    private enum Opened: Equatable {
        case issue(Int)
        case pull(Int)
    }

    @State private var opened: Opened? = ProjectWorkGitHub.openedInPreferences
    /// The diff `github.diff` answered, which shows in place of everything else until the person goes back.
    @State private var diff: ShownDiff?
    @State private var problem: String?
    /// The pull request whose merge waits for the person's word.
    @State private var confirmingMerge: GitHubPull?
    /// What the person is typing to send a pull request back.
    @State private var sendBackText = ""
    /// An issue's title and text as the person is editing them, with the issue as last seeded.
    @State private var draftTitle = ""
    @State private var draftText = ""
    @State private var draftBase: WorkPiece?
    @State private var noteText = ""
    /// The findings whose words are shown in full, by the finding's id (#573).
    @State private var unfoldedFindings: Set<String> = []
    /// What the person asked for and the engine has not answered yet: while one of these is on its way, nothing else in
    /// the tab is sent, so a second click while the first is on its way writes nothing twice.
    @State private var working: String?
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
    private var work: GitHubWork { GitHubWork(engine.extras["github"]?["projects"]?[project.id]) }
    private var repositoryName: String {
        [project.repository?.owner, project.repository?.name].compactMap { $0 }.joined(separator: "/")
    }
    private var agents: [AgentProfile] { engine.allAgents.filter { $0.projectId == project.id } }
    private var openIssue: WorkPiece? {
        guard case .issue(let number)? = opened else { return nil }
        return work.issues.first { $0.id == number }
    }
    private var openPull: GitHubPull? {
        guard case .pull(let number)? = opened else { return nil }
        return work.pulls.first { $0.number == number }
    }
    private var busy: Bool { working != nil }
    private var edited: Bool {
        guard let base = draftBase else { return false }
        return draftTitle != base.title || draftText != base.text
    }

    var body: some View {
        VStack(spacing: 0) {
            if let diff {
                diffPage(diff)
            } else if let pull = openPull {
                pullPage(pull)
            } else if let issue = openIssue {
                issuePage(issue)
            } else if opened != nil {
                WorkGone(words: "This is no longer in the list.", back: { opened = nil })
            } else {
                listPage
            }
            if let held = heldStart {
                HeldStartCard(
                    held: held,
                    enabled: !busy,
                    start: { assign(held.piece, to: held.agent, confirming: held.limit) },
                    leave: { heldStart = nil }
                )
            } else if let pull = confirmingMerge {
                mergeCard(pull)
            } else if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(Theme.bad)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // A row the preference named is seeded here, as one the person clicked is seeded by the change below.
            if case .issue? = opened { seedDrafts(openIssue) }
            if case .merge? = WorkRowLaunch.asked, let pull = openPull { confirmingMerge = pull }
            if case .diff? = WorkRowLaunch.asked, openPull != nil { showDiff() }
        }
        .onChange(of: opened) { _, latest in
            problem = nil
            confirmingMerge = nil
            sendBackText = ""
            noteText = ""
            if case .issue? = latest {
                seedDrafts(openIssue)
            } else {
                seedDrafts(nil)
            }
        }
        .onChange(of: openIssue) { _, latest in
            // Follow what the engine says, unless the person is in the middle of editing.
            if !edited { seedDrafts(latest) } else { draftBase = latest }
        }
    }

    // MARK: - The list

    private var listPage: some View {
        VStack(spacing: 0) {
            bar
            banner
            if work.issues.isEmpty && work.pulls.isEmpty && work.unknown.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(work.unknown) { write in
                            unknownCard(write)
                        }
                        ForEach(work.grouped, id: \.state) { group in
                            issueGroup(group)
                        }
                        if !work.pulls.isEmpty {
                            pullGroup
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            if !repositoryName.isEmpty {
                Label(repositoryName, systemImage: "chevron.left.forwardslash.chevron.right")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tx3)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Refresh", action: refresh)
                .buttonStyle(.piSecondary)
                .controlSize(.small)
                .disabled(work.state == "loading" || busy)
                .help("Read the repository again")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// One calm line when GitHub's last read left something wrong, or while the first read is under way: which it is,
    /// and when the list below was read.
    @ViewBuilder
    private var banner: some View {
        if work.state != "ok" {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: work.state == "loading" ? "clock" : "exclamationmark.triangle.fill")
                    .foregroundStyle(work.state == "loading" ? Theme.tx3 : Theme.warn)
                Text(troubleWords)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tx2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }

    /// What went wrong, and what the list under it holds: the last listing, read before it went wrong.
    private var troubleWords: String {
        let read = work.readAt.map { "The last read, \(LimitsFormat.ago($0, now: Date())), is below" }
            ?? "Nothing has been read yet"
        switch work.state {
        case "loading":
            return "Reading \(repositoryName)…"
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

    private var empty: some View {
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
            Menu {
                Button("It Happened") { settle(write, happened: true) }
                Button("It Did Not") { settle(write, happened: false) }
            } label: {
                Text("Check Again")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            // Nothing to settle while a write of the tab's is on its way, which could be the one this asks about.
            .disabled(busy)
            .help("Say whether the write happened, after looking at the repository")
            .accessibilityLabel("Check again whether \(write.summary) happened")
        }
        .padding(12)
        .panel(radius: 12, border: Theme.warn.opacity(0.55))
    }

    private func issueGroup(_ group: (state: String, name: String, items: [WorkPiece])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(group.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tx3)
                Text(String(group.items.count))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tx3)
                    .monospacedDigit()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Theme.card2, in: .rect(cornerRadius: 4))
            }
            ForEach(group.items) { issue in
                issueRow(issue)
            }
        }
    }

    private func issueRow(_ issue: WorkPiece) -> some View {
        HStack(spacing: 10) {
            Button { opened = .issue(issue.id) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(issue.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.tx)
                            .lineLimit(1)
                        Text("#\(issue.id)").font(Theme.mono).foregroundStyle(Theme.tx3)
                        classChip(issue)
                    }
                    WorkHolderLine(engine: engine, piece: issue)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Issue #\(issue.id), \(issue.title)")
            .accessibilityHint("Open this issue")
            // A menu inside the row's button is not a control of its own, so it sits beside it in the row.
            if issue.state == "open", !agents.isEmpty {
                WorkGiveMenu(agents: agents, piece: issue, onGitHub: true, give: { assign(issue, to: $0) })
                    .disabled(work.troubled || busy)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.card, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    /// The label the contract gives the model a piece of work needs, quietly beside its title (3.11).
    @ViewBuilder
    private func classChip(_ issue: WorkPiece) -> some View {
        if let modelClass = issue.modelClass {
            Text(modelClass == "local" ? "local model" : "cloud model")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tx3)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Theme.card2, in: .rect(cornerRadius: 4))
        }
    }

    private var pullGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Pull requests").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tx3)
                Text(String(work.pulls.count))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tx3)
                    .monospacedDigit()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Theme.card2, in: .rect(cornerRadius: 4))
            }
            ForEach(work.pulls.sorted { $0.number > $1.number }) { pull in
                pullRow(pull)
            }
        }
    }

    private func pullRow(_ pull: GitHubPull) -> some View {
        Button { opened = .pull(pull.number) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pull.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.tx)
                        .lineLimit(1)
                    Text("#\(pull.number)").font(Theme.mono).foregroundStyle(Theme.tx3)
                    if pull.state != "open" {
                        // GitHub lists one merged or closed in the last seven days (3.11), so the row says which.
                        Text(pull.state).font(.system(size: 10.5)).foregroundStyle(Theme.tx3)
                    }
                    if pull.draft {
                        Text("draft").font(.system(size: 10.5)).foregroundStyle(Theme.tx3)
                    }
                }
                HStack(spacing: 5) {
                    Text("\(pull.head) → \(pull.base)").foregroundStyle(Theme.tx3).lineLimit(1)
                    Text("·").foregroundStyle(Theme.tx3)
                    Text(pull.checksWords)
                        .foregroundStyle(checksColour(pull))
                    if let finding = pull.newestFinding {
                        Text("·").foregroundStyle(Theme.tx3)
                        Text("\(finding.agentName) \(GitHubPull.verdictWords(finding.verdict))")
                            .foregroundStyle(finding.verdict == "changes" ? Theme.warn : Theme.tx2)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11.5))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pull request #\(pull.number), \(pull.title)")
        .accessibilityHint("Open this pull request")
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.card, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
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

    private func issuePage(_ issue: WorkPiece) -> some View {
        VStack(spacing: 0) {
            header(back: { opened = nil }, trailing: "#\(issue.id)")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(work.unknown) { write in
                        unknownCard(write)
                    }
                    TextField("Title", text: $draftTitle, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1...)
                        .disabled(work.troubled)
                        .accessibilityLabel("Title of issue #\(issue.id)")
                    TextField("Text", text: $draftText, prompt: Text("What needs doing (you can leave this empty)"), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .lineLimit(2...)
                        .disabled(work.troubled)
                        .accessibilityLabel("Text of issue #\(issue.id)")
                    if edited {
                        HStack(spacing: 8) {
                            Button("Save Changes") { save(issue) }
                                .buttonStyle(.piPrimary)
                                .controlSize(.small)
                            Button("Revert") { seedDrafts(issue) }
                                .buttonStyle(.piGhost)
                                .controlSize(.small)
                        }
                        .disabled(work.troubled || busy)
                    }
                    WorkStatusLine(engine: engine, piece: issue)
                    WorkActions(
                        piece: issue, agents: agents, onGitHub: true, enabled: !work.troubled && !busy,
                        act: { action, extra in act(issue, action, extra) },
                        assign: { assign(issue, to: $0) }
                    )
                    WorkNotes(engine: engine, piece: issue, heading: "Comments")
                    if let result = issue.result {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What finishing it said was done").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tx3)
                            Text(result)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.tx)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .panel(radius: 8, border: Theme.line)
                    }
                    WorkNoteField(
                        piece: issue, text: $noteText, onGitHub: true, enabled: !work.troubled && !busy,
                        add: { addNote(issue) }
                    )
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - One pull request, opened

    private func pullPage(_ pull: GitHubPull) -> some View {
        VStack(spacing: 0) {
            header(back: { opened = nil }, trailing: "#\(pull.number)")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(work.unknown) { write in
                        unknownCard(write)
                    }
                    Text(pull.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.tx)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        Text("\(pull.head) → \(pull.base)").foregroundStyle(Theme.tx2)
                        Text("·").foregroundStyle(Theme.tx3)
                        Text(pull.checksWords).foregroundStyle(checksColour(pull))
                        if pull.draft {
                            Text("·").foregroundStyle(Theme.tx3)
                            Text("draft").foregroundStyle(Theme.tx3)
                        }
                        if !pull.author.isEmpty {
                            Text("·").foregroundStyle(Theme.tx3)
                            Text("from \(pull.author)").foregroundStyle(Theme.tx3)
                        }
                    }
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    if pull.state != "open" {
                        Text(pull.state == "merged"
                            ? "GitHub merged it into \(pull.base). Nothing here can merge or send it back again."
                            : "GitHub closed it without merging. Nothing here can merge or send it back again.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tx2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    failingChecksList(pull)
                    if pull.mergeable == "no" {
                        Text("GitHub says it conflicts with \(pull.base), so it cannot be merged as it is.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tx2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Diff") { showDiff() }
                            .buttonStyle(.piSecondary)
                            .controlSize(.small)
                            .help("Show what this pull request changes")
                        Button("Merge") { confirmingMerge = pull }
                            .buttonStyle(.piPrimary)
                            .controlSize(.small)
                            .disabled(work.troubled || busy || pull.state != "open")
                            .help(pull.state == "open" ? "Merge this pull request into \(pull.base)"
                                : "It is \(pull.state), so there is nothing left to merge")
                        if let workItem = pull.work {
                            Text("Fixes #\(workItem)").font(Theme.mono).foregroundStyle(Theme.tx3)
                        }
                        Spacer(minLength: 0)
                    }
                    findings(pull)
                    sendBackField(pull)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The pull request's checks that failed, each its name opening its page on GitHub in the browser (#573). The
    /// roll-up once said only that some had failed, without which.
    @ViewBuilder
    private func failingChecksList(_ pull: GitHubPull) -> some View {
        if pull.checks == "failing" {
            if pull.failingChecks.isEmpty {
                Text("Its checks are failing. GitHub shows which of them under the pull request, and pi² only knows that they failed.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tx2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(pull.failingChecks.count) \(pull.failingChecks.count == 1 ? "check" : "checks") failing")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tx3)
                    ForEach(pull.failingChecks) { check in
                        Button {
                            if let url = URL(string: check.url) { NSWorkspace.shared.open(url) }
                        } label: {
                            Label(check.name, systemImage: "xmark.circle.fill")
                                .font(.system(size: 12))
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
    }

    /// What reviewing agents found: each verdict, who gave it and when, with its words under the verdict (#573).
    private func findings(_ pull: GitHubPull) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What reviewing agents found").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tx3)
            if pull.findings.isEmpty {
                Text("No agent has posted a finding on it yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tx3)
            }
            ForEach(pull.findings.sorted { $0.at > $1.at }) { finding in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(capitalised(GitHubPull.verdictWords(finding.verdict)))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(finding.verdict == "approve" ? Theme.ok : finding.verdict == "changes" ? Theme.warn : Theme.tx2)
                        Text(finding.agentName)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.tx)
                        Text("·").foregroundStyle(Theme.tx3)
                        Text(LimitsFormat.ago(finding.at, now: Date()))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tx3)
                        Spacer(minLength: 0)
                    }
                    if !finding.text.isEmpty {
                        Text(finding.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.tx)
                            .textSelection(.enabled)
                            // At most a few lines of it; the rest is one click away.
                            .lineLimit(unfoldedFindings.contains(finding.id) ? nil : 3)
                            .fixedSize(horizontal: false, vertical: true)
                        if finding.text.count > 120 || finding.text.contains("\n") {
                            Button(unfoldedFindings.contains(finding.id) ? "Show Less" : "Show All") {
                                if unfoldedFindings.contains(finding.id) {
                                    unfoldedFindings.remove(finding.id)
                                } else {
                                    unfoldedFindings.insert(finding.id)
                                }
                            }
                            .buttonStyle(.piGhost)
                            .controlSize(.small)
                            .accessibilityLabel(unfoldedFindings.contains(finding.id)
                                ? "Show less of the finding \(finding.agentName) posted"
                                : "Show all of the finding \(finding.agentName) posted")
                        }
                    }
                }
            }
        }
        .padding(10)
        .panel(radius: 8, border: Theme.line)
    }

    private func capitalised(_ words: String) -> String {
        words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The short field for what to put right, sent with `github.sendBack`, which posts it on the pull request and hands
    /// it to the conversation that opened it (3.11).
    private func sendBackField(_ pull: GitHubPull) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                TextField("Send Back", text: $sendBackText, prompt: Text("What to put right"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...3)
                    .disabled(work.troubled || busy || pull.state != "open")
                    .accessibilityLabel("What to put right on pull request #\(pull.number)")
                    .sendsOnReturn { sendBack(pull) }
                Button("Send Back") { sendBack(pull) }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .disabled(work.troubled || busy || pull.state != "open" || sendBackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(pull.openedBy.map { "The reason is posted on the pull request and given to sub-chat \($0), which opened it." }
                ?? "The reason is posted on the pull request. Nobody opened it through pi², so no agent is told.")
                .font(.caption)
                .foregroundStyle(Theme.tx3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .panel(radius: 12, border: Theme.line2)
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
                    .disabled(busy)
                Button("Cancel") { confirmingMerge = nil }
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
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : String(line))
                            .font(Theme.mono)
                            .foregroundStyle(diffColour(String(line)))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
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

    // MARK: - The bar of an opened issue or pull request

    /// The bar an opened issue or pull request has: the way back, and what is open.
    private func header(back: @escaping () -> Void, trailing: String) -> some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Label("All Work", systemImage: "chevron.left")
            }
            .buttonStyle(.piGhost)
            .controlSize(.small)
            .help("Back to the project's issues and pull requests")
            Spacer(minLength: 4)
            Text(trailing).font(Theme.mono).foregroundStyle(Theme.tx3)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: - The drafts the person edits

    /// Brings the person's edits in step with the engine's issue. One just opened always seeds them, since what was
    /// typed on the last one is not this one's editing.
    private func seedDrafts(_ latest: WorkPiece?) {
        draftBase = latest
        draftTitle = latest?.title ?? ""
        draftText = latest?.text ?? ""
    }

    // MARK: - Changes

    private func refresh() {
        send("refresh", "github.refresh", ["projectId": project.id])
    }

    private func save(_ issue: WorkPiece) {
        // The title is one line wherever it is shown, so a line break typed into it becomes a space.
        let title = draftTitle.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        draftTitle = title
        send("edit", "work.act", ["projectId": project.id, "id": issue.id, "action": "edit", "title": title, "text": draftText])
    }

    private func addNote(_ issue: WorkPiece) {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        send("note", "work.act", ["projectId": project.id, "id": issue.id, "action": "note", "text": text]) {
            noteText = ""
        }
    }

    /// One action of the state table, as the person pressed its button.
    private func act(_ issue: WorkPiece, _ action: String, _ extra: [String: Any] = [:]) {
        send(action, "work.act", ["projectId": project.id, "id": issue.id, "action": action].merging(extra) { _, new in new })
    }

    /// Gives the issue to an agent, which starts it: the engine claims it and starts a sub-chat of the orchestrator's
    /// conversation in one step (3.11). Past a limit the engine refuses with its reading, and the person confirms that
    /// one start (8.3), as in the list pi² keeps.
    private func assign(_ issue: WorkPiece, to agent: AgentProfile, confirming: WorkLimit? = nil) {
        guard working == nil else { return }
        working = "assign"
        var params: [String: Any] = ["projectId": project.id, "id": issue.id, "action": "assign", "agentId": agent.id]
        if let confirming { params["confirmLimit"] = confirming.id }
        Task {
            defer { working = nil }
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
        send("settle", "github.settle", ["projectId": project.id, "intent": write.intent, "happened": happened])
    }

    /// The diff of the pull request open, or of the one the preference names.
    private func showDiff() {
        guard let pull = openPull else { return }
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
        guard working == nil else { return }
        // The card has had its answer; the engine's words show at the bottom of the tab if it refuses.
        confirmingMerge = nil
        send("merge", "github.merge", ["projectId": project.id, "number": pull.number])
    }

    private func sendBack(_ pull: GitHubPull) {
        let reason = sendBackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return }
        send("sendBack", "github.sendBack", ["projectId": project.id, "number": pull.number, "reason": reason]) {
            sendBackText = ""
        }
    }

    /// Sends one request and keeps every other write of the tab off until the engine answers: a second click while the
    /// first is on its way wrote nothing twice. What the engine says when it refuses shows at the bottom of the tab.
    private func send(_ what: String, _ request: String, _ params: [String: Any], then done: @escaping () -> Void = {}) {
        guard working == nil else { return }
        working = what
        Task {
            defer { working = nil }
            do {
                try await engine.call(request, params)
                done()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
