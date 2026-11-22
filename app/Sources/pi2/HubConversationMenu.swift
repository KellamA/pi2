import SwiftUI

// What can be done to one of a project's conversations from the hub and the sidebar of projects (#642): stop it, rename,
// export, archive or delete it, and, in the header of an agent's conversation, the agent's model and thinking, which
// are the agent's for all its conversations rather than one conversation's (the owner's answer on G3, #483). The
// prompts these open (rename, the delete confirmation) are the window's, in `RootView`, shared with chat mode.

/// The items of a conversation's own menu: a sidebar row's context menu and the agent panel's header menu. For the
/// orchestrator's current conversation, only Stop and Export: it is renamed with the project and archived by Start
/// fresh, and deleting it leaves the project with no conversation (docs/projects.md, 3.6).
struct ConversationActions: View {
    let model: AppModel
    let id: Int
    private var engine: EngineClient { model.engine }

    var body: some View {
        if let conversation = engine.conversations.first(where: { $0.id == id }) {
            let current = conversation.orchestrator == "current"
            if engine.isWorking(id) {
                Button("Stop") { engine.perform("abort", ["id": id]) }
                    .help("Stop its run and everything it started")
                Divider()
            }
            if !current {
                Button("Rename…") { model.beginRename(conversation) }
                    .help("Rename this conversation")
            }
            Menu("Export") {
                Button("As Markdown…") { StorageActions.export(conversation, format: "markdown", engine: engine) }
                Button("As JSON…") { StorageActions.export(conversation, format: "json", engine: engine) }
            }
            .help("Save this conversation to a file")
            if !current {
                Divider()
                let refusal = Self.archiveRefusal(conversation)
                Button("Archive") { model.archive(conversation) }
                    .disabled(refusal != nil)
                    .help(refusal ?? "Put this conversation away, stopping its work. It can be restored from the Archive.")
                Button("Delete…", role: .destructive) { model.delete(conversation) }
                    .help("Delete this conversation, after asking")
            }
        }
    }

    /// Why a conversation cannot be archived on its own, for the menus that offer it.
    static func archiveRefusal(_ conversation: ConversationSummary) -> String? {
        if conversation.parent != nil { return "A sub-chat is archived with the conversation it belongs to." }
        if conversation.orchestrator == "current" { return currentRefusal }
        return nil
    }

    /// Why the orchestrator's current conversation is not renamed, archived or deleted on its own.
    static let currentRefusal = "This is the project’s conversation with its orchestrator. It is renamed with the project, and kept as an earlier conversation when you Start Fresh…"
}

extension EngineClient {
    /// Whether a conversation is running: answering, or waiting on the person or a provider's limit. Stop applies.
    func isWorking(_ id: Int) -> Bool {
        conversations.first(where: { $0.id == id })?.busy == true || open[id]?.state?.busy == true || projectStore.run(id) != nil
    }

    /// The conversations that run as `agent` and still take messages: every one in the sidebar's list, sub-chats
    /// included, but an earlier conversation with a project's orchestrator (docs/projects.md, 3.5).
    func liveConversations(of agent: String) -> [Int] {
        conversations.filter { ($0.runsAs ?? $0.agentId) == agent && $0.orchestrator != "earlier" && !$0.isChat }.map(\.id)
    }

    /// Gives an agent another model, for all its conversations from their next message (#642). The agent keeps it for
    /// the conversations it starts; each of its conversations already going is changed too, since in a project the model
    /// is the agent's and not one conversation's.
    func setModel(_ model: ModelInfo, for agent: AgentProfile) {
        let ref: [String: Any] = ["provider": model.provider, "modelId": model.id]
        // The engine keeps every setting it is not sent, and the agent's project.
        perform("agents.save", ["agent": ["id": agent.id, "name": agent.name, "model": ref]])
        for id in liveConversations(of: agent.id) where open[id]?.state?.agent.model != model.ref {
            perform("conversation.configure", ["id": id, "model": ref])
        }
    }

    /// Gives an agent another thinking level, for all its conversations from their next message, as `setModel` does.
    func setThinking(_ level: String, for agent: AgentProfile) {
        perform("agents.save", ["agent": ["id": agent.id, "name": agent.name, "thinkingLevel": level]])
        for id in liveConversations(of: agent.id) where open[id]?.state?.agent.thinkingLevel != level {
            perform("conversation.configure", ["id": id, "thinkingLevel": level])
        }
    }

    /// The model an agent's next conversation starts on: its own, or the default for agents.
    func modelInfo(of agent: AgentProfile?) -> ModelInfo? {
        guard let ref = agent?.model ?? defaultModel else { return nil }
        return allModels.first { $0.ref == ref }
    }
}

/// An agent's model and thinking, as items of a menu: the agent panel's header menu (#642). Each changes the agent,
/// and with it all its conversations from their next message.
struct AgentModelItems: View {
    let engine: EngineClient
    let agent: AgentProfile

    var body: some View {
        let current = engine.modelInfo(of: agent)
        Section("For all of \(agent.name)’s conversations") {
            Menu("Model: \(current?.name ?? agent.model?.modelId ?? "None")") {
                ModelChoices(engine: engine, selected: agent.model) { engine.setModel($0, for: agent) }
            }
            .help(AgentModelItems.modelHelp(agent.name))
            if let levels = current?.thinkingLevels, !levels.isEmpty {
                ThinkingChoices(engine: engine, agent: agent, levels: levels)
            }
        }
    }

    static func modelHelp(_ name: String) -> String { "\(name)’s model, for all of \(name)’s conversations, from its next message" }
    static func thinkingHelp(_ name: String) -> String { "How much \(name)’s model reasons before answering, for all of \(name)’s conversations, from its next message" }
}

/// The Thinking menu of an agent: the agent panel's header menu and the hub's bar, beside the orchestrator's model.
struct ThinkingChoices: View {
    let engine: EngineClient
    let agent: AgentProfile
    let levels: [String]

    var body: some View {
        Menu(agent.thinkingLevel.map { "Thinking: \($0.capitalized)" } ?? "Thinking: Default") {
            Picker("Thinking", selection: Binding(
                get: { agent.thinkingLevel ?? "" },
                set: { engine.setThinking($0, for: agent) }
            )) {
                ForEach(levels, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .help(AgentModelItems.thinkingHelp(agent.name))
    }
}

/// In the header of an agent's conversation in place of the board: the button to the sub-chat's parent (#642), shown
/// for a sub-chat only.
struct ParentButton: View {
    let model: AppModel
    let project: ProjectRow
    let id: Int
    private var engine: EngineClient { model.engine }

    var body: some View {
        // The list knows a sub-chat's parent; for a sub-chat of an archived conversation, its state does, as the old
        // toolbar's Parent Chat had it.
        let listed = engine.conversations.first(where: { $0.id == id })?.parent.flatMap { parent in engine.conversations.first { $0.id == parent }?.id }
        if let parent = listed ?? engine.open[id]?.state?.agent.parent {
            let orchestrator = parent == project.conversation
            let title = engine.conversations.first(where: { $0.id == parent })?.title ?? ""
            // Where the parent lives (#644): in place of the board, or the orchestrator's panel for its conversation.
            Button("Parent", systemImage: "arrow.turn.left.up") { model.openConversation(parent) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(Theme.tx3)
                .help(orchestrator
                    ? "Go to the conversation with the orchestrator, which handed this sub-chat its work"
                    : "Go to the conversation that handed this sub-chat its work\(title.isEmpty ? "" : ": \(title)")")
                .accessibilityLabel("Parent conversation")
        }
    }
}

extension ProjectHubs {
    /// Closes the panes that showed one of `conversations`, bringing the board back where that was the last of them:
    /// they were archived or deleted (#642, #657).
    func boardBack(from conversations: Set<Int>) {
        forget(projects: Array(Set(layouts.keys).union(savedLayouts.keys))) { conversations.contains($0) }
    }
}

extension AppModel {
    /// A conversation and its sub-chats, all the way down, as the list has them: what archiving it puts away.
    func withSubChats(_ id: Int) -> Set<Int> {
        var found: Set<Int> = [id]
        var added = true
        while added {
            added = false
            for conversation in engine.conversations where conversation.parent.map(found.contains) == true && !found.contains(conversation.id) {
                found.insert(conversation.id)
                added = true
            }
        }
        return found
    }
}
