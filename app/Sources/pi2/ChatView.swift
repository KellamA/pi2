import ComputerKit
import SwiftUI

struct ChatView: View {
    let engine: EngineClient
    let id: Int

    @State private var draft = ""
    @State private var steer = true
    /// Pictures and files waiting to go with the draft.
    @State private var attachments = ComposerAttachments()
    @State private var dropTargeted = false
    @FocusState private var composerFocused: Bool

    private var data: ConversationData { engine.open[id] ?? ConversationData() }
    private var state: ConversationState? { data.state }
    private var busy: Bool { state?.busy ?? false }
    private var summary: ConversationSummary? { engine.conversations.first { $0.id == id } }
    private var parent: ConversationSummary? { summary?.parent.flatMap { parent in engine.conversations.first { $0.id == parent } } }
    private var title: String {
        let title = summary?.title ?? ""
        return title.isEmpty ? "New conversation" : title
    }
    private var subtitle: String {
        let agent = engine.agent(state?.agent.agentId)?.name ?? ""
        guard let parent else { return agent }
        return "\(agent) · sub-chat of “\(parent.title.isEmpty ? "New conversation" : parent.title)”"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let state, data.items.isEmpty, !busy, state.partial == nil {
                AgentIntro(engine: engine, agent: state.agent, isSubChat: parent != nil, projectInstructions: state.projectInstructions)
            } else {
                ConversationTranscript(engine: engine, conversationID: id, items: data.items, state: state)
            }
            // A subagent of this conversation is waiting on the person.
            ForEach(engine.inbox.filter { $0.rootConversationId == id && $0.conversationId != id }) { item in
                InboxCard(engine: engine, item: item, showsSource: true)
                    .padding(.horizontal, 28).padding(.top, 8)
            }
            if state?.compacting == true {
                banner("Summarising earlier messages to free up context…", systemImage: "arrow.down.right.and.arrow.up.left", color: Theme.acc)
            }
            if let error = state?.compactionError, state?.compacting != true {
                banner("The last attempt to summarise the conversation failed: \(error)", systemImage: "exclamationmark.triangle", color: Theme.warn)
            }
            if let retry = state?.retry {
                banner("The request failed and will be retried: \(retry.error)", systemImage: "arrow.clockwise", color: Theme.warn)
            }
            if let failure = state?.failure, !busy {
                let stopped = failure.reason == "aborted"
                HStack(spacing: 10) {
                    Image(systemName: stopped ? "stop.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(stopped ? Theme.tx2 : Theme.bad)
                    Text(failure.message).foregroundStyle(stopped ? Theme.tx2 : Theme.tx).lineLimit(3)
                    Spacer()
                    if failure.reason != "nothing_to_answer" {
                        Button("Continue", systemImage: "play.fill") { engine.perform("continue", ["id": id]) }
                            .buttonStyle(.piSecondary)
                            .help("Resume the run from where it stopped, without typing a new message")
                    }
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .panel(fill: stopped ? Theme.panel : Theme.bad.opacity(0.08), border: stopped ? Theme.line : Theme.bad.opacity(0.35))
                .padding(.horizontal, 28).padding(.top, 8)
            }
            PlanStrip(engine: engine, id: id, state: state)
            queue
            composer
        }
        .background(Theme.window)
        // Files and pictures dropped anywhere on the conversation are attached to the draft.
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            attachments.add(dropped: providers)
            composerFocused = true
            return true
        }
        .overlay { if dropTargeted { DropHighlight() } }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                if let parent {
                    Button("Parent Chat", systemImage: "arrow.turn.left.up") { engine.onNavigate(parent.id) }
                        .labelStyle(.titleAndIcon)
                        .help("Go to the conversation whose agent opened this sub-chat")
                }
                if engine.agent(state?.agent.agentId)?.browser?.enabled == true { BrowserButton(engine: engine, conversationID: id) }
                ContextMeter(engine: engine, id: id, state: state)
                ModelMenu(engine: engine, id: id, agent: state?.agent)
                ToolsMenu(engine: engine, id: id, agent: state?.agent)
            }
        }
        .onAppear {
            engine.openConversation(id)
            composerFocused = true
        }
    }

    private func banner(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12.5))
            .foregroundStyle(color)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .panel(fill: color.opacity(0.08), border: color.opacity(0.3))
            .padding(.horizontal, 28).padding(.top, 8)
    }

    @ViewBuilder
    private var queue: some View {
        if let queued = state?.queued, !queued.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(queued) { item in
                        HStack(spacing: 6) {
                            Text(item.mode == "steer" ? "Steering" : "Queued").foregroundStyle(Theme.tx3)
                            Text(item.summary).lineLimit(1).frame(maxWidth: 260, alignment: .leading)
                            Button("Remove", systemImage: "xmark") {
                                engine.perform("withdraw", ["submissionId": item.id])
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.tx3)
                            .help("Remove this message before it is sent to the model")
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .panel(radius: 8, fill: Theme.card, border: Theme.line2)
                    }
                }
                .padding(.horizontal, 28)
            }
            .padding(.top, 8)
        }
    }

    private var agentName: String { engine.agent(state?.agent.agentId)?.name ?? "the agent" }

    private var placeholder: String {
        if busy { return steer ? "Steer \(agentName) while it works…" : "Queue a follow-up for \(agentName)…" }
        return parent == nil ? "Message \(agentName)…" : "Message \(agentName) directly…"
    }

    /// The conversation's model, when it is known not to take pictures.
    private var blindModel: String? {
        guard let ref = state?.agent.model, let model = engine.allModels.first(where: { $0.ref == ref }), model.vision == false else { return nil }
        return model.name
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            AttachmentStrip(attachments: attachments, blindModel: blindModel)
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(1...10)
                .focused($composerFocused)
                .onSubmit(send)
                .accessibilityIdentifier("composer")
                .padding(.horizontal, 2).padding(.top, 2)
                // ⌘V with a picture, files or a very long text on the pasteboard attaches them.
                .background(PasteCatcher(active: composerFocused, dragging: dropTargeted) { attachments.paste() })
            HStack(spacing: 8) {
                Button("Attach", systemImage: "paperclip") {
                    attachments.chooseFiles()
                    composerFocused = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.tx2)
                .help("Attach pictures or files. You can also paste them, or drop them on the conversation.")
                .accessibilityLabel("Attach Files")
                if let agent = engine.agent(state?.agent.agentId) {
                    HStack(spacing: 6) {
                        AgentAvatar(agent: agent, size: 16)
                        Text(agent.name).foregroundStyle(Theme.tx2)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.card, in: .rect(cornerRadius: 7))
                    .help("You are talking to \(agent.name)")
                }
                Spacer()
                if busy {
                    SteerQueuePicker(steer: $steer)
                    Button("Stop", systemImage: "stop.fill") { engine.perform("abort", ["id": id]) }
                        .buttonStyle(.piDanger)
                        .help("Stop the run and everything it started (⌘.)")
                }
                Button { send() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.onAcc)
                        .frame(width: 28, height: 28)
                        .background(Theme.acc, in: .circle)
                }
                .buttonStyle(.plain)
                .opacity(canSend ? 1 : 0.35)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return)")
                .accessibilityLabel("Send")
            }
        }
        .padding(12)
        .panel(radius: 14, border: composerFocused ? Theme.acc.opacity(0.55) : Theme.line2)
        .animation(.easeOut(duration: 0.15), value: composerFocused)
        .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 18)
    }

    private var canSend: Bool {
        // Attachments can be the whole message. One still being read, or one the model cannot take, holds it back.
        let hasContent = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.ready.isEmpty
        return engine.status == .connected && hasContent && !attachments.isReading && attachments.problem(blindModel: blindModel) == nil
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        let carried = attachments.takeReady()
        let steering = busy && steer
        draft = ""
        Task {
            // A refused message goes back in the box, with what it carried, rather than being lost.
            if await !engine.submit(text, attachments: carried.compactMap(\.payload), to: id, steer: steering) {
                if draft.isEmpty { draft = text }
                attachments.restore(carried)
            }
        }
    }
}

// MARK: - Toolbar menus

/// How full the context is and what this conversation has cost, with the ways to make room.
struct ContextMeter: View {
    let engine: EngineClient
    let id: Int
    let state: ConversationState?
    @State private var resetting = false
    @State private var note = ""

    private var lastAnswer: Item? { engine.open[id]?.items.last { $0.kind == "assistant" && $0.stop == "stop" } }

    var body: some View {
        Menu {
            if let context = state?.context {
                Text(context.window.map { "Context: \(Formats.tokens(context.used)) of \(Formats.tokens($0)) tokens" } ?? "Context: \(Formats.tokens(context.used)) tokens")
            }
            if let usage = state?.usage {
                Text("This conversation: \(Formats.usage(tokens: usage.tokens, cost: usage.cost))")
            }
            Divider()
            Button("Summarise Earlier Messages") { engine.perform("conversation.compact", ["id": id]) }
                .disabled(state?.compacting == true)
            Button("Start Fresh Context…") { resetting = true }
            Button("Fork From Last Answer") { if let lastAnswer { engine.fork(id, at: lastAnswer.id) } }
                .disabled(lastAnswer == nil)
        } label: {
            Label(label, systemImage: "gauge.with.dots.needle.33percent")
                .labelStyle(.titleAndIcon)
        }
        .help("How full the model's context is. Earlier messages are summarised automatically when it fills up.")
        .alert("Start a fresh context?", isPresented: $resetting) {
            TextField("Note to carry over (optional)", text: $note)
            Button("Start Fresh") {
                engine.perform("conversation.reset", ["id": id, "note": note])
                note = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model stops seeing earlier messages. They stay in the conversation for you.")
        }
    }

    private var label: String {
        if let fraction = state?.context.fraction { return "\(Int((fraction * 100).rounded()))%" }
        return Formats.tokens(state?.context.used ?? 0)
    }
}

struct ModelMenu: View {
    let engine: EngineClient
    let id: Int
    let agent: AgentInfo?

    private var current: ModelInfo? {
        guard let ref = agent?.model else { return nil }
        return engine.allModels.first { $0.ref == ref }
    }

    private var groups: [(provider: String, name: String, models: [ModelInfo])] {
        Dictionary(grouping: engine.models, by: \.provider)
            .map { (provider: $0.key, name: $0.value[0].providerName, models: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Menu {
            ForEach(groups, id: \.provider) { group in
                if group.models.count > 12 {
                    Menu(group.name) { modelButtons(group.models) }
                } else {
                    Section(group.name) { modelButtons(group.models) }
                }
            }
            Divider()
            SettingsLink { Text("Connect More Providers…") }
        } label: {
            Label(current?.name ?? agent?.model?.modelId ?? "Model", systemImage: "cpu")
                .labelStyle(.titleAndIcon)
        }
        .help(current == nil && agent?.model != nil ? "This model's provider is not connected. Pick another model or connect it in Settings." : "Model for this conversation")

        if let current, !current.thinkingLevels.isEmpty {
            Menu {
                Picker("Thinking", selection: Binding(
                    get: { agent?.thinkingLevel ?? "" },
                    set: { engine.configure(id, ["thinkingLevel": $0]) }
                )) {
                    ForEach(current.thinkingLevels, id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(agent?.thinkingLevel.map { "Thinking: \($0.capitalized)" } ?? "Thinking", systemImage: "brain")
                    .labelStyle(.titleAndIcon)
            }
            .help("How much the model reasons before answering")
        }
    }

    @ViewBuilder
    private func modelButtons(_ models: [ModelInfo]) -> some View {
        ForEach(models) { model in
            Button {
                engine.configure(id, ["model": ["provider": model.provider, "modelId": model.id]])
            } label: {
                if model.ref == agent?.model {
                    Label(model.name, systemImage: "checkmark")
                } else {
                    Text(model.name)
                }
            }
        }
    }
}

struct ToolsMenu: View {
    let engine: EngineClient
    let id: Int
    let agent: AgentInfo?

    private var access: String { agent?.access ?? "none" }
    private var folderName: String? { agent?.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } }
    /// Whether this conversation's agent may use apps on this Mac, which is set on the agent, not here.
    private var usesComputer: Bool { engine.agent(agent?.agentId)?.computer?.enabled == true }

    var body: some View {
        Menu {
            Picker("Tool access", selection: Binding(get: { access }, set: { engine.setAccess($0, for: id) })) {
                ForEach(AccessLevel.all, id: \.id) { level in
                    Text("\(level.title) — \(level.detail)").tag(level.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            if let cwd = agent?.cwd {
                Text("Folder: \(cwd)")
            }
            Button("Choose Folder…") { engine.chooseFolder(for: id) }
        } label: {
            Label(label, systemImage: access == "none" ? "wrench.and.screwdriver" : "wrench.and.screwdriver.fill")
                .labelStyle(.titleAndIcon)
        }
        .help("What the agent may do on this Mac in this conversation")
    }

    private var label: String {
        switch access {
        case "read": "Read · \(folderName ?? "scratch folder")"
        case "ask": "Ask first · \(folderName ?? "scratch folder")"
        case "full": "Full · \(folderName ?? "scratch folder")"
        default: usesComputer ? "Computer use" : engine.agent(agent?.agentId)?.browser?.enabled == true ? "Browser" : "Tools off"
        }
    }

}

extension EngineClient {
    /// Tools always work inside a folder the person chose, never the home folder by default.
    func setAccess(_ value: String, for id: Int) {
        var change: [String: Any] = ["access": value]
        if value != "none", open[id]?.state?.agent.cwd == nil {
            guard let folder = Self.chooseFolder() else { return }
            change["cwd"] = folder
        }
        configure(id, change)
    }

    func chooseFolder(for id: Int) {
        if let folder = Self.chooseFolder() { configure(id, ["cwd": folder]) }
    }

    static func pickFolder() -> String? { chooseFolder() }

    /// Files and folders for an agent to keep at hand.
    static func pickReferenceFiles() -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose files or folders this agent can always read."
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }

    private static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder this conversation's tools work in."
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    let engine: EngineClient
    let conversationID: Int
    let items: [Item]
    let state: ConversationState?

    private var results: [String: Item] {
        Dictionary(items.filter { $0.kind == "tool" }.compactMap { item in item.callId.map { ($0, item) } }, uniquingKeysWith: { _, last in last })
    }
    private var live: [String: LiveTool] {
        Dictionary((state?.tools ?? []).map { ($0.callId, $0) }, uniquingKeysWith: { _, last in last })
    }

    @State private var pinnedToBottom = true

    /// Changes whenever the transcript grows: a new entry, more streamed text, or more tool output.
    private var growth: Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        hasher.combine(state?.partial?.text.count)
        hasher.combine(state?.partial?.thinking.count)
        for tool in state?.tools ?? [] { hasher.combine(tool.output.count) }
        hasher.combine(state?.busy)
        return hasher.finalize()
    }

    var body: some View {
        let results = results
        let live = live
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(items.filter { $0.kind != "tool" }) { item in
                    switch item.kind {
                    case "user":
                        HStack {
                            Spacer(minLength: 120)
                            VStack(alignment: .trailing, spacing: 6) {
                                SentAttachments(engine: engine, conversationID: conversationID, item: item)
                                // A message can be attachments alone.
                                if !item.text.isEmpty {
                                    Text(item.text)
                                        .textSelection(.enabled)
                                        .lineSpacing(2)
                                        .padding(.horizontal, 13).padding(.vertical, 9)
                                        .background(Theme.card2, in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14, style: .continuous))
                                }
                            }
                        }
                    case "assistant":
                        AssistantRow(engine: engine, conversationID: conversationID, item: item, results: results, live: live, running: state?.busy ?? false)
                            .contextMenu {
                                Button("Fork From Here") { engine.fork(conversationID, at: item.id) }
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.text, forType: .string)
                                }
                            }
                    default:
                        HStack(spacing: 10) {
                            Rectangle().fill(Theme.line).frame(height: 1)
                            Text(item.text).font(.system(size: 11)).foregroundStyle(Theme.tx3).fixedSize()
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                    }
                }
                if let partial = state?.partial {
                    VStack(alignment: .leading, spacing: 8) {
                        if !partial.thinking.isEmpty { ThinkingView(text: partial.thinking, streaming: partial.text.isEmpty) }
                        if !partial.text.isEmpty { MessageText(text: partial.text, streaming: true) }
                        ForEach(partial.toolCalls) { call in
                            HStack(spacing: 8) {
                                Spinner()
                                Text("Preparing \(call.name)…").foregroundStyle(Theme.tx2)
                            }
                            .font(.system(size: 12.5))
                        }
                        if partial.text.isEmpty && partial.thinking.isEmpty && partial.toolCalls.isEmpty { ThinkingDots() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if state?.busy == true, state?.tools.isEmpty ?? true, state?.retry == nil {
                    ThinkingDots()
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
            Color.clear.frame(height: 1).id("bottom")
        }
        .defaultScrollAnchor(.bottom)
        // Follow new content only while the reader is at the bottom; scrolling up to read stays put.
        .onScrollGeometryChange(for: ScrollSnapshot.self) { geometry in
            ScrollSnapshot(
                atBottom: geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60,
                contentHeight: geometry.contentSize.height,
                viewHeight: geometry.containerSize.height
            )
        } action: { old, new in
            // Only the reader's own scrolling changes the pin; content growing or the view resizing does not.
            if old.contentHeight == new.contentHeight && old.viewHeight == new.viewHeight {
                pinnedToBottom = new.atBottom
            } else if pinnedToBottom && old.viewHeight != new.viewHeight {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .onChange(of: growth) {
            if pinnedToBottom { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        // Sending a message always brings the reader back to it.
        .onChange(of: items.last { $0.kind == "user" }?.id) {
            pinnedToBottom = true
            proxy.scrollTo("bottom", anchor: .bottom)
            // Once more after layout: a transcript that has just loaded has not measured its rows yet.
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        }
    }
}

private struct ScrollSnapshot: Equatable {
    let atBottom: Bool
    let contentHeight: CGFloat
    let viewHeight: CGFloat
}

struct AssistantRow: View {
    let engine: EngineClient
    let conversationID: Int
    let item: Item
    let results: [String: Item]
    let live: [String: LiveTool]
    let running: Bool

    private var interrupted: Bool { item.stop == "aborted" || item.stop == "error" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if interrupted {
                Label(item.stop == "error" ? "This attempt failed" : "Interrupted — kept in the transcript", systemImage: "bolt.slash")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.warn)
            }
            if let thinking = item.thinking, !thinking.isEmpty { ThinkingView(text: thinking, streaming: false) }
            if !item.text.isEmpty {
                MessageText(text: item.text)
                    .foregroundStyle(interrupted ? Theme.tx2 : Theme.tx)
            }
            if let error = item.error, !error.isEmpty {
                Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.bad).textSelection(.enabled)
            }
            ForEach(item.toolCalls ?? []) { call in
                ToolCard(engine: engine, conversationID: conversationID, call: call, result: results[call.callId], live: live[call.callId], running: running)
            }
            if item.stop == "length" {
                Text("The answer was cut off at the model's output limit.").font(.system(size: 11.5)).foregroundStyle(Theme.tx3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ThinkingView: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.system(size: 12.5)).foregroundStyle(Theme.tx2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.acc.opacity(0.4)).frame(width: 2) }
                .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                if streaming { Spinner() } else { Image(systemName: "sparkle").foregroundStyle(Theme.acc) }
                Text(streaming ? "Thinking…" : "Thought").foregroundStyle(Theme.tx2)
            }
            .font(.system(size: 12.5))
        }
    }
}

struct ToolCard: View {
    let engine: EngineClient
    let conversationID: Int
    let call: ToolCall
    let result: Item?
    let live: LiveTool?
    /// Whether the conversation has a run going; a call without a result is only "running" while it does.
    let running: Bool
    @State private var expandedChoice: Bool?

    /// The approval or question this call is waiting on, if any.
    private var pending: InboxItem? {
        engine.inbox.first { $0.conversationId == conversationID && $0.callId == call.callId }
    }
    /// For a delegation: the subagent's conversation and name, once the call has created it.
    private var subagent: (id: Int, name: String)? {
        guard let details = result?.details ?? live?.details, let id = details["conversationId"]?.intValue else { return nil }
        return (id, details["agentName"]?.stringValue ?? "Subagent")
    }

    private var isRunning: Bool { result == nil && running }
    private var isError: Bool { result?.isError ?? false }
    private var output: String { Self.readable(result?.text ?? live?.output ?? "") }

    /// pi durable wraps the results it writes itself (refused, blocked, interrupted) in a tag meant for the model.
    private static func readable(_ text: String) -> String {
        // The tag can be the whole result (a refusal) or follow the tool's own output (a command that exited non-zero).
        var result = text
        while let open = result.range(of: "<harness>"), let close = result.range(of: "</harness>", range: open.upperBound..<result.endIndex) {
            let note = result[open.upperBound..<close.lowerBound]
                .split(separator: "\n")
                .map { $0.replacingOccurrences(of: #"^\[(error|warning|info)\] "#, with: "", options: .regularExpression) }
                .joined(separator: "\n")
            result.replaceSubrange(open.lowerBound..<close.upperBound, with: note)
        }
        return result.trimmingCharacters(in: .newlines)
    }
    private var expanded: Bool { expandedChoice ?? (isRunning || isError) }

    private var title: String {
        switch call.name {
        case "delegate":
            // A call that continues a sub-chat may name only its number, so fall back to that chat's agent.
            let named = call.arguments["agent"]?.stringValue ?? ""
            let name = named.isEmpty ? (subagent?.name ?? "agent") : named
            return call.arguments["chat"]?.intValue == nil ? "Delegate to \(name)" : "Continue with \(name)"
        case "ask_user": return "Question"
        case "read_reference": return "Read reference file"
        case "codemode": return "Script"
        case "browser": return "Browser"
        default:
            // An MCP tool reads as "Server: tool" rather than its long internal name.
            if let server = engine.mcpServers.first(where: { $0.tools.contains { $0.toolName == call.name } }),
               let tool = server.tools.first(where: { $0.toolName == call.name }) {
                return "\(server.name): \(tool.name)"
            }
            return call.name
        }
    }

    private var icon: String {
        switch call.name {
        case "bash": "terminal"
        case "read": "doc.text"
        case "write", "edit": "pencil"
        case "delegate": "person.2"
        case "ask_user": "questionmark.bubble"
        case "codemode": "chevron.left.forwardslash.chevron.right"
        case "browser": "globe"
        default: call.name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "hammer"
        }
    }

    /// The short name on the card's tag.
    private var tagText: String {
        switch call.name {
        case "ask_user": "question"
        case "read_reference": "reference"
        case "codemode": "script"
        default:
            if let server = engine.mcpServers.first(where: { $0.tools.contains { $0.toolName == call.name } }) {
                server.name
            } else {
                call.name
            }
        }
    }

    private var tone: Tag.Tone {
        if pending != nil { return .warn }
        if isRunning { return .acc }
        if result == nil { return .neutral }
        return isError ? .bad : .ok
    }

    /// The detail shown after the tag; for an MCP tool, which of the server's tools it was.
    private var detail: String {
        if call.name == "computer" {
            // The app says what it did ("Clicked “Send” in Mail"); until then, what was asked.
            if let summary = (result?.details ?? live?.details)?["summary"]?.stringValue { return summary }
            let action = (call.arguments["action"]?.stringValue ?? "").replacingOccurrences(of: "_", with: " ")
            return call.arguments["app"]?.stringValue.map { "\(action) · \(ComputerController.name(of: $0))" } ?? action
        }
        if call.name == "browser" { return BrowserSession.line(for: call, details: result?.details ?? live?.details) }
        if call.name.hasPrefix("mcp__"), title.contains(": ") {
            let tool = title.components(separatedBy: ": ").last ?? ""
            return call.summary.isEmpty ? tool : "\(tool) \(call.summary)"
        }
        return call.summary
    }

    var body: some View {
        if let pending {
            // Waiting on the person: the approval or question is the whole card.
            InboxCard(engine: engine, item: pending, showsSource: false)
        } else if call.name == "delegate" {
            SubagentCard(engine: engine, call: call, subagent: subagent, title: title, output: output, isRunning: isRunning, isError: isError, finished: result != nil)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expandedChoice = !expanded }
            } label: {
                HStack(spacing: 8) {
                    Tag(tagText, tone)
                    Text(detail)
                        .font(call.name == "computer" || call.name == "browser" ? .system(size: 12.5) : Theme.mono)
                        .foregroundStyle(Theme.tx)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isRunning {
                        Spinner()
                    } else if result == nil {
                        Text("no result").font(.system(size: 11)).foregroundStyle(Theme.tx3)
                    } else if isError {
                        Text("failed").font(.system(size: 11)).foregroundStyle(Theme.bad)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tx3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityLabel("\(title) \(call.summary)")

            if expanded {
                Rectangle().fill(Theme.line).frame(height: 1)
                if let result, (result.images ?? 0) > 0 {
                    ScreenshotView(engine: engine, conversationID: conversationID, entryID: result.id)
                        .padding(.horizontal, 11).padding(.top, 9)
                }
                ScrollView {
                    Text(output.isEmpty ? (isRunning ? "Running…" : "(no output)") : output)
                        .font(Theme.mono)
                        .foregroundStyle(isError ? Theme.bad : Theme.tx2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                }
                .frame(maxHeight: 260)
                .defaultScrollAnchor(.bottom)
            }
        }
        .panel()
    }
}

/// A delegation: the subagent as a character in the conversation, with its model, what it was asked, and a way in.
struct SubagentCard: View {
    let engine: EngineClient
    let call: ToolCall
    let subagent: (id: Int, name: String)?
    let title: String
    let output: String
    let isRunning: Bool
    let isError: Bool
    let finished: Bool
    @State private var expanded = false

    private var profile: AgentProfile? {
        let name = subagent?.name ?? call.arguments["agent"]?.stringValue ?? ""
        return engine.agents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id == name }
    }
    private var task: String { call.arguments["task"]?.stringValue ?? "" }
    /// The answer without the footer the engine adds for the model.
    private var answer: String {
        output.components(separatedBy: "\n\n(Sub-chat ").first ?? output
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentAvatar(agent: profile, size: 20)
                Text(profile?.name ?? subagent?.name ?? "Subagent").font(.system(size: 13, weight: .semibold))
                Tag(call.arguments["chat"]?.intValue == nil ? "subagent · \(engine.shortModelName(profile?.model))" : "continued · \(engine.shortModelName(profile?.model))")
                Spacer(minLength: 6)
                if isRunning {
                    Spinner()
                    Text("working").font(.system(size: 11.5)).foregroundStyle(Theme.tx2)
                } else if isError {
                    Text("did not finish").font(.system(size: 11.5)).foregroundStyle(Theme.bad)
                } else if finished {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ok)
                        .accessibilityLabel("Finished")
                }
                if let subagent {
                    Button {
                        engine.openConversation(subagent.id)
                        engine.onNavigate(subagent.id)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.acc)
                    .help("Open \(subagent.name)’s sub-chat")
                    .accessibilityLabel("Open \(subagent.name)’s Sub-chat")
                }
            }
            if !task.isEmpty {
                Text(inlineMarkdown(task)).foregroundStyle(Theme.tx2).lineLimit(expanded ? nil : 2)
            }
            if finished, !answer.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(Theme.tx3)
                        // Folded, the answer reads as one run of text; opened, it keeps its own lines.
                        Text(inlineMarkdown(expanded ? answer : answer.replacingOccurrences(of: #"\s*\n+\s*"#, with: " ", options: .regularExpression)))
                            .foregroundStyle(isError ? Theme.bad : Theme.tx)
                            .lineLimit(expanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Show less" : "Show the whole answer")
                .textSelection(.enabled)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.panel)
        .overlay(alignment: .leading) { Rectangle().fill(AgentColor.color(profile?.color)).frame(width: 3) }
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Assistant text: inline Markdown, with fenced code blocks set apart.
struct MessageText: View {
    let text: String
    /// Whether more text is still arriving; shows the caret at the end.
    var streaming = false

    private var segments: [(code: Bool, text: String)] {
        var result: [(Bool, String)] = []
        for (index, part) in text.components(separatedBy: "```").enumerated() {
            if index.isMultiple(of: 2) {
                let trimmed = part.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty { result.append((false, trimmed)) }
            } else {
                // Drop the language tag on the fence line.
                let body = part.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let code = body.count == 2 ? String(body[1]) : part
                result.append((true, code.trimmingCharacters(in: .newlines)))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if segment.code {
                    Text(segment.text)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.tx)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .panel(radius: 8)
                } else if streaming, index == segments.count - 1 {
                    // The caret sits at the end of the words still arriving, as part of the line.
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                        (Text(markdown(segment.text)) + Text(" ▍").foregroundColor(on ? Theme.acc : .clear))
                            .lineSpacing(3.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(markdown(segment.text))
                        .textSelection(.enabled)
                        .lineSpacing(3.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Nothing to attach it to yet (or a code block is still arriving): the caret stands alone.
            if streaming, segments.last?.code ?? true { Caret() }
        }
    }

    private func markdown(_ source: String) -> AttributedString { inlineMarkdown(source) }
}

/// Bold, italics, code and links, with line breaks kept; block Markdown is left as typed.
func inlineMarkdown(_ source: String) -> AttributedString {
    (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
}

/// Steer or queue, as two segments in the accent style.
struct SteerQueuePicker: View {
    @Binding var steer: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment("Steer", on: steer) { steer = true }
            Rectangle().fill(Theme.line2).frame(width: 1)
            segment("Queue", on: !steer) { steer = false }
        }
        .fixedSize()
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line2))
        .clipShape(.rect(cornerRadius: 7))
        .help("Steer: the message joins the current work after its next step. Queue: it starts a new run when this one answers.")
    }

    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.acc : Theme.tx2)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(on ? Theme.acc.opacity(0.14) : .clear)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// An empty conversation: who you are talking to and what they can do, before the first message.
struct AgentIntro: View {
    let engine: EngineClient
    let agent: AgentInfo
    let isSubChat: Bool
    var projectInstructions: String?

    private var profile: AgentProfile? { engine.agent(agent.agentId) }
    private var folder: String? { agent.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } }

    private var facts: [(icon: String, text: String)] {
        var facts: [(String, String)] = []
        facts.append(("cpu", engine.allModels.first { $0.ref == agent.model }?.name ?? agent.model?.modelId ?? "App default model"))
        switch agent.access {
        case "read": facts.append(("doc.text.magnifyingglass", "Can read files in \(folder ?? "its scratch folder")"))
        case "ask": facts.append(("hand.raised", "Asks before changing anything in \(folder ?? "its scratch folder")"))
        case "full": facts.append(("bolt", "Full access to \(folder ?? "its scratch folder")"))
        default: facts.append(("bubble.left", "Tools off: it can talk, not act"))
        }
        let delegates = (profile?.delegates ?? []).compactMap { engine.agent($0)?.name }
        if !delegates.isEmpty, !isSubChat { facts.append(("person.2", "Can hand work to \(ListFormatter.localizedString(byJoining: delegates))")) }
        if let projectInstructions { facts.append(("text.badge.checkmark", "Follows the \(projectInstructions) in \(folder ?? "its folder")")) }
        if let files = profile?.files, !files.isEmpty { facts.append(("books.vertical", "\(files.count) reference file\(files.count == 1 ? "" : "s") at hand")) }
        if let computer = profile?.computer, computer.enabled {
            let apps = computer.apps.map(ComputerController.name(of:))
            facts.append(("macwindow.on.rectangle", apps.isEmpty ? "Computer use is on, with no apps chosen yet" : "Can use \(ListFormatter.localizedString(byJoining: apps)) on this Mac"))
        }
        if profile?.browser?.enabled == true { facts.append(("globe", "Can browse the web in pi²’s own browser")) }
        return facts
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            AgentAvatar(agent: profile, size: 52)
                .shadow(color: AgentColor.color(profile?.color).opacity(0.45), radius: 18, y: 4)
            VStack(spacing: 4) {
                Text(profile?.name ?? "New conversation").font(.system(size: 20, weight: .semibold)).tracking(-0.2)
                if let description = profile?.description, !description.isEmpty {
                    Text(description).foregroundStyle(Theme.tx2).multilineTextAlignment(.center)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(facts, id: \.text) { fact in
                    HStack(spacing: 9) {
                        Image(systemName: fact.icon).foregroundStyle(Theme.acc).frame(width: 16)
                        Text(fact.text).foregroundStyle(Theme.tx2)
                    }
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 16).padding(.vertical, 12)
            .panel(radius: 12)
            Text("Change the model and tools from the toolbar.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tx3)
            Spacer(minLength: 0)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
