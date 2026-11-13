import ComputerKit
import SwiftUI

/// One thing waiting on the person, with the controls to answer it. Used in the transcript, the inbox, and above the
/// composer for a subagent's requests.
struct InboxCard: View {
    let engine: EngineClient
    let item: InboxItem
    /// Whether to say which agent and conversation is asking; off where the surrounding view already shows it.
    let showsSource: Bool
    @State private var answer = ""

    private var agent: AgentProfile? { engine.agents.first { $0.name == item.agentName } }
    private var isApproval: Bool { item.kind == "approval" }
    /// For a computer action: the app it is for.
    private var targetApp: String? {
        item.tool == "computer" ? item.arguments["app"]?.stringValue.map(ComputerController.name(of:)) : nil
    }

    private var isBrowser: Bool { item.tool == "browser" }
    /// For a browser action: the site it would act on, when the app could say.
    private var targetSite: String? { isBrowser ? item.site.flatMap { $0.isEmpty ? nil : $0 } : nil }
    /// Whether the action is put in words by the app that will do it, rather than shown as the call was written.
    private var inWords: Bool { targetApp != nil || isBrowser }
    /// For typing into a web page: the whole text, when it is too long for the line that describes it.
    private var longText: String? {
        guard isBrowser, item.arguments["action"]?.stringValue == "type", let text = item.arguments["text"]?.stringValue, text.count > 80 else { return nil }
        return text
    }
    /// What the "always" button covers, and what it says when hovered. Nil when there is nothing it could cover.
    private var always: (title: String, help: String)? {
        if let targetApp { return ("Always Allow in \(targetApp)", "Stop asking about \(targetApp) for the rest of this conversation") }
        if isBrowser { return targetSite.map { ("Always Allow on \($0)", "Stop asking about actions on \($0) for the rest of this conversation") } }
        return ("Always Allow \(item.tool) Here", "Stop asking about \(item.tool) in this conversation")
    }

    /// "Atlas wants to run a command", in the words of what the tool does.
    private var request: String {
        let who = item.agentName ?? "The agent"
        if let targetApp { return "\(who) wants to use \(targetApp)" }
        if isBrowser { return "\(who) wants to act on \(targetSite ?? "a web page")" }
        return switch item.tool {
        case "bash": "\(who) wants to run a command"
        case "write": "\(who) wants to write a file"
        case "edit": "\(who) wants to edit a file"
        case "write_document": "\(who) wants to write \(documentKind)"
        default: "\(who) wants to use \(item.tool)"
        }
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
            HStack(spacing: 8) {
                if showsSource { AgentAvatar(agent: agent, size: 20) }
                Text(isApproval ? request : "\(item.agentName ?? "The agent") has a question")
                    .font(.system(size: 13, weight: .semibold))
                if showsSource {
                    Text(item.title).foregroundStyle(Theme.tx2).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("waits for you · survives restarts").font(.system(size: 11)).foregroundStyle(Theme.tx3)
            }
            if isApproval {
                // An action on a window or a web page is described in words by the app that will do it; a command is shown as written.
                Text(inWords ? (item.question ?? item.call.summary) : item.call.summary)
                    .font(inWords ? .system(size: 13) : Theme.mono)
                    .foregroundStyle(Theme.tx)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.black.opacity(0.18), in: .rect(cornerRadius: 7))
                if let longText {
                    // What will be typed, in full: the person approves the words, not their count.
                    ScrollView {
                        Text(longText)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.tx2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                    }
                    .frame(maxHeight: 140)
                    .background(Color.black.opacity(0.12), in: .rect(cornerRadius: 7))
                    .accessibilityLabel("The text to be typed")
                }
                // Four choices do not fit a narrow card, such as the menu bar's, on one line; they wrap to two.
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
                }
            } else {
                Text(item.question ?? "").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("Type an answer…", text: $answer)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .panel(radius: 8, fill: Color.black.opacity(0.15), border: Theme.line2)
                        .onSubmit(send)
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

    /// For a command the engine can make a rule of: allow commands that start with the same words, in this folder, from
    /// now on. The engine makes the rule it offered; only the choice is sent.
    @ViewBuilder
    private var ruleButton: some View {
        if item.tool == "bash", let rule = item.rule, !rule.words.isEmpty {
            let who = item.agentName ?? "This agent"
            Button { decide("rule") } label: {
                Text("Always Allow \(Text(rule.command).font(.system(size: 12, design: .monospaced))) Here")
            }
            .buttonStyle(.piSecondary)
            .help("\(who) may then run commands that start with “\(rule.command)” in \(engine.folderName(rule.folder)) without asking, in this conversation and later ones. Anything more complicated still asks. Remove the rule in the agent’s settings.")
        }
    }

    private var denyButton: some View {
        Button("Deny") { decide("deny") }
            .buttonStyle(.piDanger)
    }

    private func decide(_ decision: String) {
        engine.perform("inbox.decide", ["id": item.id, "decision": decision])
    }

    private func send() {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        engine.perform("inbox.answer", ["id": item.id, "text": answer])
        answer = ""
    }
}

/// Everything waiting on the person, across all conversations.
struct InboxView: View {
    @Bindable var model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        Group {
            if engine.inbox.isEmpty {
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
                    }
                    .padding(.horizontal, 28).padding(.vertical, 22)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.window)
        .navigationTitle("Inbox")
        .navigationSubtitle(engine.inbox.isEmpty ? "" : "\(engine.inbox.count) waiting")
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
