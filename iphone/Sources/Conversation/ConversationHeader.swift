import EngineKit
import PiModels
import SwiftUI

/// The top of a conversation's screen (the drafts' "An agent's conversation"): the agent's mark and name, its model and
/// project under it, and a spinner while it works; for a chat, pi²'s mark and the chat's title. Capped at the largest
/// standard text size, as the system's own navigation titles are, so that it fits in the bar.
struct ConversationHeader: View {
    let name: String
    let color: String?
    let subtitle: String
    let busy: Bool
    /// A chat with pi²'s own assistant, which has no agent: its mark is pi²'s, not an agent's letter.
    var chat = false

    var body: some View {
        HStack(spacing: 8) {
            mark
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([name, subtitle, busy ? "working" : nil].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var mark: some View {
        if chat {
            Text("π")
                .font(.system(.callout, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.pi2Accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Text(String(name.prefix(1)).uppercased())
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color(white: 0.07))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AgentColor.color(color), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

/// What the screen reads of the engine for its header and the page's names.
@MainActor
enum ConversationNames {
    /// The title the engine gave, or nil for none yet: an untitled conversation's title is the empty string, not nil,
    /// and a title of spaces alone names nothing either.
    static func given(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    /// A chat with pi²'s own assistant (docs/chat.md), as the library's row, the Archive's or the conversation's state says.
    static func isChat(summary: ConversationSummary?, archived: ArchivedConversation?, state: ConversationState?) -> Bool {
        summary?.isChat == true || archived?.isChat == true || state?.chat == true
    }

    /// The screen's header. An agent's conversation is named by its agent, with its project or title under it; a chat,
    /// which has no agent, by its title, or "New chat" before it has one, as the Mac's chat mode and the phone's lists
    /// call it, with pi²'s mark and its assistant named under it.
    static func header(
        conversationID: Int, summary: ConversationSummary?, archived: ArchivedConversation?, state: ConversationState?,
        agent: AgentProfile?, model: String, project: String?, busy: Bool
    ) -> ConversationHeader {
        let chat = isChat(summary: summary, archived: archived, state: state)
        let title = given(summary?.title) ?? given(archived?.title) ?? given(state?.title)
        let name: String
        let place: String?
        if chat {
            name = title ?? "New chat"
            place = "pi²’s assistant"
        } else {
            let known = summary != nil || archived != nil
            name = agent?.name ?? title ?? (known ? "New conversation" : "Conversation \(conversationID)")
            place = state?.agent.parent != nil ? "sub-chat \(conversationID)" : project ?? (agent == nil ? nil : title)
        }
        return ConversationHeader(
            name: name, color: chat ? nil : agent?.color,
            subtitle: (chat ? [place, model] : [model, place]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            busy: busy, chat: chat
        )
    }

    /// What a conversation with nothing in it yet says, in place of the page: a chat's is the Mac's chat mode's question.
    static func emptyWords(chat: Bool, agentName: String?) -> (title: String, text: String) {
        if chat { return ("What can I help with?", "Ask pi²’s assistant below. It answers on your Mac.") }
        return ("Nothing here yet", "Write to \(agentName ?? "the agent") below. It works on your Mac.")
    }

    /// A model's name as the Mac's sidebar shows it: "Opus 5.5" rather than "Claude Opus 5.5" (`shortModelName`).
    static func shortModelName(_ ref: ModelRef?, engine: EngineSession<MessageField>) -> String {
        guard let ref = ref ?? engine.defaultModel else { return "" }
        let name = engine.allModels.first { $0.ref == ref }?.name ?? ref.modelId
        for prefix in ["Claude ", "Demo model "] where name.hasPrefix(prefix) {
            let rest = String(name.dropFirst(prefix.count))
            return rest.isEmpty ? name : rest.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        }
        return name
    }

    /// The names the page shows that only the app knows (docs/transcript.md): the tools' servers, the agents with
    /// their colours and models, and the conversation's agent.
    static func page(conversationID: Int, state: ConversationState?, engine: EngineSession<MessageField>) -> TranscriptFeed.Names {
        var mcp: [String: String] = [:]
        for server in engine.mcpServers {
            for tool in server.tools { mcp[tool.toolName] = "\(server.name): \(tool.name)" }
        }
        let agents = engine.allAgents.map { agent in
            TranscriptFeed.Agent(
                id: agent.id, name: agent.name, color: ConversationPalette.css(ConversationColors.agent(agent.color)),
                model: shortModelName(agent.model, engine: engine)
            )
        }
        // Apps are named by their bundle ids: their names are the Mac's to know.
        return TranscriptFeed.Names(
            conversationId: conversationID, agentName: engine.agent(state?.agent.agentId)?.name ?? "",
            mcp: mcp, agents: agents, apps: [:], folder: state?.agent.cwd?.hasPrefix("/") == true
        )
    }
}

/// Which conversations the phone shows, for the engine (`conversations.shown`): a model on the Mac stays loaded while
/// a conversation using it is shown. Several screens can show conversations at once (a hub's Chat tab under an agent's
/// screen), so each counts in and out.
@MainActor
enum ConversationShown {
    private static var counts: [Int: Int] = [:]

    static func appeared(_ id: Int, in engine: EngineSession<MessageField>) {
        counts[id, default: 0] += 1
        engine.setShown(Set(counts.keys))
    }

    static func disappeared(_ id: Int, in engine: EngineSession<MessageField>) {
        guard let count = counts[id] else { return }
        counts[id] = count > 1 ? count - 1 : nil
        engine.setShown(Set(counts.keys))
        // A conversation nobody has shown for a while stops coming from the engine (#347).
        engine.closeUnwanted()
    }
}
