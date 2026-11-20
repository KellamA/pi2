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
    let updatedAt: Double

    private enum CodingKeys: String, CodingKey { case id, text, binds, addedBy, createdAt, updatedAt }
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
        updatedAt = try values.decode(Double.self, forKey: .updatedAt)
    }
}

struct ProjectRulesEvent: Decodable {
    let projects: [String: [ProjectRule]]
}

/// A proposed rule waiting under Needs you (docs/projects.md, 3.9), as the `needs` event sends it, with only what its
/// card reads. Every kind of need shares the base fields, so the whole array decodes whatever kinds are in it.
struct RuleNeed: Decodable, Equatable, Identifiable {
    let id: String
    let projectId: String?
    let kind: String
    /// The agent that proposes it, and its name.
    let agentId: String?
    let agentName: String?
    /// Milliseconds since 1970.
    let createdAt: Double
    let text: String?
    let binds: ProjectRule.Binds?
    let why: String?
}

struct RuleNeedsEvent: Decodable {
    let items: [RuleNeed]
}

/// The Rules tab of the board (#476): a proposal above, what the rules cost, the rules themselves, and the field that
/// adds one. Changes reach the engine at once; each of them is in the next prompt of every agent the rule binds.
struct ProjectRulesTab: View {
    let model: AppModel
    let project: ProjectRow

    private var engine: EngineClient { model.engine }
    private var rules: [ProjectRule] { engine.projectRules[project.id] ?? [] }
    private var proposals: [RuleNeed] { engine.ruleNeeds[project.id] ?? [] }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(proposals) { need in
                    RuleProposalCard(engine: engine, projectId: project.id, need: need)
                }
                if !rules.isEmpty {
                    RuleCost(tokens: project.ruleTokens)
                }
                if rules.isEmpty {
                    RulesNotWrittenYet()
                } else {
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
                AddRuleField(engine: engine, projectId: project.id)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        var text = "About \(tokens.orchestrator) tokens of every request to the orchestrator, \(tokens.agents) to each other agent of the project."
        text += " The rules are read whole again at every request, so the shorter the list, the less every turn costs."
        return text
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
        VStack(alignment: .leading, spacing: 6) {
            Text("No rules yet.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.tx)
            Text(
                "A rule is a line your project keeps to. pi² sends it word for word, in full, to the orchestrator or to every agent at each of their requests; it is never summarised, so it holds however long the conversation runs."
            )
            .font(.system(size: 12))
            .foregroundStyle(Theme.tx2)
            Text("Write one below, or ask the orchestrator in the conversation to keep something as a rule: it will propose one, and you accept, change or refuse it here.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tx2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number).")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.tx3)
                    .frame(minWidth: 16, alignment: .trailing)
                TextField("Rule", text: $text, axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...12)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .layoutPriority(1)
                    .accessibilityLabel("Rule \(number)")
                    .accessibilityValue(text)
                    .sendsOnReturn { commit() }
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
            Text(origin)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tx3)
            if let problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.bad)
                    .textSelection(.enabled)
            }
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
            ForEach(ProjectRule.Binds.allCases) { value in
                Button(value == binds ? "✓ \(value.title)" : value.title) { choose(value) }
            }
        } label: {
            Text(binds.title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .background(Theme.card2, in: .rect(cornerRadius: 5))
        .contentShape(.rect)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .tint(Theme.tx2)
        .fixedSize()
        .padding(.vertical, 1)
        .accessibilityLabel("Whom rule binds")
        .accessibilityValue(binds.title)
        .help("Whom this rule is sent to at every request")
    }
}

// MARK: - Adding a rule

/// The field that adds a rule, with whom it binds. An engine's refusal, a rule too long or the fiftieth one, shows
/// under the field in the engine's words.
private struct AddRuleField: View {
    let engine: EngineClient
    let projectId: String

    @State private var text = ""
    @State private var binds: ProjectRule.Binds = .everyone
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var words: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Add a rule", text: $text, prompt: Text("Add a rule…"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...4)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .accessibilityLabel("New rule")
                    .sendsOnReturn { add() }
                BindsMenu(binds: binds) { binds = $0 }
                Button("Add", action: add)
                    .buttonStyle(.piPrimary)
                    .disabled(words.isEmpty)
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.bad)
                    .textSelection(.enabled)
            }
        }
    }

    private func add() {
        guard !words.isEmpty else { return }
        let sent = text
        Task {
            do {
                try await engine.call("projects.rules.add", ["projectId": projectId, "text": sent, "binds": binds.rawValue])
                text = ""
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

// MARK: - A proposed rule

/// A rule an agent proposes (docs/projects.md, 3.9): who proposes it, the text, whom it would bind, and the answer.
/// Accepting with the text or the binding changed is an answer in its own right, so Edit… answers, too.
private struct RuleProposalCard: View {
    let engine: EngineClient
    let projectId: String
    let need: RuleNeed

    @State private var editing = false
    @State private var text = ""
    @State private var binds: ProjectRule.Binds = .everyone
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
                TextField("Rule", text: $text, axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...6)
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
                Tag(editing ? binds.title : "Would bind: \(need.binds?.title ?? "every agent")")
                Spacer(minLength: 8)
                if editing {
                    Button("Save", action: acceptEdited)
                        .buttonStyle(.piPrimary)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { editing = false }
                        .buttonStyle(.piGhost)
                } else {
                    Button("Accept", action: accept)
                        .buttonStyle(.piSecondary)
                    Button("Edit…", action: startEditing)
                        .buttonStyle(.piSecondary)
                    Button("Refuse", action: refuse)
                        .buttonStyle(.piGhost)
                }
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.bad)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .panel(radius: 10)
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
        Task {
            do {
                try await engine.call("needs.answer", ["id": need.id, "answer": answer])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
