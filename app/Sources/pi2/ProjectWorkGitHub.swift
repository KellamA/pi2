import SwiftUI

/// A pull request of the attached repository, as the `github` event sends it (docs/projects.md, 3.11): its branches, its
/// checks as one state, what reviewing agents found, and whether GitHub would merge it.
struct GitHubPull: Identifiable, Equatable {
    /// One finding a reviewing agent posted through `work` `review`. The event carries the verdict and who gave it, not
    /// the words of the finding, which are read on GitHub.
    struct Finding: Equatable, Identifiable {
        let agentName: String
        /// "approve", "changes" or "comment".
        let verdict: String
        let at: Date
        let url: String
        var id: String { "\(agentName)|\(at.timeIntervalSince1970)|\(url)" }
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
        mergeable = value["mergeable"]?.stringValue ?? "unknown"
        findings = (value["findings"]?.arrayValue ?? []).compactMap { finding in
            guard let agentName = finding["agentName"]?.stringValue else { return nil }
            var at = 0.0
            if case .number(let milliseconds)? = finding["at"] { at = milliseconds }
            return Finding(
                agentName: agentName,
                verdict: finding["verdict"]?.stringValue ?? "comment",
                at: Date(timeIntervalSince1970: at / 1000),
                url: finding["url"]?.stringValue ?? ""
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

    /// "Checks passing", "Checks failing", "Checks running", "No checks": the pull request's checks as one state.
    var checksWords: String {
        switch checks {
        case "passing": "Checks passing"
        case "failing": "Checks failing"
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

    struct ShownDiff: Equatable {
        let number: Int
        let text: String
    }

    private var engine: EngineClient { model.engine }

    /// For pictures of this tab: a development build's copy may name a row to open in its own preferences, as
    /// `PI2_SHOW` names a page, since a copy parked behind other windows cannot be clicked. Nothing a release build
    /// reads, and nothing the person sets.
    ///
    ///     defaults write dev.pi2.app.test-7 work-open -string 'pull:8'
    ///
    /// `merge:8` opens that pull request with the question to merge it showing, and `diff:8` with its diff.
    private static var openedInPreferences: Opened? {
        #if PI2_DEVELOPMENT
            guard let asked = UserDefaults.standard.string(forKey: "work-open") else { return nil }
            let parts = asked.split(separator: ":")
            guard parts.count == 2, let number = Int(parts[1]) else { return nil }
            switch parts[0] {
            case "issue": return .issue(number)
            case "pull", "merge", "diff": return .pull(number)
            default: return nil
            }
        #else
            return nil
        #endif
    }

    /// Whether the preference above asks for the merge question, or the diff, to show too.
    private static func preference(names prefix: String) -> Bool {
        #if PI2_DEVELOPMENT
            return UserDefaults.standard.string(forKey: "work-open")?.hasPrefix(prefix) == true
        #else
            return false
        #endif
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
                gone
            } else {
                listPage
            }
            if let pull = confirmingMerge {
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
            if Self.preference(names: "merge:"), let pull = openPull { confirmingMerge = pull }
            if Self.preference(names: "diff:"), openPull != nil { showDiff() }
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
            if work.issues.isEmpty && work.pulls.isEmpty {
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
                .disabled(work.state == "loading")
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
                    whoHas(issue)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Issue #\(issue.id), \(issue.title)")
            .accessibilityHint("Open this issue")
            // A menu inside the row's button is not a control of its own, so it sits beside it in the row.
            if issue.state == "open", !agents.isEmpty {
                giveMenu(issue)
                    .disabled(work.troubled)
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

    /// "Forge · sub-chat 17 · 5 min ago", or "Nobody · 5 min ago": who has it and when it last changed.
    private func whoHas(_ issue: WorkPiece) -> some View {
        HStack(spacing: 5) {
            if let agentId = issue.holderAgentId {
                AgentAvatar(agent: engine.agent(agentId), size: 12)
                Text(engine.agent(agentId)?.name ?? agentId).foregroundStyle(Theme.tx2)
                if let chat = issue.holderConversation {
                    Text("· sub-chat \(chat)").foregroundStyle(Theme.tx3)
                }
            } else {
                Text("Nobody").foregroundStyle(Theme.tx3)
            }
            Text("·").foregroundStyle(Theme.tx3)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(LimitsFormat.ago(issue.updatedAt, now: context.date)).foregroundStyle(Theme.tx3)
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }

    private func giveMenu(_ issue: WorkPiece) -> some View {
        Menu {
            ForEach(agents) { agent in
                Button(agent.name) { assign(issue, to: agent) }
            }
        } label: {
            Text("Give to")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("Give this issue to an agent, which starts it working on it")
        .accessibilityLabel("Give issue #\(issue.id) to an agent")
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
                        .disabled(work.troubled)
                    }
                    status(issue)
                    issueActions(issue)
                    comments(issue)
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
                    noteField(issue)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Where it is, who holds it, and what class of model it needs.
    private func status(_ issue: WorkPiece) -> some View {
        HStack(spacing: 6) {
            Text(ProjectWork.name(of: issue.state)).fontWeight(.medium).foregroundStyle(Theme.tx2)
            Text("·").foregroundStyle(Theme.tx3)
            if let agentId = issue.holderAgentId {
                AgentAvatar(agent: engine.agent(agentId), size: 12)
                Text(engine.agent(agentId)?.name ?? agentId).foregroundStyle(Theme.tx2)
                if let chat = issue.holderConversation {
                    Text("· sub-chat \(chat)").foregroundStyle(Theme.tx3)
                }
            } else {
                Text("Nobody has this yet").foregroundStyle(Theme.tx3)
            }
            Text("·").foregroundStyle(Theme.tx3)
            switch issue.modelClass {
            case "local": Text("needs a local model").foregroundStyle(Theme.tx3)
            case "cloud": Text("needs a cloud model").foregroundStyle(Theme.tx3)
            default: Text("not classified").foregroundStyle(Theme.tx3)
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }

    /// The actions the state table allows the person from this issue's state (docs/projects.md, 3.11), each with the
    /// table's own word for it. On GitHub they are all undone there, not by Undo (5.9).
    @ViewBuilder
    private func issueActions(_ issue: WorkPiece) -> some View {
        let held = ["in_progress", "waiting", "blocked"].contains(issue.state)
        HStack(spacing: 8) {
            if issue.state == "open", !agents.isEmpty {
                giveMenu(issue)
            }
            if held {
                Button("Release") { act(issue, "release") }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .help("Let go of this issue: it goes back to open, with nobody on it")
            }
            if ["waiting", "blocked"].contains(issue.state) {
                Button("Resume") { act(issue, "resume") }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .help("Carry on with this issue: it goes back to in progress")
            }
            Menu {
                Button("Local model") { act(issue, "classify", ["class": "local"]) }
                Button("Cloud model") { act(issue, "classify", ["class": "cloud"]) }
                Button("Not classified") { act(issue, "classify", ["class": NSNull()]) }
            } label: {
                Text("Classify")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Say what class of model this issue needs")
            .accessibilityLabel("Classify issue #\(issue.id)")
            Spacer(minLength: 8)
            if held || issue.state == "open" {
                Menu {
                    Button("Close as Done") { act(issue, "close", ["as": "done"]) }
                    Button("Close as Dropped") { act(issue, "close", ["as": "dropped"]) }
                } label: {
                    Text("Close")
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help("Close this issue on GitHub: done, or dropped as not worth doing")
                .accessibilityLabel("Close issue #\(issue.id)")
            }
            if ["done", "dropped"].contains(issue.state) {
                Button("Reopen") { act(issue, "reopen") }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .help("Open this issue again on GitHub")
            }
        }
        .disabled(work.troubled)
    }

    /// The issue's comments, oldest first, each with who wrote it and when.
    private func comments(_ issue: WorkPiece) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !issue.notes.isEmpty {
                Text("Comments").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tx3)
            }
            ForEach(Array(issue.notes.enumerated()), id: \.offset) { _, note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.tx)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    commentLine(note)
                }
            }
        }
    }

    private func commentLine(_ note: WorkPiece.Note) -> some View {
        let who = note.agentId.map { engine.agent($0)?.name ?? $0 } ?? "You"
        // The time is kept current as the row's is, since the page stays open while a comment ages.
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            Text("\(who) · \(LimitsFormat.ago(note.at, now: context.date))")
                .font(.caption)
                .foregroundStyle(Theme.tx3)
        }
    }

    private func noteField(_ issue: WorkPiece) -> some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("Add a comment", text: $noteText, prompt: Text("Add a comment to this issue"), axis: .vertical)
                .labelsHidden()
                .lineLimit(1...3)
                .disabled(work.troubled)
                .accessibilityLabel("New comment on issue #\(issue.id)")
                .sendsOnReturn { addNote(issue) }
            Button("Add") { addNote(issue) }
                .buttonStyle(.piPrimary)
                .controlSize(.small)
                .disabled(work.troubled || noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .panel(radius: 12, border: Theme.line2)
    }

    // MARK: - One pull request, opened

    private func pullPage(_ pull: GitHubPull) -> some View {
        VStack(spacing: 0) {
            header(back: { opened = nil }, trailing: "#\(pull.number)")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                    if pull.checks == "failing" {
                        Text("Its checks are failing. GitHub shows which of them under the pull request, and pi² only knows that they failed.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tx2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                            .disabled(work.troubled)
                            .help("Merge this pull request into \(pull.base)")
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

    /// What reviewing agents found: each verdict, who gave it and when. The words of a finding are on GitHub.
    private func findings(_ pull: GitHubPull) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What reviewing agents found").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tx3)
            if pull.findings.isEmpty {
                Text("No agent has posted a finding on it yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tx3)
            }
            ForEach(pull.findings.sorted { $0.at > $1.at }) { finding in
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
                    .disabled(work.troubled)
                    .accessibilityLabel("What to put right on pull request #\(pull.number)")
                    .sendsOnReturn { sendBack(pull) }
                Button("Send Back") { sendBack(pull) }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .disabled(work.troubled || sendBackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    // MARK: - A part that was open but is no longer in the list

    private var gone: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(Theme.tx3)
            Text("This is no longer in the list.").font(.system(size: 12.5)).foregroundStyle(Theme.tx2)
            Button("All Work") { opened = nil }
                .buttonStyle(.piSecondary)
                .controlSize(.small)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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

    // MARK: - Changes

    /// Brings the person's edits in step with the engine's issue. One just opened always seeds them, since what was
    /// typed on the last one is not this one's editing.
    private func seedDrafts(_ latest: WorkPiece?) {
        draftBase = latest
        draftTitle = latest?.title ?? ""
        draftText = latest?.text ?? ""
    }

    private func refresh() {
        Task {
            do {
                try await engine.call("github.refresh", ["projectId": project.id])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func save(_ issue: WorkPiece) {
        // The title is one line wherever it is shown, so a line break typed into it becomes a space.
        let title = draftTitle.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        draftTitle = title
        Task {
            do {
                try await engine.call("work.act", ["projectId": project.id, "id": issue.id, "action": "edit", "title": title, "text": draftText])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func addNote(_ issue: WorkPiece) {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            do {
                try await engine.call("work.act", ["projectId": project.id, "id": issue.id, "action": "note", "text": text])
                noteText = ""
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// One action of the state table, as the person pressed its button.
    private func act(_ issue: WorkPiece, _ action: String, _ extra: [String: Any] = [:]) {
        Task {
            do {
                try await engine.call("work.act", ["projectId": project.id, "id": issue.id, "action": action].merging(extra) { _, new in new })
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Gives the issue to an agent, which starts it: the engine claims it and starts a sub-chat of the orchestrator's
    /// conversation in one step (3.11).
    private func assign(_ issue: WorkPiece, to agent: AgentProfile) {
        Task {
            do {
                try await engine.call("work.act", ["projectId": project.id, "id": issue.id, "action": "assign", "agentId": agent.id])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func settle(_ write: GitHubUnknownWrite, happened: Bool) {
        Task {
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
        Task {
            do {
                try await engine.call("github.merge", ["projectId": project.id, "number": pull.number])
                confirmingMerge = nil
                problem = nil
            } catch {
                // The engine's words: GitHub's reason it would not merge, or why it cannot be merged.
                confirmingMerge = nil
                problem = error.localizedDescription
            }
        }
    }

    private func sendBack(_ pull: GitHubPull) {
        let reason = sendBackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return }
        Task {
            do {
                try await engine.call("github.sendBack", ["projectId": project.id, "number": pull.number, "reason": reason])
                sendBackText = ""
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
