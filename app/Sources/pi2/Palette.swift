import SwiftUI

/// ⌘K: one box to start, switch and find things.
struct PaletteView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var selected = 0
    @State private var messages: [SearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    private var engine: EngineClient { model.engine }

    struct Entry: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let run: () -> Void
    }

    private var entries: [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = { (text: String) in needle.isEmpty || text.lowercased().contains(needle) }
        var result: [Entry] = []
        // With the Projects preview on, projects come first: they are what the sidebar lists. Archived ones only by typing.
        if engine.projectsPreview {
            for project in engine.projectStore.listed where matches(project.name) || matches("project \(project.name)") {
                result.append(Entry(id: "p-\(project.id)", icon: "folder", title: project.name, detail: project.folder.map { "Project · \(engine.folderName($0))" } ?? "Project") {
                    model.showProject(project.id)
                })
            }
            for project in engine.projectStore.archivedProjects where !needle.isEmpty && matches(project.name) {
                result.append(Entry(id: "p-\(project.id)", icon: "archivebox", title: project.name, detail: "Project · archived") { model.selection = .archive })
            }
            if matches("new project") { result.append(Entry(id: "new-project", icon: "folder.badge.plus", title: "New Project…", detail: "Action") {
                // The folder panel waits for the palette to go first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.newProject() }
            }) }
            if matches("go to dashboard") { result.append(Entry(id: "go-dashboard", icon: "square.grid.2x2", title: "Go to Dashboard", detail: "View") { model.selection = .dashboard }) }
            // Every agent's run at once, after a confirmation that names how many (#645); its dialog waits for the
            // palette to go first.
            let running = RunStopping.runs(in: nil, engine: engine).count
            if running > 0, matches("stop all runs agents") {
                result.append(Entry(id: "stop-all", icon: "stop.fill", title: "Stop All Runs…", detail: running == 1 ? "Action · 1 running" : "Action · \(running) running") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.stoppingAll = StopAllRequest(projects: nil) }
                })
            }
            projectEntries(needle, into: &result)
        }
        for agent in engine.agents where matches("new conversation with \(agent.name)") {
            result.append(Entry(id: "new-\(agent.id)", icon: "plus.bubble", title: "New conversation with \(agent.name)", detail: "Agent") { model.newConversation(agentId: agent.id) })
        }
        let places: [(String, String, Selection)] = [("Inbox", "tray", .inbox), ("Activity", "waveform.path.ecg", .activity), ("Usage", "chart.bar", .usage), ("Archive", "archivebox", .archive)]
        for (name, icon, selection) in places where matches("go to \(name)") {
            result.append(Entry(id: "go-\(name)", icon: icon, title: "Go to \(name)", detail: "View") { model.selection = selection })
        }
        if matches("new chat") { result.append(Entry(id: "new-chat", icon: "square.and.pencil", title: "New Chat", detail: "Chat") { model.newChat() }) }
        // The chat on screen, handed to an agent; its sheet waits for the palette to go first.
        if model.mode == .chat, let chat = model.chats.selection, engine.canContinueWithAgent(chat), matches("continue with an agent") {
            result.append(Entry(id: "continue-chat", icon: "arrowshape.turn.up.right", title: "Continue with an Agent…", detail: "Chat") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.continueWithAgent(chat) }
            })
        }
        for (name, mode) in [(engine.projectsPreview ? "Projects" : "Agents", WindowMode.agents), ("Chat", WindowMode.chat)] where model.mode != mode && matches("switch to \(name)") {
            result.append(Entry(id: "mode-\(name)", icon: mode == .chat ? "bubble.left.and.bubble.right" : "person.2", title: "Switch to \(name)", detail: "View") { model.mode = mode })
        }
        if matches("new agent") { result.append(Entry(id: "new-agent", icon: "person.badge.plus", title: "New Agent", detail: "Action") { model.newAgent() }) }
        if matches("quick ask") { result.append(Entry(id: "quick-ask", icon: "bolt", title: "Quick Ask", detail: "Action") { QuickAsk.shared.show(model: model) }) }
        if matches("settings providers tools") { result.append(Entry(id: "settings", icon: "gearshape", title: "Settings", detail: "Action") { openSettings() }) }
        for agent in engine.agents where matches("duplicate agent \(agent.name)") {
            result.append(Entry(id: "duplicate-\(agent.id)", icon: "doc.on.doc", title: "Duplicate agent: \(agent.name)", detail: "Agent") { model.duplicateAgent(agent.id) })
        }
        for agent in engine.agents where !needle.isEmpty && matches("edit agent \(agent.name)") {
            result.append(Entry(id: "agent-\(agent.id)", icon: "person.crop.circle", title: "Edit agent: \(agent.name)", detail: "Agent") { model.selection = .agent(agent.id) })
        }
        // Chats and agents' conversations are found alike, and each says which it is.
        for conversation in engine.conversations where conversation.isChat && matches(conversation.title) {
            result.append(Entry(id: "c-\(conversation.id)", icon: "bubble.left.and.bubble.right", title: conversation.title.isEmpty ? "New chat" : conversation.title, detail: conversation.busy ? "Chat · answering" : "Chat") {
                model.showChat(conversation.id)
            })
        }
        for conversation in engine.conversations where !conversation.isChat {
            // A project's conversation is named by its project, "Demo project › Check the build", and found by either.
            let project = conversation.projectId.flatMap(engine.project)
            let title = conversation.title.isEmpty ? "New conversation" : conversation.title
            let shown = project.map { "\($0.name) › \(title)" } ?? title
            guard project == nil ? matches(conversation.title) : (matches(conversation.title) || Self.hasWords(needle, in: shown)) else { continue }
            let owner = engine.agent(conversation.runsAs ?? conversation.agentId)
            let agent = (owner?.name ?? "") + (conversation.parent == nil ? "" : " · sub-chat")
                + (project?.conversation == conversation.id ? " · orchestrator" : "")
                + (AllowEverything.warning(conversation, agent: owner) == nil ? "" : " · \(AllowEverything.tag)")
            result.append(Entry(id: "c-\(conversation.id)", icon: "bubble.left", title: shown, detail: conversation.busy ? "\(agent) · working" : agent) {
                model.openConversation(conversation.id)
            })
        }
        // Archived conversations are found only by typing: they were put away so as not to be in the way.
        for conversation in engine.archived where !needle.isEmpty && matches(conversation.title) {
            let agent = conversation.isChat ? "Chat" : engine.agent(conversation.agentId)?.name ?? ""
            result.append(Entry(id: "a-\(conversation.id)", icon: "archivebox", title: conversation.title.isEmpty ? "New conversation" : conversation.title, detail: agent.isEmpty ? "Archived" : "\(agent) · archived") {
                model.openConversation(conversation.id)
            })
        }
        for message in messages {
            let chat = message.chat == true || engine.isChat(message.conversationId)
            result.append(Entry(id: "m-\(message.entryId)", icon: "text.magnifyingglass", title: message.snippet, detail: "In “\(message.title.isEmpty ? (chat ? "New chat" : "New conversation") : message.title)”\(chat ? " · chat" : "")\(message.archived == true ? " · archived" : "")") {
                model.openConversation(message.conversationId)
            })
        }
        return Array(result.prefix(60))
    }

    var body: some View {
        let entries = entries
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search conversations and messages, or run a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(entries, at: selected) }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(entries.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .accessibilityIdentifier("palette-field")
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if entries.isEmpty { Text("No matches").foregroundStyle(.secondary).padding(20) }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            Button {
                                run(entries, at: index)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: entry.icon).frame(width: 18).foregroundStyle(.secondary)
                                    Text(entry.title).lineLimit(1)
                                    Spacer()
                                    Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(index == selected ? Color.piAccent.opacity(0.25) : .clear, in: .rect(cornerRadius: 6))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selected) { _, index in
                    if entries.indices.contains(index) { proxy.scrollTo(entries[index].id) }
                }
            }
        }
        .frame(width: 620, height: 420)
        .onAppear {
            focused = true
            #if PI2_DEVELOPMENT
            // Typed after it appears, so the message search below runs for it as for any typing.
            if let asked = PaletteLaunch.takeQuery() { query = asked }
            #endif
        }
        .onChange(of: query) { _, text in
            selected = 0
            searchTask?.cancel()
            let needle = text.trimmingCharacters(in: .whitespaces)
            guard needle.count >= 2 else {
                messages = []
                return
            }
            // Wait for a pause in typing before searching message text.
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let found = await engine.search(needle)
                if !Task.isCancelled { messages = found }
            }
        }
    }

    /// Whether every word typed is in `text`, in any order: "demo work" finds "Demo project › Work".
    private static func hasWords(_ needle: String, in text: String) -> Bool {
        let words = needle.split(separator: " ")
        let text = text.lowercased()
        return !words.isEmpty && words.allSatisfy { text.contains($0) }
    }

    /// Each listed project's agents, a new conversation with each, and its board's tabs, named by the project ("Demo
    /// project › Atlas", "Demo project › Work") and opened in its hub (#643). Only by typing, so that the list the palette
    /// opens on stays short.
    private func projectEntries(_ needle: String, into result: inout [Entry]) {
        guard !needle.isEmpty else { return }
        let has = { (text: String) in Self.hasWords(needle, in: text) }
        for listed in engine.projectStore.listed {
            guard let project = engine.project(listed.id) else { continue }
            for agent in model.startableAgents(project) {
                let orchestrator = agent.id == project.orchestratorId
                if has("\(project.name) \(agent.name)") {
                    result.append(Entry(id: "pa-\(agent.id)", icon: "person.crop.circle", title: "\(project.name) › \(agent.name)",
                                        detail: orchestrator ? "Orchestrator · its page" : "Agent · its page") {
                        model.showAgentPage(agent.id, in: project.id)
                    })
                }
                let start = orchestrator ? "Start fresh with \(agent.name)…" : "New conversation with \(agent.name)"
                if has("\(project.name) \(start)") {
                    result.append(Entry(id: "pn-\(agent.id)", icon: "plus.bubble", title: "\(project.name) › \(start)", detail: orchestrator ? "Orchestrator" : "Agent") {
                        // Start fresh's confirmation is the hub's alert, which waits for the palette to go first.
                        if orchestrator {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.startWith(agent, in: project) }
                        } else {
                            model.startWith(agent, in: project)
                        }
                    })
                }
            }
            for tab in HubTab.allCases where has("\(project.name) \(tab.title)") {
                result.append(Entry(id: "pt-\(project.id)-\(tab.rawValue)", icon: "rectangle.split.2x1", title: "\(project.name) › \(tab.title)", detail: "Tab") {
                    model.showProject(project.id, tab: tab)
                    if model.hubs.fold(project.id) == .boardFolded { model.hubs.setFold(.both, for: project.id) }
                })
            }
        }
    }

    private func run(_ entries: [Entry], at index: Int) {
        guard entries.indices.contains(index) else { return }
        dismiss()
        entries[index].run()
    }
}
