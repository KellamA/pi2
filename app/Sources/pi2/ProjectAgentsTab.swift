import MenuKit
import SwiftUI

// The board's Agents tab (#475; docs/design/projects.md, Agents and templates): the orchestrator's card with what it
// may do without asking, the project's other agents, and the templates they are made from. The agent requests are the
// contract's (docs/projects.md, 3.3 and 4.2); a switch of 8.1 the person turns on asks them first, in the app, since it
// widens what the orchestrator may do without asking (7.1). An agent's own page is today's (AgentViews.swift), shown in
// the tab with the way back; a template is edited on today's page too, never here.

/// The switches of 8.1: what each one lets the orchestrator do without asking, and what it is called here. The names
/// are the engine's, as `projects.set` takes them.
private struct ProjectSwitch {
    let name: String
    let title: String
    let allows: String
    /// What turning it on is confirmed with, when it does not read as the plain line. Nil: the line itself.
    let confirm: String?

    static let all: [ProjectSwitch] = [
        ProjectSwitch(name: "startAgents", title: "Start agents", allows: "Hand work to the project's agents, and start them, without asking you.", confirm: nil),
        ProjectSwitch(name: "fileWork", title: "File work", allows: "Add work to the project's list without asking you.", confirm: nil),
        ProjectSwitch(name: "closeWork", title: "Close work", allows: "Mark work finished or closed without asking you.", confirm: nil),
        ProjectSwitch(name: "makeAgents", title: "Make and change agents", allows: "Make, change and remove the project's agents, and update them from their templates, without asking you.", confirm: nil),
        ProjectSwitch(name: "addRules", title: "Add rules", allows: "Add the rules you dictate to the project's rules without asking you.", confirm: nil),
        ProjectSwitch(name: "merge", title: "Merge pull requests", allows: "Merge a pull request through work without asking you.", confirm: nil),
        ProjectSwitch(name: "release", title: "Release", allows: "Nothing pi² does is held back by this switch: it tells the orchestrator to ask you before releasing anything.", confirm: "release what it has made without asking you; nothing pi² does is held back by this switch"),
        ProjectSwitch(name: "passLimits", title: "Go past limits", allows: "Start work past the project's limits without asking you.", confirm: nil),
    ]
}

/// The board's Agents tab: the orchestrator at the top, then the project's other agents, then those removed through a
/// tool, each to put back. One agent's own page can show in place of all this, with the way back.
struct ProjectAgentsTab: View {
    let model: AppModel
    let project: ProjectRow
    /// The agent whose own page shows in the tab, or nil for the list. The project's orchestrator among them.
    @State private var openAgent: String?
    @State private var updating: AgentProfile?

    private var engine: EngineClient { model.engine }

    var body: some View {
        if let id = openAgent, engine.agent(id) != nil {
            AgentPageInTab(model: model, agentID: id) { openAgent = nil }
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OrchestratorCard(model: model, project: project, openPage: { openAgent = project.orchestratorId })
                agentsList
                if !removed.isEmpty { removedList }
                templatesNote
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $updating) { agent in
            if let mark = agent.template, let template = engine.agent(mark.id), template.projectId == nil {
                UpdateFromTemplateSheet(engine: engine, agent: agent, template: template)
            } else {
                // The template went between the row being drawn and the click: say so, so the sheet is not a blank one.
                VStack(alignment: .leading, spacing: 12) {
                    Text("Update \(agent.name) from its template?")
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.tx)
                    Text("The template this agent was made from has been deleted, so there is nothing to bring it up to date with.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer(minLength: 0)
                        Button("Done") { updating = nil }
                            .buttonStyle(.piPrimary)
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(16).frame(width: 440)
            }
        }
    }

    /// The project's other agents, not removed, in the order they were made.
    private var agents: [AgentProfile] {
        engine.allAgents
            .filter { $0.projectId == project.id && $0.id != project.orchestratorId && $0.removedAt == nil }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// Agents removed through a tool (docs/projects.md, 3.3): kept whole, so Restore puts them back as they were.
    private var removed: [AgentProfile] {
        engine.allAgents
            .filter { $0.projectId == project.id && $0.removedAt != nil }
            .sorted { ($0.removedAt ?? 0, $0.id) < ($1.removedAt ?? 0, $1.id) }
    }

    @ViewBuilder
    private var agentsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Agents").sectionLabel()
                Spacer(minLength: 8)
                Button("New Agent", systemImage: "plus") { makeAgent() }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .disabled(engine.status != .connected || project.archivedAt != nil)
                    .help("Make a new agent of this project, set up by hand")
                Menu {
                    // Each template's whole name and face, as the Give to menu shows the project's agents (#597).
                    MenuChoices(engine.agents.map(MenuChoice.init(agent:))) { choice in
                        if let template = engine.agents.first(where: { $0.id == choice.id }) { copyTemplate(template) }
                    }
                } label: {
                    Label("From a Template", systemImage: "doc.on.doc")
                }
                .buttonStyle(.piSecondary)
                .controlSize(.small)
                .disabled(engine.agents.isEmpty || engine.status != .connected || project.archivedAt != nil)
                .help(engine.agents.isEmpty ? "There are no templates yet. Make one from an agent with no project." : "Copy a template into this project")
            }
            if agents.isEmpty {
                Text("No other agents yet. Make one by hand, or copy a template.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.tx2)
            }
            ForEach(agents) { agent in
                AgentListRow(model: model, project: project, agent: agent, update: { updating = agent }, open: { openAgent = agent.id })
            }
        }
    }

    @ViewBuilder
    private var removedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Removed").sectionLabel()
            ForEach(removed) { agent in
                HStack(spacing: 10) {
                    AgentAvatar(agent: agent, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.tx2)
                        Text("Removed by the orchestrator \(ArchiveRow.ago(agent.removedAt ?? 0)); nothing runs as it until it is restored.")
                            .font(.caption).foregroundStyle(Theme.tx3).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Restore") { engine.perform("agents.restore", ["id": agent.id]) }
                        .buttonStyle(.piSecondary)
                        .controlSize(.small)
                        .disabled(engine.status != .connected)
                        .help("Put \(agent.name) back as it was, for the project's conversations")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .panel()
            }
            Text("An agent removed through a tool is kept whole, and its conversations keep the setup they have. Only you can delete one for good, from its page.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tx3)
        }
    }

    /// The way to the templates, which are managed with today's agent pages, not here (docs/projects.md, 3.3).
    private var templatesNote: some View {
        // In a panel too narrow for one line the button goes below the sentence, rather than squeezing it into a column.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                noteIcon
                noteText
                Spacer(minLength: 8)
                manageTemplatesButton
            }
            .frame(minWidth: 620)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    noteIcon
                    noteText
                }
                HStack {
                    Spacer(minLength: 0)
                    manageTemplatesButton
                }
            }
        }
        .padding(12).panel()
    }

    private var noteIcon: some View {
        Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(Theme.tx3)
    }

    private var noteText: some View {
        Text("Agents of a project are made from templates: agents kept outside any project. Changing a copy here changes this project only.")
            .font(.system(size: 11.5)).foregroundStyle(Theme.tx3).fixedSize(horizontal: false, vertical: true)
    }

    private var manageTemplatesButton: some View {
        Button("Manage Templates…") { manageTemplates() }
            .buttonStyle(.piGhost)
            .controlSize(.small)
            .disabled(engine.status != .connected)
            .help("Open the templates, which are edited as agents are today")
    }

    /// Makes an agent of the project by hand, and opens its page in the tab.
    private func makeAgent() {
        var name = "New Agent"
        var n = 2
        while engine.allAgents.contains(where: { $0.projectId == project.id && $0.name.lowercased() == name.lowercased() }) {
            name = "New Agent \(n)"
            n += 1
        }
        addAgent(["name": name, "description": "", "access": "none"])
    }

    /// Copies a template into the project, and opens the copy's page in the tab.
    private func copyTemplate(_ template: AgentProfile) {
        Task {
            do {
                let result = try await engine.call("projects.addAgent", ["projectId": project.id, "template": template.id])
                if let id = result["id"]?.stringValue { openAgent = id }
            } catch { engine.lastError = error.localizedDescription }
        }
    }

    private func addAgent(_ agent: [String: Any]) {
        Task {
            do {
                let result = try await engine.call("projects.addAgent", ["projectId": project.id, "agent": agent])
                if let id = result["id"]?.stringValue { openAgent = id }
            } catch { engine.lastError = error.localizedDescription }
        }
    }

    /// Opens the templates: the sidebar's list of them unfolds, and the first one's page opens, unless a template's page
    /// is already on screen, which is left as it is (#553). With no template yet, the first one is made, as the sidebar's
    /// own button makes it.
    private func manageTemplates() {
        model.projectsSidebar.templatesShown = true
        if case .agent(let id)? = model.selection, engine.agent(id)?.projectId == nil { return }
        if let first = engine.agents.first {
            model.selection = .agent(first.id)
        } else {
            model.newAgent()
        }
    }
}

// MARK: - The orchestrator

/// The orchestrator's card: who it is, the way to its own page, and what it may do without asking. Turning a switch on
/// widens what the orchestrator may do, so it is confirmed first; turning one off asks nothing (docs/projects.md, 8.1).
private struct OrchestratorCard: View {
    let model: AppModel
    let project: ProjectRow
    let openPage: () -> Void
    @State private var confirming: ProjectSwitch?
    @State private var problem: String?

    private var engine: EngineClient { model.engine }
    private var orchestrator: AgentProfile? { engine.agent(project.orchestratorId) }
    private var working: Bool {
        engine.activity.contains { $0.projectId == project.id && $0.runsAs == project.orchestratorId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if working { Spinner().frame(width: 36) } else { AgentAvatar(agent: orchestrator, size: 36) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(orchestrator?.name ?? "Orchestrator")
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.tx)
                    HStack(spacing: 6) {
                        Tag("Orchestrator", .acc).fixedSize()
                        Text(engine.shortModelName(orchestrator?.model)).font(.caption).foregroundStyle(Theme.tx3).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button("Open Page…") { openPage() }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .help("The orchestrator's own settings, as any agent's page shows them")
            }
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 2) {
                Text("What it may do without asking").sectionLabel()
                ForEach(ProjectSwitch.all, id: \.name) { each in
                    Toggle(isOn: Binding(
                        get: { project.allows(each.name) },
                        set: { on in
                            if on { confirming = each } else { set(each, on: false) }
                        }
                    )) {
                        Text(each.title)
                        Text(each.allows)
                    }
                    .controlSize(.small)
                }
                Text("A switch that is off makes each thing it governs wait for you to allow it under Needs you. What waits is answered there, and the change shows in the conversation as a line with Undo.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tx3).fixedSize(horizontal: false, vertical: true)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(Theme.bad) }
        }
        .padding(14).panel(radius: 12, border: Theme.line2)
        .confirmationDialog(
            confirming.map { "Turn on \($0.title)?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            if let each = confirming {
                Button("Turn On") { set(each, on: true); confirming = nil }
                Button("Cancel", role: .cancel) { confirming = nil }
            }
        } message: {
            if let each = confirming { Text(confirmMessage(each)) }
        }
    }

    private func set(_ each: ProjectSwitch, on: Bool) {
        Task {
            do {
                try await engine.call("projects.set", ["id": project.id, "settings": ["withoutAsking": [each.name: on]]])
                problem = nil
            } catch { problem = error.localizedDescription }
        }
    }

    /// What the person is asked when they turn a switch on: what the orchestrator may then do without asking them.
    private func confirmMessage(_ each: ProjectSwitch) -> String {
        let line = each.confirm ?? each.allows
        return "The orchestrator may then \(line.prefix(1).lowercased() + line.dropFirst())"
    }
}

// MARK: - The agents' rows

/// One agent of the project: its avatar, name and model, the mark when the orchestrator made it, and whether it is
/// working now. Update from Template shows while its template has changed since it was copied.
private struct AgentListRow: View {
    let model: AppModel
    let project: ProjectRow
    let agent: AgentProfile
    let update: () -> Void
    let open: () -> Void
    private var engine: EngineClient { model.engine }

    private var working: Bool {
        engine.activity.contains { $0.projectId == project.id && $0.runsAs == agent.id }
    }

    /// Who made this agent through a tool (docs/projects.md, 3.3), as the row's mark says it.
    private var madeBy: String? {
        guard let mark = agent.madeBy else { return nil }
        let name = engine.agent(mark.agentId)?.name ?? "an agent"
        return mark.agentId == project.orchestratorId ? "Made by the orchestrator" : "Made by \(name)"
    }

    /// Whether the template this agent was copied from has changed since (docs/projects.md, 3.3).
    private var templateChanged: Bool {
        guard let mark = agent.template, let template = engine.agent(mark.id), template.projectId == nil else { return false }
        return (template.updatedAt ?? template.createdAt) != mark.templateUpdatedAt
    }

    /// Why Update from Template cannot be offered, when it cannot.
    private var templateGone: Bool {
        guard let mark = agent.template else { return false }
        return engine.agent(mark.id)?.projectId != nil || engine.agent(mark.id) == nil
    }

    var body: some View {
        HStack(spacing: 12) {
            // The leading part opens the agent's page; the controls beside it are controls of their own, so they are
            // reachable on their own too.
            Button(action: open) {
                HStack(spacing: 12) {
                    if working { Spinner().frame(width: 28) } else { AgentAvatar(agent: agent, size: 28) }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(agent.name)
                                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.tx)
                                .lineLimit(1)
                            if let madeBy { Tag(madeBy, .acc).fixedSize().help("Made through a tool, in this project's conversation") }
                        }
                        Text(agent.description.isEmpty ? engine.shortModelName(agent.model) : "\(engine.shortModelName(agent.model)) · \(agent.description)")
                            .font(.caption).foregroundStyle(Theme.tx3).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(agent.name)'s settings")
            if templateChanged {
                Button("Update from Template…") { update() }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .help("The template this agent was made from has changed. See what would change, and bring it up to date.")
            } else if templateGone {
                Text("Template deleted").font(.caption).foregroundStyle(Theme.tx3)
                    .help("The template this agent was made from has been deleted, so it cannot be updated from it.")
            }
            if working {
                Tag("working", .acc).fixedSize().help("\(agent.name) is working now")
            }
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tx3)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .panel()
    }
}

// MARK: - An agent's own page, in the tab

/// Today's agent page (AgentViews.swift), shown in the board with the way back to the tab. Nothing of it is built
/// again here; the back button is the tab's own.
private struct AgentPageInTab: View {
    let model: AppModel
    let agentID: String
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { back() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text("Agents")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tx2)
                }
                .buttonStyle(.plain)
                .help("Back to this project's agents")
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            AgentEditor(model: model, agentID: agentID, onDeleted: back)
        }
    }
}

// MARK: - Update from template

/// What Update from Template would change in a copy, setting by setting (docs/projects.md, 3.3): the value in the copy
/// now, and the template's. Update applies it and notes when the copy was brought up to date; Cancel changes nothing.
private struct UpdateFromTemplateSheet: View {
    struct Change: Identifiable {
        let setting: String
        let now: JSONValue
        let template: JSONValue
        var id: String { setting }
    }

    let engine: EngineClient
    let agent: AgentProfile
    let template: AgentProfile
    @Environment(\.dismiss) private var dismiss
    @State private var changes: [Change]?
    @State private var problem: String?
    @State private var applying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update \(agent.name) from “\(template.name)”?")
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.tx)
            Text("The template has changed since this agent was made from it. These settings would change; everything else stays as it is.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.line)
            Group {
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(Theme.bad)
                } else if let changes {
                    if changes.isEmpty {
                        Text("Everything this agent takes from the template already matches it.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.tx2)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(changes) { change in
                                    row(change)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Spinner().frame(width: 14)
                        Text("Reading what has changed…").font(.system(size: 12.5)).foregroundStyle(Theme.tx2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                }
            }
            Text("Its name, folder, who it can hand work to, allowed commands, variables and Allow everything are this project's own, and never come from the template.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tx3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                Button("Update") { apply() }
                    .buttonStyle(.piPrimary)
                    .disabled((changes?.isEmpty ?? true) || applying)
                    .help("Bring \(agent.name) up to date with “\(template.name)”")
                if applying { Spinner().frame(width: 14) }
            }
        }
        .padding(16)
        .frame(width: 460, height: 380)
        .task { await read() }
    }

    /// One setting that would change: what it is called, and its value in the copy now and in the template.
    private func row(_ change: Change) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title(change.setting))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tx)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(words(change.setting, change.now))
                    .font(.system(size: 12)).foregroundStyle(Theme.tx2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tx3)
                Text(words(change.setting, change.template))
                    .font(.system(size: 12)).foregroundStyle(Theme.tx)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10).panel()
    }

    /// Asks the engine what would change, changing nothing (`apply: false`).
    private func read() async {
        do {
            let result = try await engine.call("agents.updateFromTemplate", ["id": agent.id, "apply": false])
            changes = (result["changes"]?.arrayValue ?? []).compactMap { item in
                guard let setting = item["setting"]?.stringValue else { return nil }
                return Change(setting: setting, now: item["now"] ?? .null, template: item["template"] ?? .null)
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func apply() {
        applying = true
        Task {
            do {
                try await engine.call("agents.updateFromTemplate", ["id": agent.id, "apply": true])
                dismiss()
            } catch {
                problem = error.localizedDescription
                applying = false
            }
        }
    }

    /// What the setting is called on an agent's own page.
    private func title(_ setting: String) -> String {
        switch setting {
        case "description": "Description"
        case "color": "Colour"
        case "model": "Model"
        case "thinkingLevel": "Thinking"
        case "instructions": "Instructions"
        case "access": "Tool access"
        case "worktree": "Give each conversation its own worktree"
        case "setup": "Set-up command"
        case "maxTurns": "Turn limit per run"
        case "codeMode": "Write scripts that call its tools"
        case "mcpServers": "Extra tools (MCP servers)"
        case "files": "Reference files"
        case "computer": "Computer use"
        case "browser": "Browser"
        case "schedule": "Can schedule its own work"
        case "toolsOff": "Built-in tools left out"
        case "toolsOn": "Built-in tools off by default, turned on"
        case "compactionTokens": "Summary size"
        case "memory": "Memory"
        default: setting
        }
    }

    /// A setting's value as the person reads it on the agent's page. Shown whole, however long, so that a change to
    /// a long text such as the instructions can be seen; the sheet scrolls when it does not fit.
    private func words(_ setting: String, _ value: JSONValue) -> String {
        switch value {
        case .null:
            switch setting {
            case "model": return "App default"
            case "thinkingLevel": return "Default"
            case "maxTurns": return "No limit"
            case "compactionTokens": return "Default for all agents"
            case "setup": return "None"
            default: return "None"
            }
        case .bool(let on):
            return on ? "On" : "Off"
        case .number(let value):
            return setting == "compactionTokens" ? "\(Int(value)) tokens" : value.rounded() == value ? String(Int(value)) : String(value)
        case .string(let text):
            switch setting {
            case "access": return AccessLevel.all.first { $0.id == text }?.title ?? text
            case "color": return text.capitalized
            case "thinkingLevel": return text.capitalized
            default: return text.isEmpty ? "Empty" : text
            }
        case .array(let items):
            let names = items.compactMap { item -> String? in
                if case .string(let name) = item { return name }
                return item["path"]?.stringValue
            }
            return names.isEmpty ? "None" : names.joined(separator: ", ")
        case .object(let fields):
            switch setting {
            case "model":
                return "\(fields["provider"]?.stringValue ?? "") · \(fields["modelId"]?.stringValue ?? "")"
            case "computer", "browser":
                let on = fields["enabled"] == .bool(true)
                var text = on ? "On" : "Off"
                if on, setting == "computer", let apps = fields["apps"]?.arrayValue, !apps.isEmpty {
                    text += " · \(apps.compactMap(\.stringValue).joined(separator: ", "))"
                }
                if on, fields["ask"] == .bool(false) { text += ", without asking" }
                return text
            case "schedule":
                return fields["enabled"] == .bool(true) ? "On" : "Off"
            default:
                return fields.keys.sorted().compactMap { key in
                    guard let inner = fields[key] else { return nil }
                    return "\(key): \(words(key, inner))"
                }.joined(separator: ", ")
            }
        }
    }
}
