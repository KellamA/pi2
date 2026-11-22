import MenuKit
import SwiftUI

// The board's Rules tab (#476): the project's rules, read and changed, and a proposal waiting to be answered.
// docs/design/projects.md ("Rules and notes") says what a rule is for; docs/projects.md (3.7) has its shape, (6.2) the
// cost in tokens, (3.9) the proposed rule and its answer.

/// A rule of a project, as the `projectRules` event sends it (docs/projects.md, 3.7). The array's order is the order
/// the prompt and this tab show, numbered from 1.
struct ProjectRule: Decodable, Equatable, Identifiable {
    /// Whom it binds.
    enum Binds: String, Decodable, CaseIterable, Identifiable {
        case orchestrator, everyone

        var id: String { rawValue }

        var title: String {
            switch self {
            case .orchestrator: "Orchestrator"
            case .everyone: "Every agent"
            }
        }
    }

    /// Who put it there: the person by hand, the orchestrator as the person dictated it, or an agent's proposal the
    /// person accepted (docs/projects.md, 3.7).
    enum AddedBy: Equatable {
        case person
        case agent(agentId: String, conversationId: Int)
        case proposal(agentId: String, conversationId: Int, need: String)
    }

    let id: String
    let text: String
    let binds: Binds
    let addedBy: AddedBy
    /// Milliseconds since 1970.
    let createdAt: Double

    private enum CodingKeys: String, CodingKey { case id, text, binds, addedBy, createdAt }
    private enum AddedKeys: String, CodingKey { case kind, agentId, conversationId, need }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        binds = try values.decode(Binds.self, forKey: .binds)
        let added = try values.nestedContainer(keyedBy: AddedKeys.self, forKey: .addedBy)
        let kind = try added.decode(String.self, forKey: .kind)
        switch kind {
        case "person":
            addedBy = .person
        case "agent":
            addedBy = .agent(
                agentId: try added.decode(String.self, forKey: .agentId),
                conversationId: try added.decode(Int.self, forKey: .conversationId))
        case "proposal":
            addedBy = .proposal(
                agentId: try added.decode(String.self, forKey: .agentId),
                conversationId: try added.decode(Int.self, forKey: .conversationId),
                need: try added.decode(String.self, forKey: .need))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown addedBy kind: \(kind)"))
        }
        createdAt = try values.decode(Double.self, forKey: .createdAt)
    }
}

struct ProjectRulesEvent: Decodable {
    let projects: [String: [ProjectRule]]
}

/// One thing waiting under Needs you, as the `needs` event sends it (docs/projects.md, 3.9): a discriminated union, with
/// the fields of the kinds that do not use them left out. The Rules tab reads a proposed rule from it, and the Now tab
/// the card of every kind; the sidebar counts what it holds by `projectId`. The whole array decodes whatever kinds are
/// in it, so a kind this app knows nothing of cannot take the list, a tab or the cards down.
struct NeedItem: Decodable, Equatable, Identifiable {
    struct Choice: Decodable, Equatable {
        let id: String
        let label: String
    }

    /// A reach request's change, as the person reads it (7.2): what it would let agents do.
    struct ReachChange: Decodable, Equatable {
        let summary: String
    }

    /// The start the project's limit stopped (8.3), as the person reads it.
    struct Start: Decodable, Equatable {
        let agentName: String?
        let title: String?
        let task: String?
    }

    /// What was over when the start was refused: `reason` is the sentence the person reads.
    struct LimitReading: Decodable, Equatable {
        let reason: String
    }

    let id: String
    /// Null for an approval or question of a conversation in no project.
    let projectId: String?
    let kind: String
    /// The conversation that asks, its root, and their titles, for "in …".
    let conversationId: Int
    let rootConversationId: Int
    let title: String
    let rootTitle: String
    /// The agent the conversation that asks runs as, and its name.
    let agentId: String?
    let agentName: String?
    /// Whether the agent is held until it is answered: true for approvals and ask_user questions only.
    let blocking: Bool
    /// Milliseconds since 1970.
    let createdAt: Double
    /// A proposed rule's text and whom it would bind, and why the agent proposes it.
    let text: String?
    let binds: ProjectRule.Binds?
    let why: String?
    /// A question's or a decision's words, its choices, and whether it takes an answer in the person's own words.
    let question: String?
    let choices: [Choice]?
    let words: Bool?
    /// An approval's call, and the switch of the project that asked when it is off (8.1): then it is answered with
    /// `once` or `deny` only.
    let tool: String?
    let arguments: JSONValue?
    let projectSwitch: String?
    /// More reach, and a start the project's limit stopped.
    let change: ReachChange?
    let start: Start?
    let limit: LimitReading?
    /// A worker's question or decision: the work item its run was handed, when it was handed one (#507).
    let work: Int?

    /// Whether a worker asks, in a sub-chat, rather than an agent in a conversation of its own (#507).
    var fromSubChat: Bool { conversationId != rootConversationId }

    /// Where it was asked, as a line names it: "sub-chat “Fix login”", or a conversation's title.
    var placeWords: String {
        guard fromSubChat else { return title.isEmpty ? rootTitle : title }
        return title.isEmpty ? "sub-chat \(conversationId)" : "sub-chat “\(title)”"
    }

    /// Which switch asked, in words the person reads, or the switch's own name when the app does not know it.
    var switchWords: String? {
        projectSwitch.map {
            switch $0 {
            case "startAgents": "starting agents without asking"
            case "fileWork": "filing work without asking"
            case "closeWork": "closing work without asking"
            case "makeAgents": "making agents without asking"
            case "addRules": "adding rules without asking"
            case "merge": "merging without asking"
            case "release": "releasing work without asking"
            case "passLimits": "going past the project's limits"
            default: $0
            }
        }
    }

    /// The line that says what it is, as the engine names the kinds to a person who answers the wrong one.
    var named: String {
        switch kind {
        case "approval": "a request for approval"
        case "question": "a question"
        case "decision": "a decision"
        case "reach": "a request for more reach"
        case "rule": "a proposed rule"
        case "limit": "a start held back by the project's limit"
        default: "something that waits for you"
        }
    }

    /// What it asks, in one short line: the menu bar item's list of what waits and its notifications (#481).
    var short: String {
        switch kind {
        case "approval":
            question ?? ToolCall(callId: "", name: tool ?? "", arguments: arguments ?? .null).summary
        case "question", "decision":
            question ?? ""
        case "reach":
            change?.summary ?? "Asks for more reach"
        case "rule":
            text.map { "Proposes a rule: \($0)" } ?? "Proposes a rule"
        case "limit":
            limitShort
        default:
            question ?? text ?? named
        }
    }

    /// A start held back by the limit, in one line: what it wanted to start, when the need says.
    private var limitShort: String {
        let what = [start?.title, start?.task].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        return what.isEmpty ? "A start is held back by the project's limit" : "Held back by the limit: \(what)"
    }
}

struct NeedItemsEvent: Decodable {
    let items: [NeedItem]
}

/// The Rules tab of the board (#476): a proposal above, what the rules cost, the rules themselves, and the field that
/// adds one. Changes reach the engine at once; each of them is in the next prompt of every agent the rule binds.
struct ProjectRulesTab: View {
    let model: AppModel
    let project: ProjectRow

    /// The one inset the list, the cost line and the add field share, as the conversation's own parts do.
    private let inset: CGFloat = 12

    private var engine: EngineClient { model.engine }
    private var rules: [ProjectRule] { engine.projectRules[project.id] ?? [] }
    private var proposals: [NeedItem] { engine.ruleNeeds[project.id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            // With nothing written and nothing proposed, the tab is its explanation, centred as the Notes tab's is.
            // A proposal is what the tab is about then, so the explanation waits until the list has something in it.
            if rules.isEmpty && proposals.isEmpty {
                RulesNotWrittenYet()
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(proposals) { need in
                            RuleProposalCard(engine: engine, need: need)
                        }
                        if !rules.isEmpty {
                            RuleCost(tokens: project.ruleTokens)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                                    RuleRow(engine: engine, projectId: project.id, number: index + 1, count: rules.count, rule: rule)
                                    if index < rules.count - 1 {
                                        Rectangle().fill(Theme.line).frame(height: 1)
                                    }
                                }
                            }
                            .panel(radius: 10)
                        }
                    }
                    .padding(inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider().overlay(Theme.line)
            AddRuleField(engine: engine, projectId: project.id, inset: inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.window)
    }
}

/// What the rules cost at every request (docs/projects.md, 6.2): an estimate made without a provider, the same for
/// every model.
private struct RuleCost: View {
    let tokens: ProjectRow.RuleTokens?

    private var words: String {
        guard let tokens else { return "" }
        return "About \(tokens.orchestrator) tokens with every request to the orchestrator, \(tokens.agents) to each other agent."
            + " The rules are read whole again at every request, so a shorter list costs less."
    }

    var body: some View {
        Text(words)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.tx3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The tab with no rules yet: what a rule is, and the two ways to write the first one.
private struct RulesNotWrittenYet: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 22))
                .foregroundStyle(Theme.tx3)
            Text("No rules yet.")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.tx)
            Text("A rule is a line your project keeps to. pi² sends it word for word, in full, to the orchestrator or to every agent at each of their requests; it is never summarised, so it holds however long the conversation runs.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.tx2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Write one below, or ask the orchestrator in the conversation to keep something as a rule: it will propose one, and you accept, change or refuse it here.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.tx2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - One rule

/// A rule of the project: its text, editable in place; whom it binds; who added it and when; and the ways to change it.
private struct RuleRow: View {
    let engine: EngineClient
    let projectId: String
    let number: Int
    let count: Int
    let rule: ProjectRule

    @State private var text: String
    @State private var problem: String?
    @State private var confirmingRemove = false
    @FocusState private var focused: Bool

    private var origin: String {
        let when = Date(timeIntervalSince1970: rule.createdAt / 1000).formatted(date: .abbreviated, time: .shortened)
        switch rule.addedBy {
        case .person:
            return "Added by you, \(when)"
        case .agent(let agentId, _):
            let name = engine.agent(agentId)?.name ?? "the orchestrator"
            return "Added by \(name), \(when)"
        case .proposal(let agentId, _, _):
            let name = engine.agent(agentId)?.name ?? "an agent"
            return "Proposed by \(name), accepted by you, \(when)"
        }
    }

    init(engine: EngineClient, projectId: String, number: Int, count: Int, rule: ProjectRule) {
        self.engine = engine
        self.projectId = projectId
        self.number = number
        self.count = count
        self.rule = rule
        _text = State(initialValue: rule.text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Wide enough for two digits and the dot, so that the text of rule 1 and rule 10 start in one column.
            Text("\(number).")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.tx3)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                // The plain field of the message composer, not the bezel a field is drawn with: a rule reads as a rule
                // that can be changed, not as an input box in a stack of them.
                TextField("Rule", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .lineLimit(1...40)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Rule \(number)")
                    .accessibilityValue(text)
                    .accessibilityHint(origin)
                    .sendsOnReturn { commit() }
                    .help("Click to change this rule; Return saves it")
                Text(origin)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tx3)
                if let problem {
                    Text(problem)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.bad)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 2) {
                BindsMenu(binds: rule.binds) { change("projects.rules.edit", ["binds": $0.rawValue]) }
                Button("Move Rule \(number) Up", systemImage: "chevron.up") { move(-1) }
                    .disabled(number == 1)
                    .help("Move this rule up")
                Button("Move Rule \(number) Down", systemImage: "chevron.down") { move(1) }
                    .disabled(number == count)
                    .help("Move this rule down")
                Button("Remove Rule \(number)", systemImage: "trash") { confirmingRemove = true }
                    .help("Remove this rule")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(Theme.tx3)
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
        .onChange(of: rule.text) { _, latest in
            // Follow what the engine says, unless the person is in the middle of typing.
            if !focused { text = latest }
        }
        .confirmationDialog("Remove rule \(number)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { change("projects.rules.remove", [:]) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(rule.text)” stops binding \(rule.binds == .everyone ? "every agent" : "the orchestrator") from its next request.")
        }
    }

    private func move(_ offset: Int) {
        // `to` is the place counted from 0 (docs/projects.md, 4.2).
        change("projects.rules.move", ["to": number - 1 + offset])
    }

    private func commit() {
        let tidy = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if tidy.isEmpty {
            text = rule.text
        } else if tidy != rule.text {
            text = tidy
            change("projects.rules.edit", ["text": tidy])
        }
    }

    private func change(_ method: String, _ extra: [String: Any]) {
        var params: [String: Any] = ["projectId": projectId, "id": rule.id]
        for (key, value) in extra { params[key] = value }
        Task {
            do {
                try await engine.call(method, params)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Whom a rule binds, as a small menu: choosing the other value changes the rule at once.
private struct BindsMenu: View {
    let binds: ProjectRule.Binds
    let choose: (ProjectRule.Binds) -> Void

    var body: some View {
        Menu {
            // The one it binds now ticked as the model menus tick theirs, so each row says only whom it stands for (#597).
            MenuChoices(ProjectRule.Binds.allCases.map { MenuChoice(id: $0.rawValue, title: $0.title, ticked: $0 == binds) }) { choice in
                if let value = ProjectRule.Binds(rawValue: choice.id) { choose(value) }
            }
        } label: {
            Text(binds.title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .frame(width: 56)
        }
        .background(Theme.card2, in: .rect(cornerRadius: 5))
        .contentShape(.rect)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .tint(Theme.tx2)
        .fixedSize()
        .padding(.vertical, 1)
        // One width for both labels, so that the rows' menus and the buttons beside them line up.
        .frame(width: 76, alignment: .trailing)
        .accessibilityLabel("Whom rule binds")
        .accessibilityValue(binds.title)
        .help("Whom this rule is sent to at every request")
    }
}

// MARK: - Adding a rule

/// The field that adds a rule, with whom it binds: one border around the field and its buttons, as the message field
/// has. An engine's refusal, a rule too long or the fiftieth one, shows under it in the engine's own words.
private struct AddRuleField: View {
    let engine: EngineClient
    let projectId: String
    let inset: CGFloat

    @State private var text = ""
    @State private var binds: ProjectRule.Binds = .everyone
    @State private var adding = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var words: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                TextField("Add a rule", text: $text, prompt: Text("Add a rule…"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .lineLimit(1...4)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .accessibilityLabel("New rule")
                    .sendsOnReturn { add() }
                BindsMenu(binds: binds) { binds = $0 }
                Button("Add", action: add)
                    .buttonStyle(.piPrimary)
                    .disabled(adding || words.isEmpty)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .panel(radius: 12, border: focused ? Theme.acc.opacity(0.55) : Theme.line2)
            if let problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.bad)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, inset)
            }
        }
        .padding(.horizontal, inset).padding(.top, 8).padding(.bottom, inset)
    }

    private func add() {
        guard !words.isEmpty, !adding else { return }
        let sent = text
        adding = true
        Task {
            do {
                try await engine.call("projects.rules.add", ["projectId": projectId, "text": sent, "binds": binds.rawValue])
                text = ""
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            adding = false
        }
    }
}

// MARK: - A proposed rule

/// A rule an agent proposes (docs/projects.md, 3.9): who proposes it, the text, whom it would bind, and the answer.
/// Accepting with the text or the binding changed is an answer in its own right, so Edit… answers, too. The Rules tab
/// shows it under the list, and the Now tab under Needs you (#472), so that a proposal is answered in the same words
/// and with the same buttons in both places.
struct RuleProposalCard: View {
    let engine: EngineClient
    let need: NeedItem

    @State private var editing = false
    @State private var text = ""
    @State private var binds: ProjectRule.Binds = .everyone
    @State private var answering = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Proposed by \(need.agentName ?? "an agent")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tx)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Date(timeIntervalSince1970: need.createdAt / 1000).formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tx3)
                    .fixedSize()
            }
            if editing {
                // A field here, and not plain text: it says that this is being changed before it is accepted.
                TextField("Rule", text: $text, axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...8)
                    .font(.system(size: 12.5))
                    .accessibilityLabel("Proposed rule")
                    .accessibilityValue(text)
            } else {
                Text(need.text ?? "")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tx)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let why = need.why {
                    Text("“\(why)”")
                        .font(.system(size: 11.5, design: .serif))
                        .foregroundStyle(Theme.tx2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                // Whom it would bind, and while it is being edited, what it will bind instead.
                if editing {
                    BindsMenu(binds: binds) { binds = $0 }
                } else {
                    Tag("Would bind: \(need.binds?.title ?? "every agent")")
                }
                Spacer(minLength: 8)
                if editing {
                    Button("Save", action: acceptEdited)
                        .buttonStyle(.piPrimary)
                        .disabled(answering || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { editing = false }
                        .buttonStyle(.piGhost)
                        .disabled(answering)
                } else {
                    Button("Accept", action: accept)
                        .buttonStyle(.piSecondary)
                        .disabled(answering)
                    Button("Edit…", action: startEditing)
                        .buttonStyle(.piSecondary)
                        .disabled(answering)
                    Button("Refuse", action: refuse)
                        .buttonStyle(.piGhost)
                        .disabled(answering)
                }
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.bad)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        // A card of its own, a shade above the list it sits over, as the board's other cards are.
        .panel(radius: 10, fill: Theme.card, border: Theme.line2)
    }

    private func startEditing() {
        text = need.text ?? ""
        binds = need.binds ?? .everyone
        editing = true
    }

    /// Accepts, with the text and the binding changed or not: one answer, as the contract reads it.
    private func acceptEdited() {
        answer(["kind": "rule", "accept": true, "text": text.trimmingCharacters(in: .whitespacesAndNewlines), "binds": binds.rawValue])
        editing = false
    }

    private func accept() {
        answer(["kind": "rule", "accept": true])
    }

    private func refuse() {
        answer(["kind": "rule", "accept": false])
    }

    private func answer(_ answer: [String: Any]) {
        answering = true
        Task {
            do {
                try await engine.call("needs.answer", ["id": need.id, "answer": answer])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            answering = false
        }
    }
}
