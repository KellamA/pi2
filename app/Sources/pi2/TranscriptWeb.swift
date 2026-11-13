import AppKit
import ComputerKit
import SwiftUI
import WebKit

/// A conversation's transcript: one web page, so a selection can run across prose, code and tool steps and copy as
/// text; or, when the page is not in the app (a bare `swift build`), the SwiftUI transcript. See docs/transcript.md.
struct ConversationTranscript: View {
    let engine: EngineClient
    let conversationID: Int
    let items: [Item]
    let state: ConversationState?

    var body: some View {
        if let folder = TranscriptPage.folder {
            TranscriptWebView(
                folder: folder, engine: engine, conversationID: conversationID, items: items, state: state,
                inbox: engine.inbox.filter { $0.conversationId == conversationID }, names: names
            )
        } else {
            TranscriptView(engine: engine, conversationID: conversationID, items: items, state: state)
        }
    }

    /// The names the page shows that only the app knows, read here so that a change to any of them updates the page.
    private var names: TranscriptFeed.Names {
        var mcp: [String: String] = [:]
        for server in engine.mcpServers {
            for tool in server.tools { mcp[tool.toolName] = "\(server.name): \(tool.name)" }
        }
        let agents = engine.agents.map { agent in
            TranscriptFeed.Agent(
                id: agent.id, name: agent.name, color: TranscriptPalette.css(AgentColor.color(agent.color)) ?? "",
                model: engine.shortModelName(agent.model)
            )
        }
        var apps: [String: String] = [:]
        for app in TranscriptFeed.appsNamed(in: items, partial: state?.partial, inbox: engine.inbox) {
            apps[app] = ComputerController.name(of: app)
        }
        return TranscriptFeed.Names(
            conversationId: conversationID, agentName: engine.agent(state?.agent.agentId)?.name ?? "",
            mcp: mcp, agents: agents, apps: apps
        )
    }
}

struct TranscriptWebView: NSViewRepresentable {
    let folder: URL
    let engine: EngineClient
    let conversationID: Int
    let items: [Item]
    let state: ConversationState?
    let inbox: [InboxItem]
    let names: TranscriptFeed.Names

    func makeCoordinator() -> TranscriptBridge {
        TranscriptBridge(engine: engine, conversationID: conversationID)
    }

    func makeNSView(context: Context) -> TranscriptWebKitView {
        context.coordinator.makeView(folder: folder)
    }

    func updateNSView(_ view: TranscriptWebKitView, context: Context) {
        context.coordinator.show(conversationID: conversationID, items: items, state: state, inbox: inbox, names: names)
    }

    static func dismantleNSView(_ view: TranscriptWebKitView, coordinator: TranscriptBridge) {
        view.close()
    }
}

/// Between the page and the engine: sends the page what changed, and carries out what the person does there with the
/// same requests the SwiftUI transcript makes, once it has checked the request belongs to this conversation.
@MainActor
final class TranscriptBridge {
    private let engine: EngineClient
    private var conversationID: Int
    private weak var view: TranscriptWebKitView?
    private var ready = false
    private var feed = TranscriptFeed()
    private var items: [Item] = []
    private var state: ConversationState?
    private var inbox: [InboxItem] = []
    private var names: TranscriptFeed.Names?

    init(engine: EngineClient, conversationID: Int) {
        self.engine = engine
        self.conversationID = conversationID
    }

    func makeView(folder: URL) -> TranscriptWebKitView {
        let view = TranscriptWebKitView(folder: folder)
        view.underPageBackgroundColor = NSColor(Theme.window)
        // Hidden until the page is ready, so opening a conversation never flashes an empty page.
        view.alphaValue = 0
        view.onAction = { [weak self] action in self?.perform(action) }
        view.onReload = { [weak self] in self?.ready = false }
        view.onAppearanceChange = { [weak self] in self?.push() }
        self.view = view
        return view
    }

    func show(conversationID: Int, items: [Item], state: ConversationState?, inbox: [InboxItem], names: TranscriptFeed.Names) {
        if conversationID != self.conversationID {
            self.conversationID = conversationID
            feed.restart()
        }
        self.items = items
        self.state = state
        self.inbox = inbox
        self.names = names
        push()
    }

    private func push() {
        guard ready, let view, let names else { return }
        let palette = TranscriptPalette.colors(for: view.effectiveAppearance)
        guard let message = feed.update(items: items, state: state, inbox: inbox, names: names, palette: palette),
              let json = TranscriptFeed.json(message) else { return }
        send(json)
    }

    private func send(_ json: String) {
        // The JSON goes in as an argument and is parsed by the page, so nothing in it is ever run as script.
        view?.callAsyncJavaScript("window.pi2.receive(message)", arguments: ["message": json], in: nil, in: .page, completionHandler: nil)
    }

    private func perform(_ action: TranscriptAction) {
        switch action {
        case .ready:
            ready = true
            feed.restart()
            push()
            view?.alphaValue = 1
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .openLink(let url):
            NSWorkspace.shared.open(url)
        case .decide(let id, let decision):
            guard inbox.contains(where: { $0.id == id && $0.kind == "approval" }) else { return }
            engine.perform("inbox.decide", ["id": id, "decision": decision])
        case .answer(let id, let text):
            guard inbox.contains(where: { $0.id == id && $0.kind != "approval" }) else { return }
            engine.perform("inbox.answer", ["id": id, "text": text])
        case .openChat(let id):
            guard subChats.contains(id) else { return }
            engine.openConversation(id)
            engine.onNavigate(id)
        case .fork(let entry):
            guard items.contains(where: { $0.id == entry && $0.kind == "assistant" }) else { return }
            engine.fork(conversationID, at: entry)
        case .picture(let entry, let index):
            guard let item = items.first(where: { $0.id == entry }), index < (item.images ?? 0) else { return }
            sendPicture(entry: entry, index: index)
        }
    }

    /// The sub-chats this conversation's hand-offs opened, as their calls' results (or live state) name them.
    private var subChats: Set<Int> {
        var ids = Set<Int>()
        for item in items where item.kind == "tool" && item.name == "delegate" {
            if let id = item.details?["conversationId"]?.intValue { ids.insert(id) }
        }
        for tool in state?.tools ?? [] where tool.name == "delegate" {
            if let id = tool.details?["conversationId"]?.intValue { ids.insert(id) }
        }
        return ids
    }

    private static let pictureTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// Fetches one of an entry's pictures from the engine and hands it to the page, or tells the page it failed.
    private func sendPicture(entry: Int, index: Int) {
        let conversationID = conversationID
        Task { [weak self] in
            guard let self else { return }
            var picture: [String: Any] = ["entry": entry, "index": index]
            if let result = try? await engine.call("conversation.image", ["id": conversationID, "entryId": entry, "index": index]),
               let data = result["data"]?.stringValue, let type = result["mimeType"]?.stringValue, Self.pictureTypes.contains(type) {
                picture["data"] = data
                picture["mimeType"] = type
            }
            guard conversationID == self.conversationID,
                  let json = try? JSONSerialization.data(withJSONObject: ["image": picture]),
                  let text = String(data: json, encoding: .utf8) else { return }
            send(text)
        }
    }
}
