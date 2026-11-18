import SwiftUI

// Chat mode (#172, docs/chat.md): a place to ask pi²'s own assistant questions, beside the agent view. The window shows
// one side or the other; each keeps what it showed while the other is on screen. A chat is a conversation whose library
// record says `chat: true`, made with `conversation.create` and `chat: true`; everything else uses the requests every
// conversation has. The conversation itself is `ChatView`, the same view (and page) as an agent's conversation, told it
// is a chat.

/// Which side the main window shows.
enum WindowMode: String {
    case agents
    case chat
}

/// Chat mode's own state, apart from the agent view's `AppModel.selection` and panes, so that switching keeps both.
@MainActor
@Observable
final class ChatModeState {
    private static let modeKey = "window.mode"
    private static let selectionKey = "chat.selection"

    /// The side the window shows: the agent view on first launch, afterwards the one it was last on.
    var mode: WindowMode {
        didSet { if mode != oldValue { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) } }
    }
    /// The chat on screen in chat mode. Nil shows a new chat once the engine can make one.
    var selection: Int? {
        didSet {
            guard selection != oldValue else { return }
            if let selection { UserDefaults.standard.set(selection, forKey: Self.selectionKey) } else { UserDefaults.standard.removeObject(forKey: Self.selectionKey) }
        }
    }
    /// A new chat is being made, so a second click does not make two.
    var creating = false
    /// The chat whose Continue with an Agent sheet is showing (ChatContinue.swift).
    var continuing: Int?
    /// Set while the agent view's selection is changed for it (at launch, or when its conversation went away) rather than
    /// by the person, so the window stays on the side it is on.
    @ObservationIgnored var holdingMode = false
    /// Set while a chat chosen as the agent view's selection is handed over here.
    @ObservationIgnored var redirecting = false

    init() {
        mode = WindowMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .agents
        selection = UserDefaults.standard.object(forKey: Self.selectionKey) as? Int
    }
}

// MARK: - Which conversations are chats

extension ConversationSummary {
    var isChat: Bool { chat == true }
    var isPinned: Bool { pinned == true }
}

extension ArchivedConversation {
    var isChat: Bool { chat == true }
}

extension EngineClient {
    /// The chats chat mode lists, most recently used first.
    var chats: [ConversationSummary] {
        conversations.filter(\.isChat).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Whether a conversation, listed, archived or open, is a chat.
    func isChat(_ id: Int) -> Bool {
        if let listed = conversations.first(where: { $0.id == id }) { return listed.isChat }
        if let archived = archived.first(where: { $0.id == id }) { return archived.isChat }
        return open[id]?.state?.chat == true
    }

    /// Makes a chat. The engine gives it the model chosen last in a chat, or chat mode's default model.
    func createChat() async -> Int? {
        do {
            let result = try await call("conversation.create", ["chat": true])
            guard let id = result["id"]?.intValue else { return nil }
            openConversation(id)
            return id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func pin(_ id: Int, _ pinned: Bool) {
        perform("conversation.pin", ["id": id, "pinned": pinned])
    }
}

extension AppModel {
    var mode: WindowMode {
        get { chats.mode }
        set { chats.mode = newValue }
    }

    /// The conversation the Conversation menu acts on: the chat on screen in chat mode, else the agent view's.
    var activeConversationID: Int? { mode == .chat ? chats.selection : selectedConversationID }
    var activeConversation: ConversationSummary? { engine.conversations.first { $0.id == activeConversationID } }

    /// Changes the agent view's selection without bringing the agent view on screen.
    func restoreSelection(_ value: Selection?) {
        chats.holdingMode = true
        selection = value
        chats.holdingMode = false
    }

    /// A chat chosen anywhere (the palette, Search, a fork) opens in chat mode, and the agent view keeps what it had.
    func showChat(_ id: Int) {
        engine.openConversation(id)
        chats.selection = id
        mode = .chat
    }

    /// Shows an empty chat: the one already waiting, if a new chat has not been written in yet, or a new one.
    func newChat() {
        mode = .chat
        if let waiting = engine.chats.first(where: { chat in
            guard chat.title.isEmpty, !chat.busy, let data = engine.open[chat.id], let state = data.state else { return false }
            return data.items.isEmpty && state.partial == nil && !state.busy
        }) {
            chats.selection = waiting.id
            return
        }
        guard !chats.creating else { return }
        chats.creating = true
        Task {
            defer { chats.creating = false }
            if let id = await engine.createChat() { chats.selection = id }
        }
    }

    /// Before a chat leaves the sidebar (archived or deleted): the one on screen gives way to the chat below it, or
    /// above it, as in a mail app; with none, a new chat.
    func moveOnFromChat(_ id: Int) {
        guard chats.selection == id else { return }
        let order = ChatGroups.make(engine.chats, query: "", found: []).flatMap(\.chats).map(\.id)
        guard let index = order.firstIndex(of: id) else {
            chats.selection = nil
            return
        }
        chats.selection = index + 1 < order.count ? order[index + 1] : index > 0 ? order[index - 1] : nil
    }
}

// MARK: - The switch

/// Agents and Chat, at the top of the sidebar. Each side says when something is going on in the other.
struct ModeSwitch: View {
    let model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        HStack(spacing: 2) {
            segment(.agents, "Agents", icon: "person.2", shortcut: "⌘1") {
                if model.mode == .chat {
                    if !engine.inbox.isEmpty {
                        Tag("\(engine.inbox.count)", .warn).accessibilityLabel("\(engine.inbox.count) waiting on you")
                    } else if engine.rootConversations.contains(where: \.busy) {
                        Spinner(size: 8)
                    }
                }
            }
            segment(.chat, "Chat", icon: "bubble.left.and.bubble.right", shortcut: "⌘2") {
                if model.mode == .agents, engine.chats.contains(where: \.busy) { Spinner(size: 8) }
            }
        }
        .padding(2)
        .background(Theme.window.opacity(0.6), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 6)
        .background(Theme.side)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents or Chat")
    }

    private func segment<Badge: View>(_ mode: WindowMode, _ title: String, icon: String, shortcut: String, @ViewBuilder badge: () -> Badge) -> some View {
        let on = model.mode == mode
        return Button { model.mode = mode } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title)
                badge()
            }
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Theme.tx : Theme.tx2)
            // The same height with a count or a spinner beside the name as without.
            .frame(maxWidth: .infinity, minHeight: 18)
            .padding(.vertical, 3)
            .background(on ? Theme.card2 : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(title) (\(shortcut))")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The View menu's Agents and Chat, with a tick by the one showing.
struct ModeCommands: View {
    let model: AppModel

    var body: some View {
        Toggle("Agents", isOn: Binding(get: { model.mode == .agents }, set: { if $0 { model.mode = .agents } }))
            .keyboardShortcut("1")
        Toggle("Chat", isOn: Binding(get: { model.mode == .chat }, set: { if $0 { model.mode = .chat } }))
            .keyboardShortcut("2")
    }
}

// MARK: - Sidebar

/// Chats in the sidebar: pinned ones first, then by when they were last used.
struct ChatGroups {
    struct Group: Identifiable {
        let id: String
        let title: String
        let chats: [ConversationSummary]
    }

    /// `query` keeps the chats whose title has it, or whose messages do (`found`), in one group of results.
    static func make(_ chats: [ConversationSummary], query: String, found: Set<Int>, now: Date = .now, calendar: Calendar = .current) -> [Group] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            let matches = chats.filter { $0.title.localizedCaseInsensitiveContains(needle) || found.contains($0.id) }
            return matches.isEmpty ? [] : [Group(id: "results", title: "Results", chats: matches)]
        }
        var groups: [Group] = []
        let pinned = chats.filter(\.isPinned)
        if !pinned.isEmpty { groups.append(Group(id: "pinned", title: "Pinned", chats: pinned)) }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var order: [String] = []
        var members: [String: (title: String, chats: [ConversationSummary])] = [:]
        for chat in chats where !chat.isPinned {
            let date = Date(timeIntervalSince1970: chat.updatedAt / 1000)
            let key: String, title: String
            if date >= today {
                (key, title) = ("today", "Today")
            } else if date >= yesterday {
                (key, title) = ("yesterday", "Yesterday")
            } else if date >= week {
                (key, title) = ("week", "Previous 7 Days")
            } else {
                let parts = calendar.dateComponents([.year, .month], from: date)
                key = "\(parts.year ?? 0)-\(parts.month ?? 0)"
                let sameYear = parts.year == calendar.component(.year, from: now)
                title = date.formatted(sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
            }
            if members[key] == nil { order.append(key) }
            members[key, default: (title: title, chats: [])].chats.append(chat)
        }
        for key in order {
            if let group = members[key] { groups.append(Group(id: key, title: group.title, chats: group.chats)) }
        }
        return groups
    }
}

/// Chat mode's sidebar: New Chat, a search, then the chats. No agents, folders, branches, Inbox or Activity.
struct ChatSidebar: View {
    @Bindable var model: AppModel
    @State private var query = ""
    /// Chats whose messages have the query, from the engine's search.
    @State private var found: Set<Int> = []
    @FocusState private var searching: Bool
    private var engine: EngineClient { model.engine }

    var body: some View {
        let chats = engine.chats
        let groups = ChatGroups.make(chats, query: query, found: found)
        List(selection: Binding(get: { model.chats.selection }, set: { if let id = $0 { model.chats.selection = id } })) {
            if chats.isEmpty && engine.hasLoadedLibrary {
                Text("No chats yet").font(.callout).foregroundStyle(Theme.tx3)
            } else if groups.isEmpty {
                Text("No chats match “\(query.trimmingCharacters(in: .whitespaces))”.").font(.callout).foregroundStyle(Theme.tx3)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.chats) { chat in
                        ChatRow(model: model, chat: chat).tag(chat.id)
                    }
                } header: {
                    Text(group.title).sectionLabel()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.side)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 6) {
                Button { model.newChat() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.pencil").foregroundStyle(Theme.tx2).frame(width: 20)
                        Text("New Chat")
                        Spacer(minLength: 4)
                        Text("⌘N").font(.system(size: 11)).foregroundStyle(Theme.tx3)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(.rect)
                }
                .buttonStyle(ChatSidebarButtonStyle())
                .disabled(engine.status != .connected)
                .help("Start a new chat (⌘N)")
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.tx3)
                    TextField("Search chats", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searching)
                        .onExitCommand { query = "" }
                    if !query.isEmpty {
                        Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.tx3)
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Theme.window.opacity(0.6), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searching ? Theme.acc.opacity(0.55) : Theme.line))
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
            .background(Theme.side)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter(engine: engine) }
        .toolbar {
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") { model.newChat() }
                    .disabled(engine.status != .connected)
                    .help("New chat (⌘N)")
            }
        }
        // The titles are matched here as typed; the messages are searched by the engine after a pause in typing.
        .task(id: query) {
            let needle = query.trimmingCharacters(in: .whitespaces)
            guard needle.count >= 2 else {
                found = []
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let results = await engine.search(needle)
            if !Task.isCancelled { found = Set(results.map(\.conversationId)) }
        }
    }
}

/// A chat in the sidebar, with Rename, Pin, Archive and Delete on its context menu.
private struct ChatRow: View {
    let model: AppModel
    let chat: ConversationSummary
    private var title: String { chat.title.isEmpty ? "New chat" : chat.title }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .foregroundStyle(chat.title.isEmpty ? Theme.tx2 : Theme.tx)
            Spacer(minLength: 0)
            if chat.busy { Spinner().accessibilityLabel("Answering") }
        }
        .contextMenu(previewAs: title, String(chat.id)) {
            Button("Rename…") { model.beginRename(chat) }
            Button(chat.isPinned ? "Unpin" : "Pin") { model.engine.pin(chat.id, !chat.isPinned) }
            Button("Continue with an Agent…") { model.continueWithAgent(chat.id) }
                .disabled(!model.engine.canContinueWithAgent(chat.id))
            Button("Archive") { model.archive(chat) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(chat) }
        }
    }
}

/// A row-like button at the top of the chat sidebar, lit under the pointer.
private struct ChatSidebarButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Theme.card : .clear, in: .rect(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}

// MARK: - Detail

/// How wide a chat's column is: the conversation page's text column with its padding (transcript.css, `main`).
enum ChatColumn {
    static let width: CGFloat = 816
}

/// Chat mode's side of the window: the chat on screen, with its model in the toolbar as an agent's conversation has it.
struct ChatModeDetail: View {
    let model: AppModel
    private var engine: EngineClient { model.engine }
    private var id: Int? { model.chats.selection }
    /// Nothing is on screen and the engine can make a chat: make one, so the window shows an empty chat.
    private var needsChat: Bool { id == nil && engine.status == .connected && engine.hasLoadedLibrary }

    var body: some View {
        Group {
            if let id {
                ChatView(engine: engine, id: id, chat: true)
                    .id(id)
            } else {
                Theme.window
            }
        }
        .navigationTitle(id.map { engine.conversationTitle($0, chat: true) } ?? "New chat")
        .navigationSubtitle("Chat")
        .toolbar {
            ToolbarItemGroup {
                if let id {
                    Button("Continue with an Agent…", systemImage: "arrowshape.turn.up.right") { model.continueWithAgent(id) }
                        .disabled(!engine.canContinueWithAgent(id))
                        .help("Continue with an Agent: hand this chat to one of your agents, in a folder you choose")
                    ModelMenu(engine: engine, id: id, agent: engine.open[id]?.state?.agent)
                }
            }
        }
        .sheet(isPresented: Binding(get: { model.chats.continuing != nil }, set: { if !$0 { model.chats.continuing = nil } })) {
            if let chat = model.chats.continuing { ContinueWithAgentSheet(model: model, chat: chat) }
        }
        .task(id: needsChat) { if needsChat { model.newChat() } }
        .onAppear { forgetMissing() }
        .onChange(of: engine.hasLoadedLibrary) { forgetMissing() }
        // The chat on screen was deleted other than from here (from the Archive, say): move on to the latest. One that was
        // archived stays, to be read or restored.
        .onChange(of: engine.conversations.map(\.id) + engine.archived.map(\.id)) { old, new in
            if let id, old.contains(id), !new.contains(id) { model.chats.selection = engine.chats.first?.id }
        }
    }

    /// A chat kept from last time that this data folder no longer has.
    private func forgetMissing() {
        guard engine.hasLoadedLibrary, let id, !engine.conversations.contains(where: { $0.id == id }), !engine.archived.contains(where: { $0.id == id }) else { return }
        model.chats.selection = nil
    }
}

extension EngineClient {
    /// A chat's title as the window shows it.
    func conversationTitle(_ id: Int, chat: Bool) -> String {
        let title = conversations.first { $0.id == id }?.title ?? archived.first { $0.id == id }?.title ?? open[id]?.state?.title ?? ""
        return title.isEmpty ? (chat ? "New chat" : "New conversation") : title
    }
}

// MARK: - The web switch

/// The chat's web switch, by its message field (#287): whether the assistant may search the web and read pages. A new
/// chat starts as Settings › Chat says; the switch is the chat's own and counts from its next message.
struct ChatWebSwitch: View {
    let engine: EngineClient
    let id: Int
    let on: Bool

    var body: some View {
        Button {
            engine.perform("conversation.configure", ["id": id, "web": !on])
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "globe" : "network.slash")
                Text(on ? "Web" : "Web off")
            }
            .font(.system(size: 12))
            .foregroundStyle(on ? Theme.acc : Theme.tx2)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(on ? Theme.acc.opacity(0.12) : Theme.card, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(engine.status != .connected)
        .help(on ? "The assistant can search the web and read pages in this chat. Click to turn the web off for this chat, from your next message." : "The web is off for this chat: the assistant answers from what it knows. Click to let it search the web and read pages again, from your next message.")
        .accessibilityLabel("Web")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Above a chat's message field while its web switch is off, so the person knows why an answer reads no pages.
struct ChatWebOffNote: View {
    var body: some View {
        Label("The web is off for this chat. Answers come from what the model already knows.", systemImage: "network.slash")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.tx3)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("chat-web-off")
    }
}

/// A way to begin an empty chat: what it puts in the message field.
struct ChatStarter: Identifiable {
    let icon: String
    let title: String
    /// What goes in the message field, to finish or send as it is.
    let text: String
    /// Opens the file picker as well.
    var attaches = false
    var id: String { title }

    static let all = [
        ChatStarter(icon: "lightbulb", title: "Explain something", text: "Explain in simple terms: "),
        ChatStarter(icon: "envelope", title: "Draft a message", text: "Help me write a message that "),
        ChatStarter(icon: "doc.text.magnifyingglass", title: "Summarise a file", text: "Summarise the attached file.", attaches: true),
        ChatStarter(icon: "list.bullet", title: "Make a plan", text: "Help me plan "),
    ]
}

/// A chat with nothing in it yet: the message field in the middle, with a few ways to begin.
struct ChatStart<Field: View>: View {
    let pick: (ChatStarter) -> Void
    @ViewBuilder let field: Field

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            PiMark(size: 44)
            Text("What can I help with?").font(.system(size: 22, weight: .semibold)).tracking(-0.3)
            field
            HStack(spacing: 8) {
                ForEach(ChatStarter.all) { starter in
                    Button { pick(starter) } label: {
                        Label(starter.title, systemImage: starter.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tx2)
                            .lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.card, in: .rect(cornerRadius: 8))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(starter.attaches ? "Choose a file and start a message about it" : "Start a message with “\(starter.text.trimmingCharacters(in: .whitespaces))”")
                }
            }
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: ChatColumn.width)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if PI2_DEVELOPMENT
/// What a development build was asked to open chat mode on, in `PI2_SHOW`: "chat" for chat mode on an empty chat, or
/// "chat:<number or title>" for that chat (docs/development.md). A chat's number or title alone works too, as any
/// conversation's does: a chat chosen anywhere opens in chat mode.
enum ChatLaunch {
    /// Applies `PI2_SHOW` once the library is in. True when it was about chat mode.
    @MainActor
    static func apply(_ value: String?, to model: AppModel) -> Bool {
        guard let value else { return false }
        if value == "chat" {
            model.chats.selection = nil
            model.mode = .chat
            return true
        }
        guard value.hasPrefix("chat:") else { return false }
        let asked = String(value.dropFirst("chat:".count))
        let engine = model.engine
        if let chat = engine.chats.first(where: { String($0.id) == asked || $0.title == asked }) {
            model.showChat(chat.id)
        } else if let chat = engine.archived.first(where: { $0.isChat && (String($0.id) == asked || $0.title == asked) }) {
            model.showChat(chat.id)
        } else {
            model.chats.selection = nil
            model.mode = .chat
        }
        return true
    }
}
#endif
