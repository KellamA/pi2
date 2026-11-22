import SwiftUI

// Continue with an Agent (#289, docs/chat.md): a chat that turns into real work is handed to one of the person's agents,
// as the first message of a new conversation of that agent in the agent view, in a folder the person chooses. The engine
// (`chat.continueWithAgent`, engine/src/handover.ts) gives the agent the chat as it stands, with its pictures and files,
// and none of what chat mode remembers. The chat stays as it was, and each links to the other.

extension ConversationSummary {
    /// The conversations of agents this chat was continued in, oldest first.
    var continuations: [Int] { continuedIn ?? [] }
}

extension EngineClient {
    /// Whether a chat can be handed to an agent now: it has something in it, is not answering, and there is an agent.
    func canContinueWithAgent(_ id: Int) -> Bool {
        guard status == .connected, !agents.isEmpty, isChat(id) else { return false }
        let listed = conversations.first { $0.id == id }
        if listed?.busy == true || open[id]?.state?.busy == true { return false }
        if let data = open[id], data.state != nil { return !data.items.isEmpty }
        return !(listed?.title.isEmpty ?? true)
    }
}

extension AppModel {
    /// Asks which agent and folder to continue chat `id` with. The sheet is chat mode's, so the chat comes on screen.
    func continueWithAgent(_ id: Int) {
        guard engine.canContinueWithAgent(id) else { return }
        showChat(id)
        chats.continuing = id
    }
}

/// Which agent, which folder, and what it should do next; then the conversation, in the agent view.
struct ContinueWithAgentSheet: View {
    let model: AppModel
    let chat: Int
    @Environment(\.dismiss) private var dismiss
    @State private var agentId = ""
    /// A folder chosen here; nil for the agent's own.
    @State private var folder: String?
    @State private var text = ""
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var writing: Bool
    private var engine: EngineClient { model.engine }
    private var agent: AgentProfile? { engine.agent(agentId) }
    private var name: String { agent?.name ?? "The agent" }
    private var title: String { engine.conversationTitle(chat, chat: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Continue with an Agent").font(.system(size: 17, weight: .semibold))
                Text("“\(title)” goes to the agent as the first message of a new conversation, as it stands, with its pictures and files. The chat stays as it is, and each links to the other.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tx2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Agent").foregroundStyle(Theme.tx2).gridColumnAlignment(.trailing)
                    Picker("Agent", selection: $agentId) {
                        ForEach(engine.agents) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }
                GridRow {
                    Text("Folder").foregroundStyle(Theme.tx2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(folderText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button("Choose…") { if let chosen = EngineClient.pickFolder() { folder = chosen } }
                            if folder != nil { Button("Use \(name)’s Own") { folder = nil } }
                        }
                        .controlSize(.small)
                    }
                }
                GridRow {
                    Text("Next").foregroundStyle(Theme.tx2)
                    TextField("What should \(name) do now? Leave it empty to have it read the chat and wait.", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($writing)
                }
            }
            .font(.system(size: 13))
            Label(accessText, systemImage: "lock.shield")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tx2)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(sending ? "Continuing…" : "Continue") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(agent == nil || sending || engine.status != .connected)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if agent == nil { agentId = engine.agents.first?.id ?? "" }
            writing = true
        }
    }

    private var folderText: String {
        if let folder { return engine.folderName(folder) }
        if let cwd = agent?.cwd { return "\(engine.folderName(cwd)) (\(name)’s own)" }
        return "None: \(name) works in pi²’s scratch folder"
    }

    /// What the agent may do, so the person knows before it starts: its own settings apply from the first message.
    private var accessText: String {
        let level = AccessLevel.all.first { $0.id == agent?.access }?.title ?? "its own access"
        return "\(name) works with its own tools and tool access (\(level)), as in any of its conversations, and asks before anything its settings say to ask about. Nothing in the chat counts as an approval, and nothing chat mode remembers is passed on."
    }

    private func send() {
        guard let agent else { return }
        sending = true
        problem = nil
        var params: [String: Any] = ["id": chat, "agentId": agent.id]
        if let folder { params["cwd"] = folder }
        let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !next.isEmpty { params["text"] = next }
        Task {
            defer { sending = false }
            do {
                let result = try await engine.call("chat.continueWithAgent", params)
                guard let id = result["id"]?.intValue else { return }
                dismiss()
                engine.openConversation(id)
                // An agent's conversation: the window moves to the agent view, and the chat keeps its place here.
                model.openConversation(id)
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Under a conversation that is linked to another by Continue with an Agent: the chat it came from, or the
/// conversations a chat went on in, each a click away.
struct ContinuedLinks: View {
    let engine: EngineClient
    let id: Int
    var inset: CGFloat = 28

    private var summary: ConversationSummary? { engine.conversations.first { $0.id == id } }

    var body: some View {
        let links = self.links
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(links, id: \.id) { link in
                    HStack(spacing: 6) {
                        Image(systemName: link.icon).foregroundStyle(Theme.tx3)
                        Text(link.text).foregroundStyle(Theme.tx2).lineLimit(1).truncationMode(.middle)
                        Button(link.action) { engine.onNavigate(link.id, nil) }
                            .buttonStyle(.link)
                            .help(link.help)
                        Spacer(minLength: 0)
                    }
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, inset + 4).padding(.top, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("continued-links")
        }
    }

    private struct Link {
        let id: Int
        let icon: String
        let text: String
        let action: String
        let help: String
    }

    /// The other side of each link that still exists, listed or archived.
    private var links: [Link] {
        guard let summary else { return [] }
        let exists = { (other: Int) in engine.conversations.contains { $0.id == other } || engine.archived.contains { $0.id == other } }
        if let from = summary.continuedFrom, exists(from) {
            return [Link(id: from, icon: "bubble.left.and.bubble.right", text: "Continued from the chat “\(engine.conversationTitle(from, chat: true))”", action: "Open Chat", help: "Open the chat this conversation was continued from, in chat mode")]
        }
        return summary.continuations.filter(exists).suffix(3).map { other in
            let agent = engine.agent(engine.conversations.first { $0.id == other }?.agentId ?? engine.archived.first { $0.id == other }?.agentId)?.name ?? "an agent"
            return Link(id: other, icon: "arrowshape.turn.up.right", text: "Continued with \(agent) in “\(engine.conversationTitle(other, chat: false))”", action: "Open", help: "Open the conversation this chat was continued in, in the agent view")
        }
    }
}
