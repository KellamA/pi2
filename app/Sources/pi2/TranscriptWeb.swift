import AppKit
import BrowserKit
import ComputerKit
import FileLinkKit
import SwiftUI
import TranscriptKit
import WebKit

/// A conversation's transcript: one web page, so a selection can run across prose, code and tool steps and copy as
/// text; or, when the page is not in the app (a bare `swift build`), the SwiftUI transcript. See docs/transcript.md.
struct ConversationTranscript: View {
    let engine: EngineClient
    let conversationID: Int
    let items: [Item]
    /// How many entries older than `items` are still to come (#380).
    var earlier = 0
    /// Whether there are entries older than those, to ask for, and whether they are being asked for (#440).
    var older = TranscriptFeed.Older.none
    let state: ConversationState?

    var body: some View {
        if let folder = TranscriptPage.folder {
            TranscriptWebView(
                folder: folder, engine: engine, conversationID: conversationID, items: items, earlier: earlier, older: older, state: state,
                inbox: engine.inbox.filter { $0.conversationId == conversationID }, names: names, chat: chat
            )
            // The page stays hidden until it has drawn the conversation; meanwhile this shows through.
            .background { ConversationLoading(chat: state?.chat == true || engine.isChat(conversationID)) }
        } else if state == nil {
            ConversationLoading(chat: engine.isChat(conversationID))
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
        let agents = engine.allAgents.map { agent in
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
            mcp: mcp, agents: agents, apps: apps, folder: state?.agent.cwd?.hasPrefix("/") == true
        )
    }
}

/// Where the page loaded ahead for the next conversation waits, behind what the window shows (#441, `SparePage`).
struct SparePageSpot: NSViewRepresentable {
    func makeNSView(context: Context) -> SparePageHost { SparePageHost(spare: TranscriptPage.spare) }
    func updateNSView(_ view: SparePageHost, context: Context) {}
}

struct TranscriptWebView: NSViewRepresentable {
    let folder: URL
    let engine: EngineClient
    let conversationID: Int
    let items: [Item]
    let earlier: Int
    let older: TranscriptFeed.Older
    let state: ConversationState?
    let inbox: [InboxItem]
    let names: TranscriptFeed.Names
    let chat: TranscriptFeed.Chat

    func makeCoordinator() -> TranscriptBridge {
        TranscriptBridge(engine: engine, conversationID: conversationID)
    }

    func makeNSView(context: Context) -> TranscriptPane {
        TranscriptPane(page: context.coordinator.makeView(folder: folder))
    }

    func updateNSView(_ view: TranscriptPane, context: Context) {
        let openWindow = context.environment.openWindow
        context.coordinator.showOutput = { id in openWindow(id: BackgroundOutputScene.id, value: id) }
        context.coordinator.show(conversationID: conversationID, items: items, earlier: earlier, older: older, state: state, inbox: inbox, names: names, chat: chat)
    }

    static func dismantleNSView(_ view: TranscriptPane, coordinator: TranscriptBridge) {
        view.page.close()
        // A page taken from the one loaded ahead and never shown is still where it waited.
        view.page.removeFromSuperview()
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
    private var earlier = 0
    private var older = TranscriptFeed.Older.none
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
        // The page loaded ahead, which has never shown a conversation (#441); it may have said it is ready already.
        let view = TranscriptPage.spare?.take() ?? TranscriptWebKitView(folder: folder)
        view.underPageBackgroundColor = NSColor(Theme.window)
        // Hidden until the page is ready, so opening a conversation never flashes an empty page.
        view.alphaValue = 0
        view.onMessage = { [weak self] body in
            guard let action = TranscriptAction(message: body) else { return }
            self?.perform(action)
        }
        view.onReload = { [weak self] in
            self?.ready = false
            self?.hidden = true
            self?.undrawn = true
            self?.view?.alphaValue = 0
        }
        view.onAppearanceChange = { [weak self] in self?.push() }
        self.view = view
        if view.isReady { perform(.ready) }
        return view
    }

    func show(conversationID: Int, items: [Item], earlier: Int, older: TranscriptFeed.Older, state: ConversationState?, inbox: [InboxItem], names: TranscriptFeed.Names, chat: TranscriptFeed.Chat) {
        if conversationID != self.conversationID {
            self.conversationID = conversationID
            feed.restart()
            olderOnTheWay = false
            undrawn = true
        }
        self.items = items
        self.earlier = earlier
        self.older = older
        self.state = state
        self.inbox = inbox
        self.names = names
        self.chat = chat
        if hidden {
            push { [weak self] in self?.reveal() }
        } else if undrawn {
            push { [weak self] in self?.drawn() }
        } else {
            push()
        }
    }

    /// Whether the page has yet to draw this conversation since it was shown or the page loaded again.
    private var undrawn = true

    /// The page has drawn what it was sent. Once it holds the conversation, a test copy's `show` hears of it (#453).
    private func drawn() {
        guard undrawn, ready, state != nil else { return }
        undrawn = false
        #if PI2_DEVELOPMENT
        TranscriptDrawn.note(conversationID)
        #endif
    }

    /// Whether the page is still hidden: until it has loaded and drawn the conversation, which needs the conversation to
    /// have come from the engine. The loading view behind it shows meanwhile.
    private var hidden = true

    private func reveal() {
        guard hidden, state != nil else { return }
        hidden = false
        view?.alphaValue = 1
        drawn()
    }

    /// Sends the page what changed. `drawn` is called once the page has drawn it, or at once when nothing changed.
    private func push(drawn: (@MainActor () -> Void)? = nil) {
        guard ready, let view, let names else {
            drawn?()
            return
        }
        let started = PerfProbe.now()
        let palette = TranscriptPalette.colors(for: view.effectiveAppearance)
        // A long conversation goes to the page newest first, and the older entries a part at a time, each once the page
        // has drawn the one before (#380): one part on its way at a time, whatever else is sent meanwhile.
        guard let message = feed.update(items: items, earlier: earlier, older: older, state: state, inbox: inbox, names: names, palette: palette, chat: chat, withOlder: !olderOnTheWay),
              let json = TranscriptFeed.json(message) else {
            drawn?()
            return
        }
        PerfProbe.event("page update", bytes: json.utf8.count, since: started)
        var then = drawn
        if feed.pending > 0, !olderOnTheWay {
            olderOnTheWay = true
            then = { [weak self] in
                drawn?()
                self?.olderOnTheWay = false
                self?.push()
            }
        }
        let id = conversationID
        // The last of the older entries of a conversation that came newest first: time it until the page has shown it.
        if PerfProbe.active, message.older != nil, message.earlier == 0 {
            PerfProbe.opening(id, "rest to page (\(json.utf8.count / 1024) KB)")
            return send(json) {
                PerfProbe.opening(id, "rest drawn")
                then?()
            }
        }
        guard PerfProbe.active, state != nil, message.reset == true || hidden else { return send(json, then: then) }
        // The conversation going to the page, as it does when one is opened: time it until the page has shown it.
        PerfProbe.opening(id, "page \(message.items?.count ?? 0) entries (\(json.utf8.count / 1024) KB, \(Int(((PerfProbe.now() - started) * 1000).rounded()))ms to encode)")
        // With older entries still to come, it is the first part that was drawn.
        let whole = (message.earlier ?? earlier) == 0
        send(json) {
            PerfProbe.opening(id, whole ? "drawn" : "first part drawn")
            then?()
        }
    }

    /// Whether a part of the older entries is on its way to the page, which sends the next once it has drawn it.
    private var olderOnTheWay = false

    private func send(_ json: String, then done: (@MainActor () -> Void)? = nil) {
        // The JSON goes in as an argument and is parsed by the page, so nothing in it is ever run as script.
        guard let done else {
            view?.callAsyncJavaScript("window.pi2.receive(message)", arguments: ["message": json], in: nil, in: .page, completionHandler: nil)
            return
        }
        // The page draws in its next animation frame: wait for that, and a turn after it. A window nobody can see has
        // no animation frames, and the page then draws on a timer of its own, so this does not wait longer than that.
        let script = "window.pi2.receive(message); await new Promise((done) => { requestAnimationFrame(() => setTimeout(done, 0)); setTimeout(done, 200); });"
        view?.callAsyncJavaScript(script, arguments: ["message": json], in: nil, in: .page) { _ in
            MainActor.assumeIsolated { done() }
        }
    }

    private func perform(_ action: TranscriptAction) {
        switch action {
        case .ready:
            PerfProbe.opening(conversationID, "page ready")
            ready = true
            feed.restart()
            olderOnTheWay = false
            // Shown once it has drawn the conversation, so it never shows empty over the loading view.
            push { [weak self] in
                self?.reveal()
                self?.drawn()
            }
        case .older:
            // Not while this page still has older entries of the app's to come; the engine is asked only when it said
            // there is more, and one part at a time (EngineClient.loadOlder).
            guard feed.pending == 0 else { return }
            engine.loadOlder(conversationID)
        case .copy(let text):
            AppCopy.write(text, kind: .transcript, engine: engine, conversation: conversationID)
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
        case .showFile(let target):
            guard let path = filePath(target) else { return }
            showFile(path)
        case .fileMenu(let target, let code):
            view?.fileMenuItems = nil
            guard let target, let path = filePath(target) else { return }
            fileMenu(path, code: code)
        }
    }

    // MARK: Files on this Mac (#451)

    /// The absolute path a file link names: relative ones in this conversation's folder.
    private func filePath(_ target: String) -> String? {
        FileLink.path(of: target, folder: state?.agent.cwd, home: NSHomeDirectory())
    }

    /// Shows the file in Finder, selected in its folder, or opens the folder; or says in the page that it is not there.
    /// The path is made whole first. In a test copy, writes down what it would have shown instead.
    private func showFile(_ path: String) {
        let resolution = FileLink.resolve(path)
        switch FileLink.show(resolution, home: NSHomeDirectory()) {
        case .reveal(let whole):
            if record("show", whole) { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: whole)])
        case .openFolder(let whole):
            if record("showFolder", whole) { return }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: whole)
        case .notice(let text):
            _ = record("notice", resolution.path, ["notice": text])
            sendNotice(text)
        }
    }

    /// Gives the view the items for the menu it is about to show. Each looks at the file again when chosen, since it may
    /// have changed while the menu was open.
    private func fileMenu(_ path: String, code: Bool) {
        let items = FileLink.menu(FileLink.resolve(path), code: code)
        _ = record("menu", path, ["items": items.map(\.rawValue)], act: false)
        guard !items.isEmpty else { return }
        view?.fileMenuItems = (items.map { item in (item.rawValue, { [weak self] in self?.choose(item, path) }) }, Date())
    }

    private func choose(_ item: FileLink.MenuItem, _ path: String) {
        switch item {
        case .showInFinder:
            showFile(path)
        case .open:
            let resolution = FileLink.resolve(path)
            guard case .found(let whole, let kind) = resolution else {
                if let text = FileLink.notice(resolution, home: NSHomeDirectory()) { sendNotice(text) }
                return
            }
            guard FileLink.mayOpen(whole, kind: kind), !record("open", whole) else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: whole))
        case .copyPath:
            let whole = FileLink.resolve(path).path
            _ = record("copyPath", whole, act: false)
            AppCopy.write(whole, kind: .filePath, engine: engine, conversation: conversationID)
        }
    }

    /// In a test copy, writes down what a file link did or would have done, and says whether that stands in for doing
    /// it: a test copy never puts a Finder window or another app on the person's screen, nor changes their pasteboard.
    private func record(_ action: String, _ path: String, _ more: [String: Any] = [:], act: Bool = true) -> Bool {
        guard let file = TestCopyRecord.fileLinks(engine: engine) else { return false }
        TestCopyRecord.append(more.merging(["action": action, "path": path, "conversation": conversationID]) { $1 }, to: file)
        return act
    }

    /// A short line at the foot of the page.
    private func sendNotice(_ text: String) {
        guard let json = try? JSONSerialization.data(withJSONObject: ["notice": text]), let message = String(data: json, encoding: .utf8) else { return }
        send(message)
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
        FilePanels.beginSave("transcript-file", in: view?.window, configure: { panel in
            panel.nameFieldStringValue = name
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
        }) { url in
            guard let url else { return }
            do {
                try write(url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "\(url.lastPathComponent) could not be saved"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
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
