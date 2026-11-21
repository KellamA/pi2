import ComposeKit
import ComputerKit
import SwiftUI

/// One thing waiting on the person, with the controls to answer it. Used in the transcript, the inbox, and above the
/// composer for a subagent's requests.
struct InboxCard: View {
    let engine: EngineClient
    let item: InboxItem
    /// Whether to say which agent and conversation is asking; off where the surrounding view already shows it.
    let showsSource: Bool
    /// Whether the card is in a narrower place than the Inbox, such as a Dashboard column (#481): its row then takes
    /// two lines rather than folding every part of it down a word at a time. Off everywhere else, so the Inbox's and the
    /// menu bar's cards read exactly as they did.
    var compact = false
    @State private var answer = ""
    /// The answer's request is on its way: a second click while it goes does nothing (#481).
    @State private var sending = false

    private var agent: AgentProfile? { engine.allAgents.first { $0.name == item.agentName } }
    private var isApproval: Bool { item.kind == "approval" }
    /// For a computer action: the app it is for.
    private var targetApp: String? {
        item.tool == "computer" ? item.arguments["app"]?.stringValue.map(ComputerController.name(of:)) : nil
    }

    private var isBrowser: Bool { item.tool == "browser" }
    /// A schedule the agent wants to set for itself.
    private var isSchedule: Bool { item.tool == "schedule_task" }
    /// A worktree the agent wants made for a sub-chat it hands work to (delegate's `worktree`).
    private var isWorktree: Bool { item.tool == "delegate" }
    /// For a browser action: the site it would act on, when the app could say.
    private var targetSite: String? { isBrowser ? item.site.flatMap { $0.isEmpty ? nil : $0 } : nil }
    /// Whether the action is put in words by the app or the engine, rather than shown as the call was written.
    private var inWords: Bool { targetApp != nil || isBrowser || isSchedule || isWorktree }
    /// The line that says what would happen. For a schedule, when it would run: its title is in the heading and its
    /// prompt below.
    private var described: String {
        if isSchedule { return item.when ?? item.question ?? item.call.summary }
        return inWords ? (item.question ?? item.call.summary) : item.call.summary
    }
    /// Words to read in full before deciding: what a scheduled run would be told, or what would be typed into a web page
    /// when it is too long for the line that describes it.
    private var longText: (text: String, label: String)? {
        if isSchedule, let prompt = item.arguments["prompt"]?.stringValue {
            return (prompt.trimmingCharacters(in: .whitespacesAndNewlines), "What the agent will be told to do")
        }
        if isWorktree, let task = item.arguments["task"]?.stringValue {
            return (task.trimmingCharacters(in: .whitespacesAndNewlines), "The task the sub-chat will be given")
        }
        guard isBrowser, item.arguments["action"]?.stringValue == "type", let text = item.arguments["text"]?.stringValue, text.count > 80 else { return nil }
        return (text, "The text to be typed")
    }
    /// What the "always" button covers, and what it says when hovered. Nil when there is nothing it could cover.
    private var always: (title: String, help: String)? {
        // A project's switch that is off asks each time on purpose, and only the project's Settings can turn it on: in a
        // conversation the card offers Allow Once and Deny alone, as the Now tab's card does, and the engine refuses
        // anything else (#553).
        if item.projectSwitch != nil { return nil }
        // A schedule runs later with no one watching, so each one is a decision of its own.
        if isSchedule { return nil }
        if let targetApp { return ("Always Allow in \(targetApp)", "Stop asking about \(targetApp) for the rest of this conversation") }
        if isBrowser { return targetSite.map { ("Always Allow on \($0)", "Stop asking about actions on \($0) for the rest of this conversation") } }
        if isWorktree { return ("Always Allow Here", "Stop asking about worktrees for sub-chats in this conversation") }
        return ("Always Allow \(item.tool) Here", "Stop asking about \(item.tool) in this conversation")
    }

    /// "Atlas wants to run a command", in the words of what the tool does.
    private var request: String {
        let who = item.agentName ?? "The agent"
        if let targetApp { return "\(who) wants to use \(targetApp)" }
        if isBrowser { return "\(who) wants to act on \(targetSite ?? "a web page")" }
        if isWorktree { return "\(who) wants a worktree for a sub-chat" }
        if isSchedule {
            let title = (item.arguments["title"]?.stringValue ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return title.isEmpty ? "\(who) wants to schedule work" : "\(who) wants to schedule “\(title)”"
        }
        return switch item.tool {
        case "bash": item.background == true ? "\(who) wants to run a command in the background" : "\(who) wants to run a command"
        case "write": "\(who) wants to write a file"
        case "edit": "\(who) wants to edit a file"
        case "write_document": "\(who) wants to write \(documentKind)"
        default: "\(who) wants to use \(item.tool)"
        }
    }

    /// What is asked, in the row's words: an approval's request, or a question's asking.
    private var asking: some View {
        Text(isApproval ? request : "\(item.agentName ?? "The agent") has a question")
            .font(.system(size: 13, weight: .semibold))
    }

    /// What a document written by the agent is, from the ending of the file name it chose: the file itself is shown below.
    private var documentKind: String {
        switch (item.arguments["path"]?.stringValue ?? "").split(separator: ".").last?.lowercased() {
        case "docx": "a Word document"
        case "rtf": "an RTF document"
        case "odt": "an OpenDocument file"
        case "html": "an HTML page"
        default: "a document"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if compact {
                // A Dashboard column's card is narrower than the Inbox's: what is asked takes up to two lines and the
                // hint shortens, rather than every part of the row folding down a word at a time (#481).
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        if showsSource { AgentAvatar(agent: agent, size: 20) }
                        asking.lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        if showsSource {
                            Text(item.title).foregroundStyle(Theme.tx2).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 6)
                        Text("waits for you").font(.system(size: 11)).foregroundStyle(Theme.tx3).fixedSize()
                    }
                }
            } else {
                HStack(spacing: 8) {
                    if showsSource { AgentAvatar(agent: agent, size: 20) }
                    asking
                    if showsSource {
                        Text(item.title).foregroundStyle(Theme.tx2).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text("waits for you · survives restarts").font(.system(size: 11)).foregroundStyle(Theme.tx3)
                }
            }
            if isApproval {
                // An action on a window or a web page is described in words by the app that will do it, and a schedule
                // by the engine; a command is shown as written.
                Text(described)
                    .font(inWords ? .system(size: 13) : Theme.mono)
                    .foregroundStyle(Theme.tx)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.black.opacity(0.18), in: .rect(cornerRadius: 7))
                if let longText {
                    // In full: the person approves the words, not their count.
                    ScrollView {
                        Text(longText.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.tx2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                    }
                    .frame(maxHeight: 140)
                    .background(Color.black.opacity(0.12), in: .rect(cornerRadius: 7))
                    .accessibilityLabel(longText.label)
                }
                if item.tool == "bash", item.background == true {
                    // The same words as the conversation page's card (`backgroundCaption` in tools.js).
                    Text("It is started and left running, with no time limit, until it ends, the agent or you stop it, this conversation is archived, or pi² stops. Activity lists it while it runs, with a Stop button.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tx3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isSchedule {
                    Text("Each run starts a new conversation with this agent and works with no one watching. You can turn the schedule off or delete it in Activity.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tx3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Four choices do not fit a narrow card, such as the menu bar's, on one line; they wrap to two, or three.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        onceButton
                        ruleButton
                        alwaysButton
                        denyButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            onceButton
                            ruleButton
                        }
                        HStack(spacing: 8) {
                            alwaysButton
                            denyButton
                        }
                    }
                    // A rule's button that says "in This Repository" may need a line of its own.
                    VStack(alignment: .leading, spacing: 8) {
                        onceButton
                        ruleButton
                        HStack(spacing: 8) {
                            alwaysButton
                            denyButton
                        }
                    }
                }
            } else {
                Text(item.question ?? "").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("Type an answer…", text: $answer, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .sendsOnReturn(send)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .panel(radius: 8, fill: Color.black.opacity(0.15), border: Theme.line2)
                    Button("Send") { send() }
                        .buttonStyle(.piPrimary)
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .font(.system(size: 12.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, 11)
        .panel(fill: isApproval ? Theme.warn.opacity(0.10) : Theme.panel, border: isApproval ? Theme.warn.opacity(0.4) : Theme.line2)
    }

    private var onceButton: some View {
        Button("Allow Once") { decide("once") }
            .buttonStyle(.piPrimary)
    }

    @ViewBuilder
    private var alwaysButton: some View {
        if let always {
            Button(always.title) { decide("always") }
                .buttonStyle(.piSecondary)
                .help(always.help)
        }
    }

    /// For a command the engine can make a rule of: allow commands that start with the same words, in this folder (and,
    /// in a repository, its worktrees pi² makes), from now on. The engine makes the rule it offered; only the choice is sent.
    @ViewBuilder
    private var ruleButton: some View {
        // A project's switch asks about one action, so there is no rule to make of it either (#553).
        if item.projectSwitch == nil, item.tool == "bash", let rule = item.rule, !rule.words.isEmpty {
            let who = item.agentName ?? "This agent"
            Button { decide("rule") } label: {
                // A long command is cut in its middle, so the button still says where the rule holds.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Always Allow").fixedSize()
                    Text(rule.command).font(.system(size: 12, design: .monospaced)).truncationMode(.middle)
                    Text(rule.place).fixedSize()
                }
            }
            .buttonStyle(.piSecondary)
            .help("\(who) may then run commands that start with “\(rule.command)” in \(engine.folderName(rule.folder))\(rule.worktrees == true ? " and the same folder of every worktree pi² makes from that repository," : "") without asking, in this conversation and later ones. Anything more complicated still asks. To undo this, remove it under Allowed commands in the agent’s settings.")
        }
    }

    private var denyButton: some View {
        Button("Deny") { decide("deny") }
            .buttonStyle(.piDanger)
    }

    private func decide(_ decision: String) {
        guard !sending else { return }
        sending = true
        Task {
            do { try await engine.call("inbox.decide", ["id": item.id, "decision": decision]) }
            catch { engine.lastError = error.localizedDescription }
            sending = false
        }
    }

    private func send() {
        guard !sending, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        let text = answer
        answer = ""
        Task {
            do { try await engine.call("inbox.answer", ["id": item.id, "text": text]) }
            catch { engine.lastError = error.localizedDescription }
            sending = false
        }
    }
}

/// Everything waiting on the person, across all conversations.
struct InboxView: View {
    @Bindable var model: AppModel
    private var engine: EngineClient { model.engine }
    /// Windows of a subscription nearly used up while runs on it were going (limits.ts): below what waits on the person.
    private var notices: [PlanLimits.Notice] { PlanLimits(engine.extras["limits"])?.notices ?? [] }

    var body: some View {
        Group {
            if engine.inbox.isEmpty && notices.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "Nothing needs you", message: "Approvals and questions from your agents land here. You can answer them from the transcript too.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(engine.inbox) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                InboxCard(engine: engine, item: item, showsSource: true)
                                Button("Open “\(item.rootTitle.isEmpty ? "New conversation" : item.rootTitle)”") {
                                    model.selection = .conversation(item.rootConversationId)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.acc)
                                .font(.system(size: 12))
                            }
                        }
                        ForEach(notices) { notice in
                            LimitNoticeCard(engine: engine, notice: notice, open: { model.selection = .conversation($0) }, showUsage: { model.selection = .usage })
                        }
                    }
                    .padding(.horizontal, 28).padding(.vertical, 22)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.window)
        .navigationTitle("Inbox")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let parts = [
            engine.inbox.isEmpty ? nil : "\(engine.inbox.count) waiting",
            notices.isEmpty ? nil : notices.count == 1 ? "1 notice" : "\(notices.count) notices",
        ]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

/// A calm, centred "nothing here" with the pi² accent.
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.acc)
                .frame(width: 60, height: 60)
                .background(Theme.acc.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(message).foregroundStyle(Theme.tx2).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
