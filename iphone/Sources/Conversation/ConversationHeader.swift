import EngineKit
import PiModels
import SwiftUI

/// The top of a conversation's screen (the drafts' "An agent's conversation"): the agent's mark and name, its model and
/// project under it, and a spinner while it works. Capped at the largest standard text size, as the system's own
/// navigation titles are, so that it fits in the bar.
struct ConversationHeader: View {
    let name: String
    let color: String?
    let subtitle: String
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(String(name.prefix(1)).uppercased())
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color(white: 0.07))
                .frame(width: 26, height: 26)
                .background(Color(uiColor: ConversationColors.agent(color)), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
}

/// What the screen reads of the engine for its header and the page's names.
@MainActor
enum ConversationNames {
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
