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
        for agent in engine.agents where matches("new conversation with \(agent.name)") {
            result.append(Entry(id: "new-\(agent.id)", icon: "plus.bubble", title: "New conversation with \(agent.name)", detail: "Agent") { model.newConversation(agentId: agent.id) })
        }
        let places: [(String, String, Selection)] = [("Inbox", "tray", .inbox), ("Activity", "waveform.path.ecg", .activity), ("Usage", "chart.bar", .usage), ("Archive", "archivebox", .archive)]
        for (name, icon, selection) in places where matches("go to \(name)") {
            result.append(Entry(id: "go-\(name)", icon: icon, title: "Go to \(name)", detail: "View") { model.selection = selection })
        }
        if matches("new agent") { result.append(Entry(id: "new-agent", icon: "person.badge.plus", title: "New Agent", detail: "Action") { model.newAgent() }) }
        if matches("quick ask") { result.append(Entry(id: "quick-ask", icon: "bolt", title: "Quick Ask", detail: "Action") { QuickAsk.shared.show(model: model) }) }
        if matches("settings providers tools") { result.append(Entry(id: "settings", icon: "gearshape", title: "Settings", detail: "Action") { openSettings() }) }
        for agent in engine.agents where !needle.isEmpty && matches("edit agent \(agent.name)") {
            result.append(Entry(id: "agent-\(agent.id)", icon: "person.crop.circle", title: "Edit agent: \(agent.name)", detail: "Agent") { model.selection = .agent(agent.id) })
        }
        for conversation in engine.conversations where matches(conversation.title) {
            let agent = (engine.agent(conversation.agentId)?.name ?? "") + (conversation.parent == nil ? "" : " · sub-chat")
            result.append(Entry(id: "c-\(conversation.id)", icon: "bubble.left", title: conversation.title.isEmpty ? "New conversation" : conversation.title, detail: conversation.busy ? "\(agent) · working" : agent) {
                model.selection = .conversation(conversation.id)
            })
        }
        // Archived conversations are found only by typing: they were put away so as not to be in the way.
        for conversation in engine.archived where !needle.isEmpty && matches(conversation.title) {
            let agent = engine.agent(conversation.agentId)?.name ?? ""
            result.append(Entry(id: "a-\(conversation.id)", icon: "archivebox", title: conversation.title.isEmpty ? "New conversation" : conversation.title, detail: agent.isEmpty ? "Archived" : "\(agent) · archived") {
                model.selection = .conversation(conversation.id)
            })
        }
        for message in messages {
            result.append(Entry(id: "m-\(message.entryId)", icon: "text.magnifyingglass", title: message.snippet, detail: "In “\(message.title.isEmpty ? "New conversation" : message.title)”\(message.archived == true ? " · archived" : "")") {
                model.selection = .conversation(message.conversationId)
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
        .onAppear { focused = true }
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

    private func run(_ entries: [Entry], at index: Int) {
        guard entries.indices.contains(index) else { return }
        dismiss()
        entries[index].run()
    }
}
