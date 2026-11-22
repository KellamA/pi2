
import EngineKit
import Foundation
import Observation
import PiModels
import SwiftUI

/// Search, as the Mac's palette finds things (`PaletteView`): projects, chats and conversations by their names from what
/// the engine sent, archived ones too once something is typed, and the words of messages through the engine's `search`.
enum HomeSearch {
    /// One thing found, and the screen it opens.
    struct Found: Identifiable, Equatable {
        enum Kind: Equatable { case project, chat, conversation, archived, message }
        let id: String
        let kind: Kind
        let title: String
        let detail: String
        let route: Route
    }

    /// What matches `query` among the names the engine sent, in the palette's order: projects, chats, agents'
    /// conversations (named by their project, "Demo project › Check the build"), then archived ones.
    @MainActor
    static func names(_ query: String, in engine: EngineSession<MessageField>) -> [Found] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let matches = { (text: String) in text.lowercased().contains(needle) }
        let projects = engine.projects.filter { $0.deletedAt == nil && $0.archivedAt == nil }
        var found: [Found] = []
        for project in projects where matches(project.name) {
            found.append(Found(id: "p-\(project.id)", kind: .project, title: project.name, detail: String(localized: "Project"), route: .project(project.id)))
        }
        for chat in HomeLists.chats(engine.conversations) where matches(chat.title) {
            found.append(Found(id: "c-\(chat.id)", kind: .chat, title: chat.title, detail: chat.busy ? String(localized: "Chat · answering") : String(localized: "Chat"), route: .conversation(chat.id)))
        }
        for conversation in engine.conversations where !conversation.isChat {
            let project = conversation.projectId.flatMap { id in projects.first { $0.id == id } }
            let title = conversation.title.isEmpty ? String(localized: "New conversation") : conversation.title
            let shown = project.map { "\($0.name) › \(title)" } ?? title
            guard project == nil ? matches(conversation.title) : (matches(conversation.title) || hasWords(needle, in: shown)) else { continue }
            var detail = engine.agent(conversation.runsAs ?? conversation.agentId)?.name ?? ""
            if conversation.parent != nil { detail += String(localized: " · sub-chat") }
            if project?.conversation == conversation.id, detail.lowercased() != "orchestrator" { detail += String(localized: " · orchestrator") }
            if conversation.busy { detail += String(localized: " · working") }
            found.append(Found(id: "c-\(conversation.id)", kind: .conversation, title: shown, detail: detail, route: .conversation(conversation.id)))
        }
        for conversation in engine.archived where matches(conversation.title) {
            let agent = conversation.isChat ? String(localized: "Chat") : engine.agent(conversation.agentId)?.name ?? ""
            found.append(Found(id: "a-\(conversation.id)", kind: .archived,
                               title: conversation.title.isEmpty ? String(localized: "New conversation") : conversation.title,
                               detail: agent.isEmpty ? String(localized: "Archived") : String(localized: "\(agent) · archived"),
                               route: .conversation(conversation.id)))
        }
        return found
    }

    /// The engine's message search, as results to list.
    static func messages(_ results: [SearchResult]) -> [Found] {
        results.map { result in
            let title = result.title.isEmpty ? (result.chat == true ? String(localized: "New chat") : String(localized: "New conversation")) : result.title
            var detail = String(localized: "In “\(title)”")
            if result.chat == true { detail += String(localized: " · chat") }
            if result.archived == true { detail += String(localized: " · archived") }
            return Found(id: "m-\(result.entryId)", kind: .message, title: result.snippet, detail: detail, route: .conversation(result.conversationId))
        }
    }

    /// Whether every word typed is in `text`, in any order: "demo walk" finds "Demo project › Put together a walkthrough".
    static func hasWords(_ needle: String, in text: String) -> Bool {
        let words = needle.split(separator: " ")
        let text = text.lowercased()
        return !words.isEmpty && words.allSatisfy { text.contains($0) }
    }
}

/// The words of messages, found by the engine's `search` request a moment after the person stops typing, as the Mac's
/// palette asks for them. A refusal is kept and shown, rather than taken for nothing found.
@MainActor
@Observable
final class HomeMessageSearch {
    enum State: Equatable {
        /// Fewer than two letters typed: nothing asked.
        case idle
        case searching
        case found([HomeSearch.Found])
        case failed(String)
    }

    private(set) var state = State.idle
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Asks again for `query`, after a pause in typing.
    func update(_ query: String, in engine: EngineSession<MessageField>, pause: Duration = .milliseconds(250)) {
        task?.cancel()
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else {
            state = .idle
            return
        }
        state = .searching
        task = Task {
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            let result = await Self.search(needle, in: engine)
            guard !Task.isCancelled else { return }
            state = result
        }
    }

    /// The engine's `search`: `{ query }`, answered `{ results: [SearchResult] }` (`EngineSession.search`, which the Mac
    /// uses, takes a refusal for nothing found; this keeps it).
    static func search(_ needle: String, in engine: EngineSession<MessageField>) async -> State {
        do {
            let result = try await engine.call("search", ["query": needle])
            let data = try JSONEncoder().encode(result["results"] ?? .array([]))
            return .found(HomeSearch.messages(try JSONDecoder().decode([SearchResult].self, from: data)))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// The list while something is typed in the search field: names first, then messages.
struct HomeSearchResults: View {
    let query: String
    let messages: HomeMessageSearch
    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let names = HomeSearch.names(query, in: session.engine)
        if !names.isEmpty {
            Section("By Name") {
                ForEach(names) { found in row(found) }
            }
        }
        Section("Messages") {
            switch messages.state {
            case .idle:
                Text("Type two letters or more to search the words of messages.")
                    .foregroundStyle(.secondary)
            case .searching:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching messages…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .found(let found) where found.isEmpty:
                Text("No message has these words.").foregroundStyle(.secondary)
            case .found(let found):
                ForEach(found) { found in row(found) }
            case .failed(let message):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Messages could not be searched.")
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func row(_ found: HomeSearch.Found) -> some View {
        Button { openRoute(found.route) } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(found.title).lineLimit(typeSize.isAccessibilitySize ? nil : found.kind == .message ? 3 : 2)
                    if !found.detail.isEmpty {
                        Text(found.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    }
                }
                .foregroundStyle(.primary)
            } icon: {
                Image(systemName: icon(found.kind)).foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func icon(_ kind: HomeSearch.Found.Kind) -> String {
        switch kind {
        case .project: "folder"
        case .chat: "bubble.left.and.bubble.right"
        case .conversation: "bubble.left"
        case .archived: "archivebox"
        case .message: "text.magnifyingglass"
        }
    }
}
