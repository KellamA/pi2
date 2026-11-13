import SwiftUI

/// The Archive: conversations put out of the sidebar but kept. Each can be read, found by search, restored or deleted.
struct ArchiveView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    private var engine: EngineClient { model.engine }

    /// What the filter leaves: every word typed has to be in the title or the agent's name.
    private var rows: [ArchivedConversation] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        guard !words.isEmpty else { return engine.archived }
        return engine.archived.filter { row in
            let text = "\(row.title) \(engine.agent(row.agentId)?.name ?? "")"
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if engine.archived.isEmpty {
                    ContentUnavailableView(
                        "Nothing archived",
                        systemImage: "archivebox",
                        description: Text("Archive a conversation to clear it out of the sidebar without losing it. It is kept here, search still finds it, and you can restore it at any time.")
                    )
                    .padding(.top, 40)
                } else {
                    list
                }
                automatic
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.window)
        .navigationTitle("Archive")
        .navigationSubtitle(engine.archived.isEmpty ? "Empty" : engine.archived.count == 1 ? "1 conversation" : "\(engine.archived.count) conversations")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            if engine.archived.count > 6 {
                TextField("Filter", text: $query, prompt: Text("Filter by title or agent"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter archived conversations")
                    .padding(.bottom, 4)
            }
            if rows.isEmpty {
                Text("No archived conversation matches “\(query)”.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                ArchiveRow(model: model, row: row)
            }
        }
    }

    /// The setting that archives what has gone unused. It lives here because this is where its results turn up.
    private var automatic: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Archive on its own").font(.headline)
            HStack {
                Text("Archive conversations not used for")
                Picker("Archive conversations not used for", selection: Binding(
                    get: { engine.autoArchiveDays ?? 0 },
                    set: { days in engine.perform("settings.setAutoArchive", ["days": days == 0 ? NSNull() : days as Any]) }
                )) {
                    Text("Never").tag(0)
                    ForEach(choices, id: \.self) { days in
                        Text(Self.label(days)).tag(days)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .panel()
            Text("A conversation that is working or waiting for you is left where it is. Archiving never deletes anything.")
                .formFooter()
        }
    }

    /// The usual choices, plus whatever is set if it is not one of them.
    private var choices: [Int] {
        var days = [7, 30, 90, 365]
        if let set = engine.autoArchiveDays, !days.contains(set) { days = (days + [set]).sorted() }
        return days
    }

    private static func label(_ days: Int) -> String {
        switch days {
        case 7: "A week"
        case 30: "A month"
        case 90: "Three months"
        case 365: "A year"
        default: "\(days) days"
        }
    }
}

struct ArchiveRow: View {
    @Bindable var model: AppModel
    let row: ArchivedConversation
    private var engine: EngineClient { model.engine }

    private var title: String { row.title.isEmpty ? "New conversation" : row.title }

    private var detail: String {
        var parts: [String] = []
        if let agent = engine.agent(row.agentId)?.name { parts.append(agent) }
        parts.append("archived \(Self.ago(row.archivedAt))")
        if row.subChats > 0 { parts.append(row.subChats == 1 ? "1 sub-chat" : "\(row.subChats) sub-chats") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatar(agent: engine.agent(row.agentId), size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Open") { model.selection = .conversation(row.id) }
                .help("Read it without restoring it")
            Button("Restore") { engine.perform("conversation.unarchive", ["id": row.id]) }
                .help("Put it back in the sidebar, where it can be continued")
            Button("Delete", systemImage: "trash") { model.delete(id: row.id, title: row.title) }
                .labelStyle(.iconOnly)
                .help("Delete “\(title)”")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .panel()
        .contextMenu {
            Button("Open") { model.selection = .conversation(row.id) }
            Button("Restore") { engine.perform("conversation.unarchive", ["id": row.id]) }
            Button("Delete", role: .destructive) { model.delete(id: row.id, title: row.title) }
        }
    }

    /// "today", "yesterday", "5 days ago", then the date.
    static func ago(_ milliseconds: Double) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: .now)).day ?? 0
        switch days {
        case ...0: return "today"
        case 1: return "yesterday"
        case 2...30: return "\(days) days ago"
        default: return "on \(date.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}
