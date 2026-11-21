import ComposeKit
import SwiftUI
import WindowKit

// The board's Now tab (#472; docs/design/projects.md "The hub" and "Needs you", docs/projects.md 3.9, 3.10 and 10.3):
// what needs the person, which agents are working now, and what finished today. The needs scroll within a space of
// their own, in the manner of the requests above a conversation's field (#489), so they never push the sections below
// out of the tab, and the board's other tabs stay as they were (ProjectHubViews.swift).

// MARK: - What the engine sends

/// One report as the engine's `reports` event sends it (docs/projects.md, 3.10): how a run the orchestrator handed out
/// ended, and whether it has been given to the orchestrator yet.
struct ProjectReport: Identifiable, Equatable {
    let submissionId: Int
    let conversationId: Int
    let agentId: String
    let title: String
    /// Nil while the run goes on.
    let endedAt: Date?
    /// "answered", "failed" or "stopped".
    let outcome: String?
    /// How the orchestrator was given it ("wake", "wait" or "read"); nil while it waits to be read.
    let deliveredBy: String?
    var id: Int { submissionId }

    init?(_ item: JSONValue) {
        guard let submissionId = item["submissionId"]?.intValue,
              let conversationId = item["conversationId"]?.intValue,
              let agentId = item["agentId"]?.stringValue,
              let title = item["title"]?.stringValue else { return nil }
        self.submissionId = submissionId
        self.conversationId = conversationId
        self.agentId = agentId
        self.title = title
        var ended: Date?
        if case .number(let milliseconds)? = item["ended"]?["at"] { ended = Date(timeIntervalSince1970: milliseconds / 1000) }
        endedAt = ended
        outcome = item["ended"]?["outcome"]?.stringValue
        deliveredBy = item["delivered"]?["by"]?.stringValue
    }
}

/// The reports of one project, from the `reports` event's `projects` (docs/projects.md, 4.3): what finished today,
/// newest first.
struct ProjectReports {
    let items: [ProjectReport]

    init(_ value: JSONValue?) {
        let read = (value?.arrayValue ?? []).compactMap(ProjectReport.init)
        let midnight = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        items = read
            .filter { $0.endedAt.map { $0.timeIntervalSince1970 >= midnight } == true }
            .sorted { ($0.endedAt?.timeIntervalSince1970 ?? 0) > ($1.endedAt?.timeIntervalSince1970 ?? 0) }
    }
}

// MARK: - The tab

/// The board's Now tab: what needs the person at the top, answered in place; who is working now, with the project's
/// switch for waking the orchestrator on reports; and what finished today, with a mark on what has not been read yet.
struct ProjectNowTab: View {
    let model: AppModel
    let project: ProjectRow

    /// The engine's answer when an answer fails, by the need's id: shown under that need's controls.
    @State private var problems: [String: String] = [:]
    /// The tab's height, for the space the needs scroll within.
    @State private var height: CGFloat = 0
    /// The wake switch as the person last set it, until the engine's `projects` event says which it is.
    @State private var wakeChoice: Bool?
    /// The answer being typed into a question's or a decision's field, by the need's id.
    @State private var words: [String: String] = [:]

    private var engine: EngineClient { model.engine }
    private var needs: [NeedItem] { engine.needs.filter { $0.projectId == project.id } }
    /// The project's runs, its orchestrator's included, oldest first as the engine lists them.
    private var runs: [ActivityRun] { engine.activity.filter { $0.projectId == project.id && $0.chat != true } }
    private var reports: [ProjectReport] { ProjectReports(engine.extras["reports"]?["projects"]?[project.id]).items }
    private var waking: Bool { wakeChoice ?? project.settings?.wakeOnReports ?? false }

    var body: some View {
        VStack(spacing: 0) {
            needsSection
            Divider().overlay(Theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    workingSection
                    Divider().overlay(Theme.line)
                    finishedSection
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.window)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onChange(of: project.settings?.wakeOnReports ?? false) { _, _ in wakeChoice = nil }
        .onAppear { ProjectTabWatch.shared.shows(project.id, tab: .now, engine: engine) }
        .onDisappear { ProjectTabWatch.shared.hides(project.id, tab: .now, engine: engine) }
    }

    // MARK: Needs you

    private var needsSection: some View {
        VStack(spacing: 0) {
            ProjectSectionHeader(title: "Needs you", count: needs.count)
            if needs.isEmpty {
                QuietLine(text: "Nothing needs you right now.")
            } else {
                // However many there are, they scroll within a space of their own and never push the sections below
                // out of the tab (#489's stack: at most 60% of what is left after the header).
                ConversationRequests(needs, availableHeight: max(140, height - 32)) { need in
                    NeedCard(
                        model: model, need: need, problem: problems[need.id],
                        words: Binding(get: { words[need.id] ?? "" }, set: { words[need.id] = $0 }),
                        answer: answer
                    )
                }
            }
        }
    }

    // MARK: Working now

    private var workingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Working now").sectionLabel()
                Spacer(minLength: 0)
                Toggle("Reports wake the orchestrator", isOn: wakeBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11.5))
                    .disabled(engine.status != .connected || project.archivedAt != nil)
                    .help("When a run the orchestrator handed out ends, its report is given to the orchestrator at once, instead of waiting to be read")
            }
            Text("When a run the orchestrator handed out ends, its report is given to the orchestrator at once, instead of waiting to be read.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tx3)
                .formFooter()
            if runs.isEmpty {
                QuietLine(text: "Nobody is working right now.")
            } else {
                ForEach(runs) { run in
                    WorkingRow(engine: engine, run: run, waking: waking) {
                        model.openAgent(run.conversationId, in: project.id)
                    }
                }
            }
        }
    }

    private var wakeBinding: Binding<Bool> {
        Binding(
            get: { waking },
            set: { on in
                wakeChoice = on
                engine.perform("projects.set", ["id": project.id, "settings": ["wakeOnReports": on]])
            }
        )
    }

    // MARK: Finished today

    private var finishedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finished today").sectionLabel()
            if reports.isEmpty {
                QuietLine(text: "Nothing has finished today yet.")
            } else {
                ForEach(reports) { report in
                    FinishedRow(engine: engine, report: report)
                }
            }
        }
    }

    // MARK: Answering

    /// Sends one answer to a need through the one request every kind answers by (`needs.answer`, docs/projects.md,
    /// 4.2), and keeps the engine's refusal on the card it was given from.
    private func answer(_ need: NeedItem, _ reply: [String: Any]) {
        Task {
            do {
                try await engine.call("needs.answer", ["id": need.id, "answer": reply])
                problems[need.id] = nil
                words[need.id] = nil
            } catch {
                problems[need.id] = error.localizedDescription
            }
        }
    }
}

// MARK: - The bits both a tab and the Dashboard's columns show

/// A section's header on a board tab and in a Dashboard column: its name, and a count when there is one.
struct ProjectSectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title).sectionLabel()
            if let count, count > 0 {
                Text(String(count)).font(Theme.label).monospacedDigit().foregroundStyle(Theme.tx3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// One quiet line where a section has nothing to say.
struct QuietLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.tx3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
    }
}

// MARK: - The cards

/// One need's card: what is asked, which agent asks and on what, and the controls that answer it in place. Approvals
/// and questions the Inbox already answers reuse its card; every other kind has its own here. Shown in the board's Now
/// tab and in a Dashboard column (#481).
struct NeedCard: View {
    let model: AppModel
    let need: NeedItem
    let problem: String?
    /// The answer typed into this card's field.
    @Binding var words: String
    let answer: (NeedItem, [String: Any]) -> Void
    /// Whether the card is in a narrower place than the Now tab, such as a Dashboard column (#481): its row then takes
    /// two lines rather than folding down a word at a time. Off on the Now tab, which has the width.
    var compact = false

    private var engine: EngineClient { model.engine }
    private var agent: AgentProfile? { engine.agent(need.agentId ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            card
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Theme.bad)
            }
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    @ViewBuilder
    private var card: some View {
        switch need.kind {
        case "approval":
            if need.projectSwitch != nil {
                switchCard
            } else if let item = engine.inbox.first(where: { $0.id == need.id }) {
                // The Inbox's own card, which answers it as it does today (`inbox.decide` and `inbox.answer`).
                InboxCard(engine: engine, item: item, showsSource: true, compact: compact)
            } else {
                // The Inbox item has not reached the app, or belongs to a version of a chat the person is not looking at.
                plainCard
            }
        case "question":
            if need.blocking, let item = engine.inbox.first(where: { $0.id == need.id }) {
                InboxCard(engine: engine, item: item, showsSource: true, compact: compact)
            } else {
                questionCard
            }
        case "decision":
            decisionCard
        case "reach":
            reachCard
        case "rule":
            // The Rules tab's own card, so a proposal reads and answers the same in both places.
            RuleProposalCard(engine: engine, need: need)
        case "limit":
            limitCard
        default:
            // A kind this app does not know: the conversation it came from answers it there.
            plainCard
        }
    }

    /// "Orchestrator asks, in Put together a short walkthrough for Friday · asked 5 min ago".
    private var who: some View {
        HStack(spacing: 8) {
            AgentAvatar(agent: agent, size: 18)
            // On one line, in a Dashboard column's narrower card as on the Now tab's (#481): the name keeps its
            // width and the conversation's title gives way, rather than the name folding down a letter at a time.
            Text(need.agentName ?? "Someone").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.tx)
                .lineLimit(1).layoutPriority(1)
            place
            Spacer(minLength: 6)
            Text("asked \(LimitsFormat.ago(LimitsFormat.date(need.createdAt), now: .now))")
                .font(.system(size: 11)).foregroundStyle(Theme.tx3).fixedSize()
        }
    }

    /// Where it was asked: "in" a conversation's title or, for a worker's question (#507), "in sub-chat “Fix login”",
    /// which opens the sub-chat in place of the board, and "on #28 Fix login" when its run was handed a piece of work.
    @ViewBuilder
    private var place: some View {
        if need.fromSubChat, let project = need.projectId {
            HStack(spacing: 4) {
                Text("in").foregroundStyle(Theme.tx3).fixedSize()
                Button(need.placeWords) { model.openAgent(need.conversationId, in: project) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.acc)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                    .help("Open the sub-chat in place of the board")
                if let work = workWords {
                    Text("on \(work)").foregroundStyle(Theme.tx3).lineLimit(1).truncationMode(.tail)
                }
            }
            .font(.system(size: 11.5))
        } else {
            Text("in \(need.placeWords)")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tx3).lineLimit(1).truncationMode(.middle)
        }
    }

    /// The piece of work a worker's run was handed, with its title when the app has the project's list (#507).
    private var workWords: String? {
        guard let id = need.work else { return nil }
        let project = need.projectId ?? ""
        let pieces = ProjectWork(engine.extras["work"]?["projects"]?[project]).items
            + GitHubWork(engine.extras["github"]?["projects"]?[project]).issues
        guard let title = pieces.first(where: { $0.id == id })?.title, !title.isEmpty else { return "#\(id)" }
        return "#\(id) \(title)"
    }

    /// A card of one's own, in the Inbox card's manner.
    private func own(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            // A wide card puts the name, the conversation and the kind on one line; a narrow one, such as a
            // Dashboard column's, puts the name and kind on the first line and the conversation and time on the
            // second, so the name keeps its width and the title gives way (#481).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    who
                    Text(label).font(.system(size: 11)).foregroundStyle(Theme.acc).fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        AgentAvatar(agent: agent, size: 18)
                        Text(need.agentName ?? "Someone").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.tx)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(label).font(.system(size: 11)).foregroundStyle(Theme.acc).fixedSize()
                    }
                    HStack(spacing: 6) {
                        place
                        Spacer(minLength: 6)
                        Text("asked \(LimitsFormat.ago(LimitsFormat.date(need.createdAt), now: .now))")
                            .font(.system(size: 11)).foregroundStyle(Theme.tx3).fixedSize()
                    }
                }
            }
            content()
        }
        .font(.system(size: 12.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, 11)
        .panel(fill: Theme.panel, border: Theme.line2)
    }

    /// The approval's call, for the line that says what would happen.
    private var call: ToolCall? {
        need.tool.map { ToolCall(callId: "", name: $0, arguments: need.arguments ?? .null) }
    }

    /// The plain card for a kind another issue answers: what it says, and where to answer it.
    private var plainCard: some View {
        own(need.named) {
            Text(need.question ?? need.text ?? need.change?.summary ?? call?.summary ?? need.named)
                .foregroundStyle(Theme.tx)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            openConversation
        }
    }

    /// A button that opens the conversation the need came from.
    private var openConversation: some View {
        Button("Open “\(need.rootTitle.isEmpty ? "New conversation" : need.rootTitle)”") {
            model.selection = .conversation(need.rootConversationId)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.acc)
        .font(.system(size: 12))
    }

    /// A question put with `needs_you`: a typed answer goes to the asking conversation as a message.
    private var questionCard: some View {
        own("question") {
            Text(need.question ?? "").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Type an answer…", text: $words)
                    .textFieldStyle(.plain)
                    .sendsOnReturn { answer(need, ["kind": "question", "text": words]) }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .panel(radius: 8, fill: Color.black.opacity(0.15), border: Theme.line2)
                Button("Send") { answer(need, ["kind": "question", "text": words]) }
                    .buttonStyle(.piPrimary)
                    .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// A decision: a button for each choice, and a field to answer in one's own words when it allows that.
    private var decisionCard: some View {
        own("decision") {
            Text(need.question ?? "").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let choices = need.choices {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ForEach(choices, id: \.id) { choice in
                            Button(choice.label) { answer(need, ["kind": "decision", "choice": choice.id]) }
                                .buttonStyle(.piSecondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(choices, id: \.id) { choice in
                            Button(choice.label) { answer(need, ["kind": "decision", "choice": choice.id]) }
                                .buttonStyle(.piSecondary)
                        }
                    }
                }
            }
            if need.words == true {
                HStack(spacing: 8) {
                    TextField("Or answer in your own words…", text: $words)
                        .textFieldStyle(.plain)
                        .sendsOnReturn { answer(need, ["kind": "decision", "text": words]) }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .panel(radius: 8, fill: Color.black.opacity(0.15), border: Theme.line2)
                    Button("Send") { answer(need, ["kind": "decision", "text": words]) }
                        .buttonStyle(.piPrimary)
                        .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// More reach: what it would let agents do, and the person's Allow or Refuse — the contract's own words (7.2),
    /// which the conversation's card uses too, so one wording answers this everywhere.
    private var reachCard: some View {
        own("more reach") {
            Text(need.change?.summary ?? "").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let why = need.why {
                Text("Why: \(why)").foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Allow") { answer(need, ["kind": "reach", "allow": true]) }
                    .buttonStyle(.piPrimary)
                Button("Refuse") { answer(need, ["kind": "reach", "allow": false]) }
                    .buttonStyle(.piDanger)
                Spacer(minLength: 0)
            }
        }
    }

    /// A start the project's limit stopped: what it wanted to do, and whether to start it anyway.
    private var limitCard: some View {
        own("held back by a limit") {
            if let start = need.start {
                let what = [start.title, start.task].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
                if !what.isEmpty {
                    Text("\(start.agentName ?? "An agent") wants to start “\(what)”")
                        .foregroundStyle(Theme.tx).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Past the project's limit: \(need.limit?.reason ?? "the project's limit stops new work"). The person can start it anyway from here, or raise the limit in the project's settings.")
                .foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Start Anyway") { answer(need, ["kind": "limit", "start": true]) }
                    .buttonStyle(.piPrimary)
                Button("Leave It") { answer(need, ["kind": "limit", "start": false]) }
                    .buttonStyle(.piSecondary)
                Spacer(minLength: 0)
            }
        }
    }

    /// One of the project's switches is off, so the approval can only be allowed once or denied (8.1).
    private var switchCard: some View {
        own("asks each time") {
            Text(need.question ?? call?.summary ?? "")
                .font(need.tool == "bash" ? Theme.mono : .system(size: 12.5))
                .foregroundStyle(Theme.tx)
                .textSelection(.enabled)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.black.opacity(0.18), in: .rect(cornerRadius: 7))
            if let switchWords = need.switchWords {
                Text("One of the project's switches is off, so it asks each time: \(switchWords). The Settings tab can turn it on.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tx3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Allow Once") { answer(need, ["kind": "approval", "decision": "once"]) }
                    .buttonStyle(.piPrimary)
                Button("Deny") { answer(need, ["kind": "approval", "decision": "deny"]) }
                    .buttonStyle(.piDanger)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Working now

/// One agent working in the project: its avatar and name, its model, how long, its last line, and whether its report
/// will wake the orchestrator. Clicking it opens its conversation in place of the board (#473). Shown in the board's
/// Now tab, and in a Dashboard column with `compact`, which drops the conversation's title and the words about waking
/// so that it fits a column's width (#481).
struct WorkingRow: View {
    let engine: EngineClient
    let run: ActivityRun
    let waking: Bool
    var compact = false
    let open: () -> Void

    private var agent: AgentProfile? { engine.agent(run.runsAs ?? run.agentId ?? "") }
    private var watch: WakeItem? {
        engine.wakes.first { $0.state == "running" && $0.kind == "subchat" && $0.ref == String(run.conversationId) }
    }

    /// The model the agent runs on, by name.
    private var modelName: String? {
        let ref = agent?.model ?? engine.defaultModel
        guard let ref else { return nil }
        return engine.allModels.first { $0.ref == ref }?.name ?? ref.modelId
    }

    var body: some View {
        Button(action: open) {
            row
                .padding(.horizontal, 10).padding(.vertical, 8)
                .panel()
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open \(agent?.name ?? "this agent")’s conversation in place of the board")
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 10) {
            mark.frame(width: 16)
            AgentAvatar(agent: agent, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent?.name ?? "An agent").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.tx)
                    if let modelName {
                        Text("· \(modelName)").font(.system(size: 11)).foregroundStyle(Theme.tx3).lineLimit(1)
                    }
                    if !run.title.isEmpty, !compact {
                        Text("· \(run.title)").font(.system(size: 11)).foregroundStyle(Theme.tx3).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    clock
                }
                if let line = run.lastLine, !line.isEmpty {
                    Text(line).font(.system(size: 12)).foregroundStyle(Theme.tx2).lineLimit(1)
                }
                if let waking = watchWords, !compact {
                    Text(waking).font(.system(size: 11)).foregroundStyle(Theme.tx3).lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var mark: some View {
        if run.status == "waiting" {
            Dot(color: Theme.warn)
                .help("Waiting for you")
        } else if run.limit != nil {
            Image(systemName: "hourglass").font(.system(size: 11)).foregroundStyle(Theme.warn)
                .help("Waiting for a provider's limit")
        } else {
            Spinner()
        }
    }

    /// A clock that ticks for as long as it has been working.
    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince1970 - run.since / 1000))
            Text(seconds < 3600 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : String(format: "%dh %02dm", seconds / 3600, seconds % 3600 / 60))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.tx3)
                .fixedSize()
        }
    }

    /// Whether its report will wake the orchestrator: its watch's own choice, or the project's switch (3.10).
    private var watchWords: String? {
        guard let watch else { return nil }
        switch watch.wake ?? (waking ? "each" : "never") {
        case "each": return "Its report wakes the orchestrator when it ends."
        case "never": return "Its report will not wake the orchestrator; it waits to be read."
        case "all": return "Its report wakes the orchestrator with its batch\(watch.batch.map { " \"\($0)\"" } ?? "") when all of it has ended."
        case "failure": return "Its report wakes the orchestrator only if the run fails."
        default: return nil
        }
    }
}

// MARK: - Finished today

/// One report since midnight: which agent, on what, how it ended, when, and a mark on what the orchestrator has not
/// read yet.
private struct FinishedRow: View {
    let engine: EngineClient
    let report: ProjectReport

    private var agent: AgentProfile? { engine.agent(report.agentId) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentAvatar(agent: agent, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent?.name ?? "An agent").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.tx).lineLimit(1)
                    if !report.title.isEmpty {
                        Text("on \(report.title)").font(.system(size: 11.5)).foregroundStyle(Theme.tx2).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                }
                HStack(spacing: 6) {
                    outcome
                    if let endedAt = report.endedAt {
                        Text(endedAt.formatted(.dateTime.hour().minute()))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tx3).fixedSize()
                    }
                    if report.deliveredBy == nil {
                        Tag("not read yet", .warn)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .panel()
    }

    /// How the run ended, in the words of a person skimming the day.
    private var outcome: some View {
        switch report.outcome {
        case "answered": Tag("done", .ok)
        case "failed": Tag("failed", .bad)
        case "stopped": Tag("stopped", .warn)
        default: Tag(report.outcome ?? "")
        }
    }
}
