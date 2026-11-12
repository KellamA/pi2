import SwiftUI

struct ChatView: View {
    let engine: EngineClient
    let id: Int

    @State private var draft = ""
    @State private var steer = true
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
            TranscriptView(engine: engine, conversationID: id, items: data.items, state: state)
            // A subagent of this conversation is waiting on the person.
            ForEach(engine.inbox.filter { $0.rootConversationId == id && $0.conversationId != id }) { item in
                InboxCard(engine: engine, item: item, showsSource: true)
                    .padding(.horizontal, 20).padding(.top, 8)
            }
            if state?.compacting == true {
                banner("Summarising earlier messages to free up context…", systemImage: "arrow.down.right.and.arrow.up.left", color: .secondary)
            }
            if let error = state?.compactionError, state?.compacting != true {
                banner("The last attempt to summarise the conversation failed: \(error)", systemImage: "exclamationmark.triangle", color: .orange)
            }
            if let retry = state?.retry {
                banner("The request failed and will be retried: \(retry.error)", systemImage: "arrow.clockwise", color: .orange)
            }
            if let failure = state?.failure, !busy {
                HStack {
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(failure.reason == "aborted" ? Color.secondary : Color.red)
                        .lineLimit(3)
                    Spacer()
                    if failure.reason != "nothing_to_answer" {
                        Button("Continue") { engine.perform("continue", ["id": id]) }
                            .help("Resume the run from where it stopped, without typing a new message")
                    }
                }
                .font(.callout)
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(.quaternary.opacity(0.5))
            }
            queue
            composer
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                if let parent {
                    Button("Parent Chat", systemImage: "arrow.turn.left.up") { engine.onNavigate(parent.id) }
                        .labelStyle(.titleAndIcon)
                        .help("Go to the conversation whose agent opened this sub-chat")
                }
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
            .font(.callout)
            .foregroundStyle(color)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(color.opacity(0.1))
    }

    @ViewBuilder
    private var queue: some View {
        if let queued = state?.queued, !queued.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(queued) { item in
                        HStack(spacing: 6) {
                            Text(item.mode == "steer" ? "Steering" : "Queued").foregroundStyle(.secondary)
                            Text(item.text).lineLimit(1).frame(maxWidth: 260, alignment: .leading)
                            Button("Remove", systemImage: "xmark") {
                                engine.perform("withdraw", ["submissionId": item.id])
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Remove this message before it is sent to the model")
                        }
                        .font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.quaternary, in: .capsule)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 8)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(busy ? (steer ? "Steer the current work…" : "Queue a follow-up…") : (parent == nil ? "Message" : "Message this subagent directly"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit(send)
                .accessibilityIdentifier("composer")
            HStack(spacing: 8) {
                if busy {
                    Picker("While working", selection: $steer) {
                        Text("Steer").tag(true)
                        Text("Queue").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Steer: the message joins the current work after its next step. Queue: it starts a new run when this one answers.")
                }
                Spacer()
                if busy {
                    Button("Stop", systemImage: "stop.fill") { engine.perform("abort", ["id": id]) }
                        .help("Stop the run and everything it started (⌘.)")
                }
                Button("Send", systemImage: "arrow.up") { send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var canSend: Bool {
        engine.status == .connected && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        let steering = busy && steer
        draft = ""
        Task {
            // A refused message goes back in the box rather than being lost.
            if await !engine.submit(text, to: id, steer: steering), draft.isEmpty { draft = text }
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
                Text("This conversation: \(usage.costText) · \(usage.tokensText) tokens")
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
        return engine.models.first { $0.ref == ref }
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
        default: "Tools off"
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
                        Text(item.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.quaternary, in: .rect(cornerRadius: 12))
                            .frame(maxWidth: .infinity, alignment: .trailing)
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
                        HStack {
                            VStack { Divider() }
                            Text(item.text).font(.caption).foregroundStyle(.secondary)
                            VStack { Divider() }
                        }
                    }
                }
                if let partial = state?.partial {
                    VStack(alignment: .leading, spacing: 8) {
                        if !partial.thinking.isEmpty { ThinkingView(text: partial.thinking, streaming: partial.text.isEmpty) }
                        if !partial.text.isEmpty { MessageText(text: partial.text + " ▍") }
                        ForEach(partial.toolCalls) { call in
                            Label("Preparing \(call.name)…", systemImage: "hammer").font(.callout).foregroundStyle(.secondary)
                        }
                        if partial.text.isEmpty && partial.thinking.isEmpty && partial.toolCalls.isEmpty { ProgressView().controlSize(.small) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if state?.busy == true, state?.tools.isEmpty ?? true, state?.retry == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(20)
            .frame(maxWidth: 860)
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
                    .font(.caption).foregroundStyle(.orange)
            }
            if let thinking = item.thinking, !thinking.isEmpty { ThinkingView(text: thinking, streaming: false) }
            if !item.text.isEmpty {
                MessageText(text: item.text)
                    .foregroundStyle(interrupted ? .secondary : .primary)
            }
            if let error = item.error, !error.isEmpty {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            ForEach(item.toolCalls ?? []) { call in
                ToolCard(engine: engine, conversationID: conversationID, call: call, result: results[call.callId], live: live[call.callId], running: running)
            }
            if item.stop == "length" {
                Text("The answer was cut off at the model's output limit.").font(.caption).foregroundStyle(.secondary)
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
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label(streaming ? "Thinking…" : "Thought", systemImage: "brain").font(.callout).foregroundStyle(.secondary)
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<harness>"), trimmed.hasSuffix("</harness>") else { return text }
        var inner = String(trimmed.dropFirst("<harness>".count).dropLast("</harness>".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.hasPrefix("[error] ") { inner.removeFirst("[error] ".count) }
        return inner
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
        case "codemode": return "Script"
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
        default: call.name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "hammer"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expandedChoice = !expanded
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                    Text(title).font(.callout.weight(.medium))
                    Text(call.summary)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if pending != nil {
                        Text("Waiting for you").font(.caption.weight(.medium)).foregroundStyle(.orange)
                    } else if isRunning {
                        ProgressView().controlSize(.small)
                    } else if result == nil {
                        Text("no result").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(isError ? .red : .green)
                            .accessibilityLabel(isError ? "Failed" : "Succeeded")
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(call.name) \(call.summary)")

            if let pending {
                Divider()
                InboxCard(engine: engine, item: pending, showsSource: false, framed: false)
                    .padding(12)
            }
            if let subagent {
                Divider()
                Button("Open \(subagent.name)’s Sub-chat", systemImage: "arrow.turn.down.right") {
                    engine.openConversation(subagent.id)
                    engine.onNavigate(subagent.id)
                }
                .buttonStyle(.link)
                .padding(.horizontal, 12).padding(.vertical, 8)
            }

            if expanded && pending == nil {
                Divider()
                ScrollView {
                    Text(output.isEmpty ? (isRunning ? "Running…" : "(no output)") : output)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(isError ? .red : .secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 260)
                .defaultScrollAnchor(.bottom)
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

/// Assistant text: inline Markdown, with fenced code blocks set apart.
struct MessageText: View {
    let text: String

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
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.code {
                    Text(segment.text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.background.secondary, in: .rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                } else {
                    Text(markdown(segment.text))
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func markdown(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
    }
}
