
import PiModels
import SwiftUI

/// The Rules page (the Mac's Rules tab, app/Sources/pi2/ProjectRulesTab.swift): a rule an agent proposes, to accept,
/// change or refuse; what the rules cost; the rules in their order, each to change, move or remove; and the field that
/// adds one. Each change reaches the engine at once, and is in the next prompt of every agent the rule binds.
struct BoardRulesPage: View {
    let project: ProjectRow
    let data: BoardData

    @Environment(AppSession.self) private var session
    @State private var newText = ""
    @State private var newBinds: ProjectRule.Binds = .everyone
    @State private var adding = false
    @State private var addProblem: String?
    @State private var listProblem: String?
    /// The rule being changed in the sheet, and the proposal being accepted with changes.
    @State private var editing: ProjectRule?
    @State private var amending: NeedItem?
    @State private var removing: ProjectRule?

    var body: some View {
        let rules = data.rules(project.id)
        let proposals = data.proposals(project.id)
        List {
            if let sample = data.sample { BoardSampleNote(what: sample) }
            if !proposals.isEmpty {
                Section("Proposed") {
                    ForEach(proposals) { need in
                        BoardRuleProposal(need: need, amend: { amending = need })
                    }
                }
            }
            if rules.isEmpty {
                if proposals.isEmpty { notWrittenYet }
            } else {
                Section {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        ruleRow(rule, number: index + 1)
                    }
                    .onMove { from, to in move(rules, from: from, to: to) }
                } header: {
                    Text("Rules")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let listProblem { BoardProblem(listProblem) }
                        if let cost = BoardData.ruleCost(project.ruleTokens) { Text(cost) }
                    }
                }
            }
            addSection
        }
        .listStyle(.insetGrouped)
        .toolbar {
            if rules.count > 1 { EditButton() }
        }
        .sheet(item: $editing) { rule in
            BoardRuleEditor(title: "Change Rule", text: rule.text, binds: rule.binds, action: "Save") { text, binds in
                await change(rule, text: text, binds: binds)
            }
        }
        .sheet(item: $amending) { need in
            BoardRuleEditor(title: "Accept with Changes", text: need.text ?? "", binds: need.binds ?? .everyone, action: "Accept",
                            note: "Proposed by \(need.agentName ?? "an agent"). Accepting with the text or whom it binds changed is your answer.") { text, binds in
                await BoardRequests.answerProposal(session.engine, need: need.id, accept: true, text: text, binds: binds)
            }
        }
        .confirmationDialog("Remove this rule?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { rule in
            Button("Remove", role: .destructive) { remove(rule) }
        } message: { rule in
            Text("“\(rule.text)” stops binding \(rule.binds == .everyone ? "every agent" : "the orchestrator") from its next request.")
        }
        #if DEBUG
        .task { await BoardDebugAct.rules(self, rules: rules) }
        #endif
    }

    private var notWrittenYet: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("No rules yet.", systemImage: "text.badge.checkmark").font(.headline)
                Text("A rule is a line your project keeps to. pi² sends it word for word, in full, to the orchestrator or to every agent at each of their requests; it is never summarised, so it holds however long the conversation runs.")
                Text("Write one below, or ask the orchestrator to keep something as a rule: it will propose one, and you accept, change or refuse it here.")
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
    }

    private func ruleRow(_ rule: ProjectRule, number: Int) -> some View {
        Button {
            editing = rule
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.text).foregroundStyle(.primary)
                    BoardTag(rule.binds.title, color: rule.binds == .orchestrator ? .pi2Accent : .secondary)
                    Text(data.origin(rule)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        // The row's words in the text's colours, not the tint a button takes.
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rule \(number): \(rule.text)")
        .accessibilityValue("Binds \(rule.binds == .everyone ? "every agent" : "the orchestrator")")
        .accessibilityHint("\(data.origin(rule)). Opens it to change.")
        .swipeActions {
            Button("Remove", role: .destructive) { removing = rule }
        }
        .contextMenu {
            Button("Change…", systemImage: "pencil") { editing = rule }
            Menu("Binds") {
                ForEach(ProjectRule.Binds.allCases) { binds in
                    Button {
                        Task { listProblem = await change(rule, text: rule.text, binds: binds) }
                    } label: {
                        if binds == rule.binds { Label(binds.title, systemImage: "checkmark") } else { Text(binds.title) }
                    }
                }
            }
            Button("Remove…", systemImage: "trash", role: .destructive) { removing = rule }
        }
        .accessibilityAction(named: "Remove") { removing = rule }
    }

    private var addSection: some View {
        Section {
            TextField("New rule", text: $newText, prompt: Text("Add a rule…"), axis: .vertical)
                .lineLimit(1...6)
            Picker("Binds", selection: $newBinds) {
                ForEach(ProjectRule.Binds.allCases) { Text($0.title).tag($0) }
            }
            Button("Add Rule") { add() }
                .disabled(adding || newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !data.connected)
        } header: {
            Text("Add a rule")
        } footer: {
            if let addProblem { BoardProblem(addProblem) }
        }
    }

    private func add() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !adding else { return }
        adding = true
        let engine = session.engine
        let binds = newBinds
        Task {
            if let problem = await BoardRequests.addRule(engine, project: project.id, text: text, binds: binds) {
                addProblem = "The rule was not added: \(problem)"
            } else {
                addProblem = nil
                newText = ""
            }
            adding = false
        }
    }

    /// Sends what changed of a rule, its text and whom it binds, each as the Mac sends it; answers the engine's words.
    @discardableResult
    private func change(_ rule: ProjectRule, text: String, binds: ProjectRule.Binds) async -> String? {
        let engine = session.engine
        if text != rule.text, let problem = await BoardRequests.editRule(engine, project: project.id, rule: rule.id, text: text) {
            return "The rule was not changed: \(problem)"
        }
        if binds != rule.binds, let problem = await BoardRequests.bindRule(engine, project: project.id, rule: rule.id, binds: binds) {
            return "Whom the rule binds was not changed: \(problem)"
        }
        return nil
    }

    private func move(_ rules: [ProjectRule], from: IndexSet, to: Int) {
        guard let index = from.first else { return }
        // `to` is the place counted from 0 the rule ends at (docs/projects.md, 4.2).
        let place = index < to ? to - 1 : to
        guard place != index else { return }
        let engine = session.engine
        boardSend($listProblem) {
            await BoardRequests.moveRule(engine, project: project.id, rule: rules[index].id, to: place).map { "The rule was not moved: \($0)" }
        }
    }

    func remove(_ rule: ProjectRule) {
        removing = nil
        let engine = session.engine
        boardSend($listProblem) { await BoardRequests.removeRule(engine, project: project.id, rule: rule.id).map { "The rule was not removed: \($0)" } }
    }

    #if DEBUG
    /// For `BoardDebugAct`: what a tap would do.
    func debugAdd(_ text: String) { newText = text; add() }
    func debugEdit(_ rule: ProjectRule) { editing = rule }
    #endif
}

/// A rule an agent proposes (docs/projects.md, 3.9): who proposes it, the text, why, whom it would bind, and the answer,
/// in the Mac's words and with its buttons, so that it is answered the same in the Rules page as under Needs you.
struct BoardRuleProposal: View {
    let need: NeedItem
    let amend: () -> Void

    @Environment(AppSession.self) private var session
    @State private var answering = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let when = Text(Date(timeIntervalSince1970: need.createdAt / 1000).formatted(date: .abbreviated, time: .omitted))
                .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Proposed by \(need.agentName ?? "an agent")").font(.subheadline.weight(.semibold)).fixedSize()
                    Spacer(minLength: 8)
                    when.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Proposed by \(need.agentName ?? "an agent")").font(.subheadline.weight(.semibold))
                    when
                }
            }
            Text(need.text ?? "")
            if let why = need.why {
                Text("“\(why)”").font(.subheadline).italic().foregroundStyle(.secondary)
            }
            BoardTag("Would bind: \(need.binds?.title ?? "Every agent")")
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading) { buttons }
            }
            .disabled(answering)
            if let problem { BoardProblem(problem) }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Accept") { answer(true) }.buttonStyle(.borderedProminent)
        Button("Edit…") { amend() }.buttonStyle(.bordered)
        Button("Refuse") { answer(false) }.buttonStyle(.bordered)
    }

    private func answer(_ accept: Bool) {
        answering = true
        let engine = session.engine
        let id = need.id
        Task {
            problem = await BoardRequests.answerProposal(engine, need: id, accept: accept).map { "Not answered: \($0)" }
            answering = false
        }
    }
}

/// A rule's text and whom it binds, changed in a sheet: a rule being changed, or a proposal accepted with changes.
struct BoardRuleEditor: View {
    let title: String
    let action: String
    let note: String?
    /// Sends the change; answers the engine's words when it was not taken.
    let send: (String, ProjectRule.Binds) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var binds: ProjectRule.Binds
    @State private var sending = false
    @State private var problem: String?

    init(title: String, text: String, binds: ProjectRule.Binds, action: String, note: String? = nil,
         send: @escaping (String, ProjectRule.Binds) async -> String?) {
        self.title = title
        self.action = action
        self.note = note
        self.send = send
        _text = State(initialValue: text)
        _binds = State(initialValue: binds)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Rule", text: $text, axis: .vertical).lineLimit(2...12)
                    Picker("Binds", selection: $binds) {
                        ForEach(ProjectRule.Binds.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let problem { BoardProblem(problem) }
                        if let note { Text(note) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action) {
                        sending = true
                        Task {
                            problem = await send(text.trimmingCharacters(in: .whitespacesAndNewlines), binds)
                            sending = false
                            if problem == nil { dismiss() }
                        }
                    }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
