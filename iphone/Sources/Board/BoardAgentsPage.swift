
import PiModels
import SwiftUI

/// The switches of what the orchestrator may do without asking (docs/projects.md, 8.1), in the Mac's words
/// (`ProjectSwitch` in app/Sources/pi2/ProjectAgentsTab.swift). The names are the engine's, as `projects.set` takes them.
struct BoardSwitch: Identifiable, Equatable {
    let name: String
    let title: String
    let allows: String
    /// What turning it on is confirmed with, when it does not read as the plain line.
    let confirm: String?
    var id: String { name }

    static let all: [BoardSwitch] = [
        BoardSwitch(name: "startAgents", title: "Start agents", allows: "Hand work to the project's agents, and start them, without asking you.", confirm: nil),
        BoardSwitch(name: "fileWork", title: "File work", allows: "Add work to the project's list without asking you.", confirm: nil),
        BoardSwitch(name: "closeWork", title: "Close work", allows: "Mark work finished or closed without asking you.", confirm: nil),
        BoardSwitch(name: "makeAgents", title: "Make and change agents", allows: "Make, change and remove the project's agents, and update them from their templates, without asking you.", confirm: nil),
        BoardSwitch(name: "addRules", title: "Add rules", allows: "Add the rules you dictate to the project's rules without asking you.", confirm: nil),
        BoardSwitch(name: "merge", title: "Merge pull requests", allows: "Merge a pull request through work without asking you.", confirm: nil),
        BoardSwitch(name: "release", title: "Release", allows: "Nothing pi² does is held back by this switch: it tells the orchestrator to ask you before releasing anything.", confirm: "release what it has made without asking you; nothing pi² does is held back by this switch"),
        BoardSwitch(name: "passLimits", title: "Go past limits", allows: "Start work past the project's limits without asking you.", confirm: nil),
    ]

    /// What the person is asked when they turn it on: what the orchestrator may then do without asking them.
    var confirmation: String {
        let line = confirm ?? allows
        return "The orchestrator may then \(line.prefix(1).lowercased() + line.dropFirst())"
    }
}

/// The Agents page: the orchestrator and what it may do without asking, the project's other agents, those removed
/// through a tool, and the way to the templates (the Mac's Agents tab, as grouped settings).
struct BoardAgentsPage: View {
    let project: ProjectRow
    let data: BoardData

    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    /// The switch the person turned on, while the confirmation shows.
    @State private var confirming: BoardSwitch?
    @State private var switchProblem: String?
    /// The agent the person asked to make the orchestrator, while the confirmation shows.
    @State private var promoting: AgentProfile?
    @State private var problem: String?
    @State private var adding = false

    private var archived: Bool { project.archivedAt != nil }

    var body: some View {
        let agents = data.projectAgents(project)
        let removed = data.removedAgents(project)
        List {
            if let sample = data.sample { BoardSampleNote(what: sample) }
            Section("Orchestrator") {
                orchestratorRow
            }
            Section {
                if agents.isEmpty {
                    Text("No other agents yet. Make one, or copy a template, with the + button.")
                        .foregroundStyle(.secondary)
                }
                ForEach(agents) { agent in
                    agentRow(agent)
                }
            } header: {
                Text("Agents")
            } footer: {
                if let problem { BoardProblem(problem) }
            }
            if !removed.isEmpty {
                Section {
                    ForEach(removed) { agent in removedRow(agent) }
                } header: {
                    Text("Removed")
                } footer: {
                    Text("An agent removed through a tool is kept whole, and its conversations keep the setup they have. Only you can delete one for good, from its page.")
                }
            }
            // On a phone the agents come first: the switches are a long list, and the Mac's card puts them beside them.
            switches
            Section {
                BoardLinkRow(route: .templates) {
                    Label("Templates", systemImage: "doc.on.doc")
                }
            } footer: {
                Text("Agents of a project are made from templates: agents kept outside any project. Changing a copy here changes this project only.")
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { addMenu }
        }
        .confirmationDialog(confirming.map { "Turn on \($0.title)?" } ?? "", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }
        ), titleVisibility: .visible) {
            if let each = confirming {
                Button("Turn On") { set(each, on: true) }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let each = confirming { Text(each.confirmation + "\n\nYour Mac is told of the change.") }
        }
        .alert(promoting.map { "Make \($0.name) the orchestrator of \(project.name)?" } ?? "", isPresented: Binding(
            get: { promoting != nil }, set: { if !$0 { promoting = nil } }
        )) {
            if let agent = promoting {
                Button("Make Orchestrator") { promote(agent) }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let agent = promoting { Text(Self.promotion(agent, previous: data.agent(project.orchestratorId))) }
        }
        #if DEBUG
        .task { await BoardDebugAct.agents(self) }
        #endif
    }

    // MARK: - The orchestrator

    @ViewBuilder
    private var orchestratorRow: some View {
        let orchestrator = data.agent(project.orchestratorId)
        BoardLinkRow(route: .agent(project.orchestratorId, project: project.id)) {
            HStack(spacing: 12) {
                if data.working(project.orchestratorId, in: project.id) {
                    ProgressView().frame(width: 36)
                } else {
                    AgentMark(agent: orchestrator, size: 36)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(orchestrator?.name ?? "Orchestrator").font(.headline)
                    BoardAgentTags(agent: orchestrator, extra: ["Orchestrator"])
                    Text(data.shortModelName(orchestrator?.model).boardOr("App default"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHint("Opens the orchestrator's settings")
    }

    @ViewBuilder
    private var switches: some View {
        Section {
            ForEach(BoardSwitch.all) { each in
                Toggle(isOn: Binding(
                    get: { project.allows(each.name) },
                    set: { on in if on { confirming = each } else { set(each, on: false) } }
                )) {
                    Text(each.title)
                    Text(each.allows)
                }
                .disabled(!data.connected)
            }
        } header: {
            Text("What the orchestrator may do without asking")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let switchProblem { BoardProblem(switchProblem) }
                Text("A switch that is off makes each thing it governs wait for you to allow it under Needs you. Your Mac is told when a switch is turned on from this phone.")
            }
        }
    }

    private func set(_ each: BoardSwitch, on: Bool) {
        confirming = nil
        let engine = session.engine
        boardSend($switchProblem) {
            await BoardRequests.setSwitch(engine, project: project.id, name: each.name, on: on)
                .map { "\(each.title) was not turned \(on ? "on" : "off"): \($0)" }
        }
    }

    // MARK: - The other agents

    private func agentRow(_ agent: AgentProfile) -> some View {
        BoardLinkRow(route: .agent(agent.id, project: project.id)) {
            HStack(spacing: 12) {
                if data.working(agent.id, in: project.id) {
                    ProgressView().frame(width: 28)
                } else {
                    AgentMark(agent: agent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name).font(.body.weight(.semibold))
                    BoardAgentTags(agent: agent, extra: [data.madeBy(agent, in: project), data.working(agent.id, in: project.id) ? "working" : nil,
                                                         data.templateChanged(agent) ? "template changed" : nil].compactMap { $0 })
                    let model = data.shortModelName(agent.model).boardOr("App default")
                    Text(agent.description.isEmpty ? model : "\(model) · \(agent.description)")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .contextMenu { agentActions(agent) }
        .swipeActions(edge: .trailing) {
            Button("New Conversation", systemImage: "plus.bubble") { startConversation(agent) }
                .tint(.pi2Accent)
                .disabled(archived || !data.connected)
        }
        .accessibilityHint("Opens \(agent.name)'s settings")
        .accessibilityActions { agentActions(agent) }
    }

    @ViewBuilder
    private func agentActions(_ agent: AgentProfile) -> some View {
        Button("New Conversation", systemImage: "plus.bubble") { startConversation(agent) }
            .disabled(archived || !data.connected)
        Button("Make Orchestrator…", systemImage: "crown") { promoting = agent }
            .disabled(archived || !data.connected)
    }

    private func removedRow(_ agent: AgentProfile) -> some View {
        HStack(spacing: 12) {
            AgentMark(agent: agent).opacity(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).foregroundStyle(.secondary)
                Text("Removed \(Date(timeIntervalSince1970: (agent.removedAt ?? 0) / 1000).formatted(.relative(presentation: .named))); nothing runs as it until it is restored.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Restore") {
                let engine = session.engine
                boardSend($problem) { await BoardRequests.restore(engine, agent: agent.id).map { "\(agent.name) was not restored: \($0)" } }
            }
            .buttonStyle(.bordered)
            .disabled(!data.connected)
            .accessibilityHint("Puts \(agent.name) back as it was, for the project's conversations")
        }
    }

    // MARK: - Adding

    private var addMenu: some View {
        Menu {
            Button("New Agent", systemImage: "person.badge.plus") { makeAgent() }
            Menu("From a Template", systemImage: "doc.on.doc") {
                ForEach(data.templates) { template in
                    Button(template.name) { copy(template) }
                }
            }
            .disabled(data.templates.isEmpty)
        } label: {
            Label("Add an Agent", systemImage: "plus")
        }
        .disabled(archived || !data.connected || adding)
    }

    private func makeAgent() {
        let name = BoardAgentDraft.uniqueName(among: data.allAgents.filter { $0.projectId == project.id })
        let engine = session.engine
        made { await BoardRequests.newAgent(engine, project: project.id, named: name) }
    }

    private func copy(_ template: AgentProfile) {
        let engine = session.engine
        made { await BoardRequests.copyTemplate(engine, project: project.id, template: template.id) }
    }

    /// Opens the page of the agent the request made, as the Mac's tab does, or says why none was made.
    private func made(_ request: @escaping @MainActor () async -> Result<String, BoardFailure>) {
        adding = true
        Task {
            switch await request() {
            case .success(let id):
                problem = nil
                openRoute(.agent(id, project: project.id))
            case .failure(let failure):
                problem = "No agent was made: \(failure.message)"
            }
            adding = false
        }
    }

    func startConversation(_ agent: AgentProfile) {
        let engine = session.engine
        Task {
            switch await BoardRequests.newConversation(engine, agent: agent.id) {
            case .success(let id):
                problem = nil
                openRoute(.conversation(id))
            case .failure(let failure):
                problem = "No conversation with \(agent.name) was started: \(failure.message)"
            }
        }
    }

    private func promote(_ agent: AgentProfile) {
        promoting = nil
        let engine = session.engine
        boardSend($problem) {
            await BoardRequests.makeOrchestrator(engine, project: project.id, agent: agent.id).map { "\(agent.name) was not made the orchestrator: \($0)" }
        }
    }

    /// What Make Orchestrator's confirmation says (docs/projects.md, 6.5), in the Mac's words (`MakeOrchestrator.words`).
    static func promotion(_ agent: AgentProfile, previous: AgentProfile?) -> String {
        let before = previous?.name ?? "the orchestrator"
        return "\(agent.name) takes over from \(before): it hands out the project’s work, with the orchestrator’s tools and what the orchestrator may do without asking. A new conversation with \(agent.name) begins, started fresh with the project as it stands. Work handed out and not yet reported goes on, and reports to the new one.\n\nThe present conversation with \(before) is kept and can be read, but takes no more messages. \(before.prefix(1).uppercased() + before.dropFirst()) stays in the project as one of its agents."
    }

    #if DEBUG
    /// For `BoardDebugAct`: what a tap would do.
    func debugAsk(_ name: String) { confirming = BoardSwitch.all.first { $0.name == name } }
    func debugAdd() { makeAgent() }
    #endif
}

/// The words beside an agent's name: what the caller adds ("Orchestrator", "working"), and "allows everything" in red
/// when nothing it does is asked about.
struct BoardAgentTags: View {
    let agent: AgentProfile?
    var extra: [String] = []

    var body: some View {
        let everything = agent?.allowEverything == true
        if everything || !extra.isEmpty {
            // Wraps at the largest text sizes rather than cutting a word off.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { tags(everything) }
                VStack(alignment: .leading, spacing: 3) { tags(everything) }
            }
        }
    }

    @ViewBuilder
    private func tags(_ everything: Bool) -> some View {
        ForEach(extra, id: \.self) { BoardTag($0, color: .pi2Accent) }
        if everything { BoardTag("allows everything", color: .red) }
    }
}

extension String {
    /// The text, or `other` when it is empty.
    func boardOr(_ other: String) -> String { isEmpty ? other : self }
}
