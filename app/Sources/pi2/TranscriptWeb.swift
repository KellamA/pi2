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
                inbox: engine.inbox.filter { $0.conversationId == conversationID }, names: names, chat: chat
            )
        } else {
            TranscriptView(engine: engine, conversationID: conversationID, items: items, state: state)
        }
    }

    /// What a chat adds to the page: its versions, and the models Try Again offers, which are the model selector's.
    private var chat: TranscriptFeed.Chat {
        guard TranscriptFeed.Chat.shown(for: state) else { return .none }
        let models = engine.modelGroups.flatMap { group in
            group.models.map { TranscriptFeed.ModelChoice(provider: $0.provider, id: $0.id, name: $0.listName, group: group.name) }
        }
        let model = state?.agent.model.map { "\($0.provider)/\($0.modelId)" } ?? ""
        return TranscriptFeed.Chat(enabled: true, versions: state?.versions ?? [], models: models, model: model)
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
    let chat: TranscriptFeed.Chat

    func makeCoordinator() -> TranscriptBridge {
        TranscriptBridge(engine: engine, conversationID: conversationID)
    }

    func makeNSView(context: Context) -> TranscriptWebKitView {
        context.coordinator.makeView(folder: folder)
    }

    func updateNSView(_ view: TranscriptWebKitView, context: Context) {
        let openWindow = context.environment.openWindow
        context.coordinator.showOutput = { id in openWindow(id: BackgroundOutputScene.id, value: id) }
        context.coordinator.show(conversationID: conversationID, items: items, state: state, inbox: inbox, names: names, chat: chat)
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
    private var chat = TranscriptFeed.Chat.none
    /// Opens the window with a background command's output, as Activity's Output does.
    var showOutput: (String) -> Void = { _ in }

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

    func show(conversationID: Int, items: [Item], state: ConversationState?, inbox: [InboxItem], names: TranscriptFeed.Names, chat: TranscriptFeed.Chat) {
        if conversationID != self.conversationID {
            self.conversationID = conversationID
            feed.restart()
        }
        self.items = items
        self.state = state
        self.inbox = inbox
        self.names = names
        self.chat = chat
        push()
    }

    private func push() {
        guard ready, let view, let names else { return }
        let palette = TranscriptPalette.colors(for: view.effectiveAppearance)
        guard let message = feed.update(items: items, state: state, inbox: inbox, names: names, palette: palette, chat: chat),
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
            guard let item = inbox.first(where: { $0.id == id && $0.kind == "approval" }) else { return }
            // A rule only where the engine offered one, for a command; the engine checks this again.
            if decision == "rule", item.tool != "bash" || item.rule == nil { return }
            engine.perform("inbox.decide", ["id": id, "decision": decision])
        case .answer(let id, let text):
            guard inbox.contains(where: { $0.id == id && $0.kind != "approval" }) else { return }
            engine.perform("inbox.answer", ["id": id, "text": text])
        case .openChat(let id, let beside):
            guard subChats.contains(id) else { return }
            engine.openConversation(id)
            if beside {
                engine.onOpenBeside(id, conversationID)
            } else {
                engine.onNavigate(id)
            }
        case .fork(let entry):
            guard items.contains(where: { $0.id == entry && $0.kind == "assistant" }) else { return }
            engine.fork(conversationID, at: entry)
        case .retry(let entry, let model):
            // Under an answer of a chat; another model only if it is one the model selector offers. The engine checks both again.
            guard chat.enabled, items.contains(where: { $0.id == entry && $0.kind == "assistant" }) else { return }
            var params: [String: Any] = ["id": conversationID, "entryId": entry]
            if let model {
                guard chat.models.contains(where: { $0.provider == model.provider && $0.id == model.modelId }) else { return }
                params["model"] = ["provider": model.provider, "modelId": model.modelId]
            }
            engine.perform("conversation.retry", params)
        case .edit(let entry, let text):
            guard chat.enabled, items.contains(where: { $0.id == entry && $0.kind == "user" }) else { return }
            engine.perform("conversation.edit", ["id": conversationID, "entryId": entry, "text": text])
        case .version(let after, let index):
            // A point the engine named, and a version it has.
            guard chat.enabled, chat.versions.contains(where: { $0.after == after && index < $0.count }) else { return }
            engine.perform("conversation.version", ["id": conversationID, "after": after.map { $0 as Any } ?? NSNull(), "index": index])
        case .picture(let entry, let index):
            guard let item = items.first(where: { $0.id == entry }), index < (item.images ?? 0) else { return }
            sendPicture(entry: entry, index: index)
        case .output(let id):
            // A command whose output pi² no longer has opens all the same: the window says so.
            guard backgroundCommands.contains(id) else { return }
            showOutput(id)
        case .save(let text, let name):
            saveFile(named: name) { url in try Data(text.utf8).write(to: url, options: .atomic) }
        case .savePicture(let entry, let index):
            guard let item = items.first(where: { $0.id == entry }), index < (item.images ?? 0) else { return }
            savePicture(entry: entry, index: index)
        case .openDocument(let entry):
            guard let file = document(entry) else { return }
            NSWorkspace.shared.open(file)
        case .saveDocument(let entry):
            guard let file = document(entry) else { return }
            saveFile(named: file.lastPathComponent) { url in
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.copyItem(at: file, to: url)
            }
        }
    }

    /// The document a `write_document` call of this conversation wrote, as its result names it, if it is still there.
    /// The page only names the call's entry, so it can open no other file.
    private func document(_ entry: Int) -> URL? {
        guard let item = items.first(where: { $0.id == entry && $0.kind == "tool" && $0.name == "write_document" }), item.isError != true,
              let path = item.details?["path"]?.stringValue, path.hasPrefix("/") else { return nil }
        let file = URL(fileURLWithPath: path)
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &folder), !folder.boolValue else {
            let alert = NSAlert()
            alert.messageText = "\(file.lastPathComponent) is no longer there"
            alert.informativeText = "It was moved or deleted after it was written: \(path)"
            alert.runModal()
            return nil
        }
        return file
    }

    /// Asks the person where to save a file, offering `name`, and writes it there. Says so if it cannot be written.
    private func saveFile(named name: String, write: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try write(url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "\(url.lastPathComponent) could not be saved"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        if let window = view?.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// Fetches one of an entry's pictures from the engine and asks the person where to save it.
    private func savePicture(entry: Int, index: Int) {
        let conversationID = conversationID
        Task { [weak self] in
            guard let self else { return }
            guard let result = try? await engine.call("conversation.image", ["id": conversationID, "entryId": entry, "index": index]),
                  let base64 = result["data"]?.stringValue, let type = result["mimeType"]?.stringValue,
                  let ending = Self.pictureEndings[type], let data = Data(base64Encoded: base64) else { return }
            saveFile(named: "Picture.\(ending)") { url in try data.write(to: url, options: .atomic) }
        }
    }

    private static let pictureEndings = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"]

    /// The background commands this conversation's rows are about, as the engine named them: the ones its calls started,
    /// read or stopped, and the ones whose end has a line of its own. Never the id an agent asked for, which may be
    /// another conversation's.
    private var backgroundCommands: Set<String> {
        var ids = Set<String>()
        for item in items {
            let id: String?
            switch (item.kind, item.name) {
            case ("tool", "bash"), ("marker", _): id = item.details?["background"]?["id"]?.stringValue
            case ("tool", "background"): id = item.details?["id"]?.stringValue
            default: id = nil
            }
            if let id { ids.insert(id) }
        }
        return ids
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
