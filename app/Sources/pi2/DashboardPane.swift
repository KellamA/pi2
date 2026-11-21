import SwiftUI

// The window onto each project's orchestrator in its Dashboard column (#618; docs/design/projects.md "The Dashboard"):
// the end of the conversation with it, live, over the field that messages it. It is drawn by the app's own text views
// from the entries the app holds, not by a conversation page each: measured with five columns and one orchestrator
// writing, the two cost the app's main thread about the same, but five pages are five web content processes (about
// 190 MB between them) and a page load each as the Dashboard opens (the numbers are on #618). Only the newest entries
// are asked for (`EngineClient.openConversation(_:tail:)`), only the last few turns are drawn, and a column scrolled out
// of sight or with its window folded away asks for and draws nothing.

/// How the person left each column, kept in the app's preferences by project id (docs/projects.md, 10.1): the height of
/// its window onto the orchestrator, or that it is folded away.
enum DashboardPaneLayout {
    /// The height a new column's window starts at.
    static let defaultHeight: CGFloat = 190
    /// The least it can be made.
    static let minimumHeight: CGFloat = 80

    private static func key(_ id: String) -> String { "dashboard.\(id).pane" }

    static func height(_ id: String) -> CGFloat {
        let saved = UserDefaults.standard.double(forKey: key(id) + "Height")
        return saved > 0 ? max(minimumHeight, saved) : defaultHeight
    }

    static func setHeight(_ height: CGFloat, for id: String) {
        UserDefaults.standard.set(Double(height.rounded()), forKey: key(id) + "Height")
    }

    static func folded(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: key(id) + "Folded") }

    static func setFolded(_ folded: Bool, for id: String) {
        UserDefaults.standard.set(folded, forKey: key(id) + "Folded")
    }
}

/// The window onto the orchestrator at the foot of a Dashboard column: a header that opens the hub, says what the
/// orchestrator is doing and folds the window; the last few turns of the conversation, following as it writes; and the
/// field that messages it. Folded, the header and the field stay, with the orchestrator's last words as the hub's strip
/// shows them.
struct OrchestratorPane: View {
    let model: AppModel
    let project: ProjectRow
    /// Whether the column is on screen. One scrolled out of sight draws an empty space and asks the engine for nothing.
    let visible: Bool
    /// The most the window may take, so that the column's other sections keep some room.
    let tallest: CGFloat
    /// Goes up when the person asks for this column's field with the keyboard.
    var focusRequest = 0

    @State private var height: CGFloat
    @State private var folded: Bool
    /// The height as a drag on the window's top edge began.
    @State private var dragFrom: CGFloat?

    private var engine: EngineClient { model.engine }

    init(model: AppModel, project: ProjectRow, visible: Bool, tallest: CGFloat, focusRequest: Int = 0) {
        self.model = model
        self.project = project
        self.visible = visible
        self.tallest = tallest
        self.focusRequest = focusRequest
        _height = State(initialValue: DashboardPaneLayout.height(project.id))
        _folded = State(initialValue: DashboardPaneLayout.folded(project.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(model: model, project: project, folded: folded) {
                folded.toggle()
                DashboardPaneLayout.setFolded(folded, for: project.id)
            }
            .overlay(alignment: .top) { if !folded { resizeEdge } }
            if !folded {
                Group {
                    if visible, let id = project.conversation {
                        PaneTranscript(model: model, id: id)
                            .id(id)
                    } else {
                        Color.clear
                    }
                }
                .frame(height: max(DashboardPaneLayout.minimumHeight, min(height, tallest)))
                .frame(maxWidth: .infinity)
                .background(Theme.window)
            }
            HubStrip(engine: engine, hubs: model.hubs, project: project, showsLastWords: folded, focusRequest: focusRequest)
        }
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// The window's top edge, dragged to make it taller or shorter. The height is kept once the drag ends.
    private var resizeEdge: some View {
        Color.clear
            .frame(height: 6)
            .contentShape(.rect)
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = dragFrom ?? min(height, tallest)
                        if dragFrom == nil { dragFrom = from }
                        height = max(DashboardPaneLayout.minimumHeight, min(tallest, from - drag.translation.height))
                    }
                    .onEnded { _ in
                        dragFrom = nil
                        DashboardPaneLayout.setHeight(height, for: project.id)
                    }
            )
            .accessibilityHidden(true)
    }
}

/// The window's header: what the orchestrator is doing, as the hub shows it (a spinner while it works, a mark while it
/// waits for the person or a provider's limit), which opens the hub when clicked, and the button that folds the window.
private struct PaneHeader: View {
    let model: AppModel
    let project: ProjectRow
    let folded: Bool
    let fold: () -> Void

    private var engine: EngineClient { model.engine }
    /// The orchestrator's run, while it has one.
    private var run: ActivityRun? { project.conversation.flatMap { id in engine.activity.first { $0.conversationId == id } } }

    var body: some View {
        let orchestrator = engine.agent(project.orchestratorId)
        HStack(spacing: 6) {
            Button { model.showProject(project.id) } label: {
                HStack(spacing: 6) {
                    mark(orchestrator).frame(width: 14)
                    Text(orchestrator?.name ?? "Orchestrator")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.tx)
                        .lineLimit(1)
                        .layoutPriority(1)
                    status
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open the project’s hub, with the whole conversation")
            Button(folded ? "Show the Conversation" : "Fold the Conversation", systemImage: folded ? "chevron.up" : "chevron.down", action: fold)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.tx3)
                .help(folded ? "Show the end of the conversation with the orchestrator here" : "Fold the conversation away, keeping the field")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    @ViewBuilder
    private func mark(_ orchestrator: AgentProfile?) -> some View {
        if let run {
            if run.status == "waiting" {
                Dot(color: Theme.warn)
            } else if run.limit != nil {
                Image(systemName: "hourglass").font(.system(size: 10)).foregroundStyle(Theme.warn)
            } else {
                Spinner()
            }
        } else {
            AgentAvatar(agent: orchestrator, size: 14)
        }
    }

    /// "writing", "waits for you", "waits for a limit until 14:05", or when it last answered.
    @ViewBuilder
    private var status: some View {
        Group {
            if let run {
                if run.status == "waiting" {
                    Text("waits for you").foregroundStyle(Theme.warn)
                } else if let limit = run.limit {
                    Text("waits for a limit until \(LimitsFormat.date(limit.until).formatted(date: .omitted, time: .shortened))").foregroundStyle(Theme.warn)
                } else {
                    Text("working").foregroundStyle(Theme.acc)
                }
            } else if let words = project.lastWords {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("answered \(LimitsFormat.ago(LimitsFormat.date(words.at), now: context.date))").foregroundStyle(Theme.tx3)
                }
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

/// The last few turns of the conversation, drawn by the app's own text views, following as it writes. What is said is
/// drawn again only when an entry is added; what is happening now, as the answer streams, is a view of its own.
private struct PaneTranscript: View {
    let model: AppModel
    let id: Int
    private var engine: EngineClient { model.engine }

    var body: some View {
        Group {
            if let data = engine.open[id], data.arrived {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        PaneHistory(data: data)
                        PaneLive(engine: engine, id: id, data: data)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // At the end as it opens, and kept there as the answer grows.
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
            } else {
                Text("Loading the conversation…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tx3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // On screen, it is open and told to the engine as shown; off screen, it is let go as any conversation is.
        .onAppear {
            engine.openConversation(id, tail: true)
            model.dashboardConversations.insert(id)
        }
        .onDisappear { model.dashboardConversations.remove(id) }
    }
}

/// What has been said: drawn again only when an entry is added, not as an answer streams.
private struct PaneHistory: View {
    let data: OpenConversation

    var body: some View {
        let blocks = PaneTail.blocks(data.items)
        if blocks.isEmpty {
            Text("Nothing said yet. Send the orchestrator a message below.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tx3)
        }
        ForEach(blocks) { block in
            PaneBlockView(block: block, last: block.id == blocks.last?.id)
        }
    }
}

/// What is happening now: the answer as it streams, the tools running, a wait, and the person's messages on their way.
private struct PaneLive: View {
    let engine: EngineClient
    let id: Int
    let data: OpenConversation

    var body: some View {
        content(data.state)
    }

    @ViewBuilder
    private func content(_ state: ConversationState?) -> some View {
        if let queued = state?.queued, !queued.isEmpty {
            ForEach(queued) { message in
                PaneBlockView(block: PaneBlock(id: "queued \(message.id)", kind: .person(message.text), note: "queued"), last: false)
            }
        }
        ForEach(engine.outgoing[id] ?? []) { message in
            PaneBlockView(block: PaneBlock(id: "sending \(message.id)", kind: .person(message.summary), note: "sending"), last: false)
        }
        if let partial = state?.partial {
            let text = partial.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                PaneBlockView(block: PaneBlock(id: "partial", kind: .answer(text)), last: true)
            }
            if !partial.toolCalls.isEmpty, let words = PaneTail.toolWords(partial.toolCalls.map(\.name)) {
                quiet(words, spinning: true)
            }
        } else if let tools = state?.tools.filter({ $0.status == "running" }), !tools.isEmpty, let words = PaneTail.toolWords(tools.map(\.name), running: true) {
            quiet(words, spinning: true)
        } else if state?.busy == true, state?.limitWait == nil {
            quiet("Thinking…", spinning: true)
        }
        if let wait = state?.limitWait {
            Text(wait.sentence)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        } else if let failure = state?.failure, state?.busy != true {
            Text(failure.message)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.bad)
                .lineLimit(3)
        }
    }

    private func quiet(_ text: String, spinning: Bool) -> some View {
        HStack(spacing: 6) {
            if spinning { Spinner(size: 9) }
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.tx3).lineLimit(1)
        }
    }
}

/// One block of the window: a message of the person's, an answer, a line for the tools an answer used, or a notice.
struct PaneBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case person(String)
        case answer(String)
        case tools(String)
        case note(String)
    }

    /// Unique among the blocks shown: the entry's id, and for a line of tools the id of the answer that made the first call,
    /// apart from that answer's own text.
    let id: String
    let kind: Kind
    /// Said beside a message of the person's that is not in the conversation yet: "queued", "sending".
    var note: String? = nil
}

private struct PaneBlockView: View {
    let block: PaneBlock
    /// The newest block, which is drawn whole; an older answer is cut to a few lines.
    let last: Bool

    var body: some View {
        switch block.kind {
        case .person(let text):
            HStack(alignment: .bottom, spacing: 6) {
                Spacer(minLength: 28)
                if let note = block.note {
                    Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.tx3).fixedSize()
                }
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tx)
                    .lineLimit(5)
                    .truncationMode(.tail)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Theme.card2, in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 3, topTrailingRadius: 10, style: .continuous))
                    .textSelection(.enabled)
            }
        case .answer(let text):
            if last {
                // A paragraph a view, each drawn again only when its own words change: as an answer streams, only its
                // last paragraph is laid out again, not the whole answer at every word.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(PaneMarkdown.paragraphs(PaneTail.shortened(text)).enumerated()), id: \.offset) { _, paragraph in
                        PaneParagraph(text: paragraph).equatable()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(PaneMarkdown.attributed(PaneTail.shortened(text)))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tx)
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .tools(let words):
            HStack(spacing: 5) {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 9.5))
                Text(words).lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.tx3)
        case .note(let text):
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tx3)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// One paragraph of an answer.
private struct PaneParagraph: View, Equatable {
    let text: String

    var body: some View {
        Text(PaneMarkdown.attributed(text))
            .font(.system(size: 12))
            .foregroundStyle(Theme.tx)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Which entries the window shows, and in what words: the last few turns, the person's messages and the answers as
/// text, each run of tool calls as one quiet line, and notices as one line each.
enum PaneTail {
    /// How many turns the window shows: each begins with a message of the person's, or with pi² waking the orchestrator.
    static let turns = 3
    /// The most entries it looks at, whatever the turns.
    static let entries = 60
    /// The most characters of one answer it draws: the end of a longer one.
    static let characters = 4000

    static func blocks(_ items: [Item]) -> [PaneBlock] {
        // Back from the end to the start of the turns shown.
        var start = max(0, items.count - entries)
        var seen = 0
        for index in stride(from: items.count - 1, through: start, by: -1) where beginsTurn(items[index]) {
            seen += 1
            if seen == turns { start = index; break }
        }
        var blocks: [PaneBlock] = []
        var tools: [String] = []
        var toolsFrom = 0
        func flush() {
            if let words = toolWords(tools) { blocks.append(PaneBlock(id: "tools \(toolsFrom)", kind: .tools(words))) }
            tools = []
        }
        for item in items[start...] {
            switch item.kind {
            case "user":
                flush()
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let attached = item.attachments?.count ?? 0
                blocks.append(PaneBlock(id: String(item.id), kind: .person(text.isEmpty ? (attached == 1 ? "1 attachment" : "\(attached) attachments") : text)))
            case "assistant":
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    flush()
                    blocks.append(PaneBlock(id: String(item.id), kind: .answer(text)))
                } else if let error = item.error, !error.isEmpty {
                    flush()
                    blocks.append(PaneBlock(id: String(item.id), kind: .note(error)))
                }
                if let calls = item.toolCalls, !calls.isEmpty {
                    if tools.isEmpty { toolsFrom = item.id }
                    tools += calls.map(\.name)
                }
            case "tool":
                // Counted by its call, in the answer before it.
                continue
            default:
                flush()
                if !item.text.isEmpty { blocks.append(PaneBlock(id: String(item.id), kind: .note(item.text))) }
            }
        }
        flush()
        return blocks
    }

    /// A message of the person's, or pi² waking the orchestrator with reports or what changed.
    private static func beginsTurn(_ item: Item) -> Bool {
        item.kind == "user" || (item.kind == "marker" && item.details?["wake"] != nil)
    }

    /// "Ran 3 commands, read 2 files": the tools of one run of calls, in the order first used. `running` says it in the
    /// present: "Running a command".
    static func toolWords(_ names: [String], running: Bool = false) -> String? {
        guard !names.isEmpty else { return nil }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for name in names {
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let parts = order.map { name -> String in
            let n = counts[name] ?? 1
            func count(_ one: String, _ many: String) -> String { n == 1 ? "a \(one)" : "\(n) \(many)" }
            switch name {
            case "bash": return "\(running ? "running" : "ran") \(count("command", "commands"))"
            case "read": return "\(running ? "reading" : "read") \(count("file", "files"))"
            case "edit": return "\(running ? "editing" : "edited") \(count("file", "files"))"
            case "write": return "\(running ? "writing" : "wrote") \(count("file", "files"))"
            case "delegate", "continue": return "\(running ? "handing out" : "handed out") \(n == 1 ? "a piece of work" : "\(n) pieces of work")"
            default: return "\(running ? "using" : "used") \(name.replacingOccurrences(of: "_", with: " "))\(n > 1 ? " \(n) times" : "")"
            }
        }
        let line = parts.joined(separator: ", ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// The end of a long answer, so that one answer of many pages does not cost what the page would.
    static func shortened(_ text: String) -> String {
        guard text.count > characters else { return text }
        return "…" + text.suffix(characters)
    }
}

/// Markdown drawn simply (#618): headings in bold, list items with a bullet, quotes quieter, code in the monospaced
/// font, and bold, italics, code and links within a line, as the app's own text draws them.
enum PaneMarkdown {
    static func attributed(_ source: String) -> AttributedString {
        var result = AttributedString()
        var inCode = false
        let lines = source.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            var line: AttributedString
            if inCode {
                line = AttributedString(raw)
                line.font = .system(size: 11, design: .monospaced)
                line.foregroundColor = Theme.tx2
            } else if let heading = heading(trimmed) {
                line = inline(heading)
                line.font = .system(size: 12, weight: .semibold)
            } else if let item = listItem(raw) {
                line = AttributedString(item.indent + "• ") + inline(item.text)
            } else if trimmed.hasPrefix(">") {
                line = inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                line.foregroundColor = Theme.tx2
            } else if trimmed == "---" || trimmed == "***" {
                line = AttributedString("―――")
                line.foregroundColor = Theme.tx3
            } else {
                line = inline(raw)
            }
            result += line
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }

    /// The text cut at its blank lines, a fenced block of code kept whole.
    static func paragraphs(_ source: String) -> [String] {
        var result: [String] = []
        var current: [String] = []
        var inCode = false
        for line in source.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle() }
            if !inCode, line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current.joined(separator: "\n")) }
        return result
    }

    private static func inline(_ text: String) -> AttributedString { inlineMarkdown(text) }

    private static func heading(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let text = line.drop { $0 == "#" }
        guard text.first == " " else { return nil }
        return String(text.dropFirst())
    }

    private static func listItem(_ line: String) -> (indent: String, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        for marker in ["- ", "* ", "+ "] where rest.hasPrefix(marker) {
            return (String(repeating: "  ", count: min(indent.count / 2, 3)), String(rest.dropFirst(2)))
        }
        return nil
    }
}
