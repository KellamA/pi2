import SwiftUI
import PaneKit

// MARK: - Layout

// The tree of panes and the ready-made layouts are in PaneKit (`app/Sources/PaneKit`); the split, its dividers and the
// rest the hub's panes share with these are in Panes.swift, which outlasts this file (#483, #657).

/// How the conversation area is split into panes, and which pane has the person's attention. The focused pane's
/// conversation is the one the sidebar, the toolbar and the Conversation menu act on.
@MainActor
@Observable
final class Workspace {
    static let maxPanes = 16
    /// The coordinate space pane frames are measured in.
    nonisolated static let space = "pi2.workspace"
    private static let key = "workspace.layout"

    private(set) var root: PaneNode
    private(set) var focused: UUID
    /// Goes up when the person moves to a pane with the keyboard, so that pane's message field takes the keyboard.
    private(set) var keyboardRequest = 0
    /// Where each pane is in the workspace, for telling which one a click landed in. Not observed: it changes as
    /// panes are laid out, and nothing on screen depends on it.
    @ObservationIgnored var frames: [UUID: CGRect] = [:]

    init() {
        // A layout that cannot be read, or that was saved damaged, gives a single pane.
        if let saved = SavedLayout.restore(UserDefaults.standard.data(forKey: Self.key), maxPanes: Self.maxPanes) {
            root = saved.root
            focused = saved.focused
        } else {
            let pane = PaneNode.pane()
            root = pane
            focused = pane.id
        }
    }

    var panes: [PaneNode] { root.leaves }
    var isSplit: Bool { !root.isPane }
    var canSplit: Bool { panes.count < Self.maxPanes }
    var focusedConversation: Int? { root.find(focused)?.conversation }
    /// The conversations open in the panes, whichever page the window shows (see `AppModel.shownConversations`).
    var shownConversations: Set<Int> { Set(panes.compactMap(\.conversation)) }

    func save() {
        if let data = SavedLayout(root: root, focused: focused).encoded() {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Shows a conversation: by moving to the pane that has it, or else in the focused pane.
    func show(_ conversation: Int) {
        if let pane = panes.first(where: { $0.conversation == conversation }) {
            focused = pane.id
        } else {
            root.modify(focused) { $0.conversation = conversation }
        }
        save()
    }

    func focus(_ pane: UUID) {
        guard pane != focused, root.find(pane)?.isPane == true else { return }
        focused = pane
        save()
    }

    func requestKeyboard() { keyboardRequest += 1 }

    /// Puts a conversation in a pane. A pane already showing it gets this pane's conversation instead, so the two swap.
    func put(_ conversation: Int?, in pane: UUID) {
        let previous = root.find(pane)?.conversation
        if let conversation, let other = panes.first(where: { $0.conversation == conversation && $0.id != pane }) {
            root.modify(other.id) { $0.conversation = previous }
        }
        root.modify(pane) { $0.conversation = conversation }
        focused = pane
        save()
    }

    /// Splits a pane in two, the new half empty and focused. A pane already in a split the same way joins it as a
    /// sibling, taking half of this pane's room, so three side by side stay one row with two dividers.
    @discardableResult
    func split(_ pane: UUID, _ axis: SplitAxis) -> UUID? {
        guard canSplit, root.find(pane)?.isPane == true else { return nil }
        let new = PaneNode.pane()
        root.split(pane, axis, adding: new)
        focused = new.id
        save()
        return new.id
    }

    /// Closes a pane. The last one stays.
    func close(_ pane: UUID) {
        guard isSplit, root.find(pane)?.isPane == true else { return }
        let order = panes.map(\.id)
        let index = order.firstIndex(of: pane) ?? 0
        root.remove(pane)
        frames[pane] = nil
        if focused == pane {
            let remaining = panes
            focused = remaining[min(max(index - 1, 0), remaining.count - 1)].id
        }
        save()
    }

    /// Sets how a split divides its room. Saved when `save` is true, at the end of a drag rather than at every step.
    func resize(_ split: UUID, _ fractions: [Double], save: Bool = false) {
        root.modify(split) { node in
            guard node.fractions.count == fractions.count else { return }
            node.fractions = fractions
        }
        if save { self.save() }
    }

    /// Gives one split's panes, or with nil every pane, equal room.
    func equalize(_ split: UUID? = nil) {
        if let split {
            root.modify(split) { $0.equalize(deep: false) }
        } else {
            root.equalize(deep: true)
        }
        save()
    }

    /// Switches to a ready-made layout. The conversations on screen stay, in reading order, with the focused one kept
    /// if there is not room for them all; panes left over get the most recent conversations not yet on screen.
    func apply(_ layout: PaneLayout, recent: [Int]) {
        var tree = layout.make()
        let room = tree.leaves.count
        let current = focusedConversation
        var shown: [Int] = []
        for conversation in panes.compactMap(\.conversation) where !shown.contains(conversation) { shown.append(conversation) }
        if let current, let index = shown.firstIndex(of: current), index >= room {
            shown.remove(at: index)
            shown.insert(current, at: room - 1)
        }
        shown += recent.filter { !shown.contains($0) }
        tree.fill(Array(shown.prefix(room)))
        root = tree
        focused = tree.leaves.first { $0.conversation == current && current != nil }?.id ?? tree.leaves[0].id
        frames = [:]
        save()
    }

    /// Empties the panes showing conversations that are gone.
    func forget(where gone: (Int) -> Bool) {
        for pane in panes {
            if let conversation = pane.conversation, gone(conversation) { root.modify(pane.id) { $0.conversation = nil } }
        }
        save()
    }

    /// The pane `step` places after (or before) the focused one, in reading order, wrapping around.
    func neighbour(_ step: Int) -> UUID? {
        let order = panes.map(\.id)
        guard order.count > 1, let index = order.firstIndex(of: focused) else { return nil }
        return order[((index + step) % order.count + order.count) % order.count]
    }

    /// The pane under a point in the workspace's coordinate space.
    func pane(at point: CGPoint) -> UUID? {
        let ids = Set(panes.map(\.id))
        return frames.first { ids.contains($0.key) && $0.value.contains(point) }?.key
    }
}

extension AppModel {
    /// Moves the person's attention to a pane: the sidebar and toolbar follow its conversation.
    func focusPane(_ pane: UUID, keyboard: Bool = false) {
        workspace.focus(pane)
        selection = workspace.focusedConversation.map { .conversation($0) }
        if keyboard { workspace.requestKeyboard() }
    }

    func put(_ conversation: Int, in pane: UUID) {
        workspace.put(conversation, in: pane)
        selection = .conversation(conversation)
    }

    func splitPane(_ axis: SplitAxis, pane: UUID? = nil) {
        if workspace.split(pane ?? workspace.focused, axis) != nil { selection = nil }
    }

    func closePane(_ pane: UUID? = nil) {
        workspace.close(pane ?? workspace.focused)
        selection = workspace.focusedConversation.map { .conversation($0) }
    }

    func applyLayout(_ layout: PaneLayout) {
        workspace.apply(layout, recent: engine.rootConversations.map(\.id))
        selection = workspace.focusedConversation.map { .conversation($0) }
    }

    /// Shows a conversation in a pane next to another one's, as a sub-chat beside the conversation that opened it. The
    /// other's pane splits to the right, or down where it is already narrower than it is tall. A conversation already
    /// in a pane is moved to; with no room for another pane it shows in place instead.
    func openBeside(_ conversation: Int, beside other: Int) {
        if let pane = workspace.panes.first(where: { $0.conversation == conversation }) {
            focusPane(pane.id)
            return
        }
        let pane = workspace.panes.first { $0.conversation == other }?.id ?? workspace.focused
        let tall = workspace.frames[pane].map { $0.width < $0.height } ?? false
        guard let new = workspace.split(pane, tall ? .column : .row) else {
            selection = .conversation(conversation)
            return
        }
        put(conversation, in: new)
    }

    /// Starts a conversation in a given pane.
    func newConversation(agentId: String?, in pane: UUID) {
        focusPane(pane)
        newConversation(agentId: agentId)
    }
}

// MARK: - Views

/// The conversation area: one conversation, or several in panes.
struct WorkspaceView: View {
    let model: AppModel
    private var engine: EngineClient { model.engine }
    private var workspace: Workspace { model.workspace }

    var body: some View {
        let focusedID = workspace.focusedConversation
        // A stack, not a Group: a Group gives its modifiers to each of its children, so the title and the toolbar
        // went with the conversation's own view, which is made anew for each conversation (`.id`), and the window's
        // whole toolbar was taken down and made again each time one was opened, some 25 ms of the main thread (#502).
        ZStack {
            if workspace.isSplit {
                PaneTree(node: workspace.root, model: model)
                    .padding(PaneMetrics.gutter)
                    .background(Theme.side)
                    .coordinateSpace(.named(Workspace.space))
                    .background(PaneClickMonitor { point in
                        if let pane = workspace.pane(at: point), pane != workspace.focused { model.focusPane(pane) }
                    })
                    .environment(\.inSplitPane, true)
            } else if let focusedID {
                ChatView(engine: engine, id: focusedID, focusRequest: workspace.keyboardRequest)
                    .id(focusedID)
            } else {
                Theme.window
            }
        }
        .navigationTitle(focusedID.map { engine.conversationTitle($0) } ?? "pi²")
        .navigationSubtitle(focusedID.map { engine.conversationSubtitle($0) } ?? (workspace.isSplit ? "\(workspace.panes.count) panes" : ""))
        .toolbar {
            ToolbarItemGroup {
                if let focusedID { conversationTools(focusedID) }
            }
            ToolbarItem {
                LayoutButton(model: model)
            }
        }
    }

    /// The focused conversation's controls.
    @ViewBuilder
    private func conversationTools(_ id: Int) -> some View {
        let state = engine.open[id]?.state
        // The sidebar's list knows a sub-chat's parent; for a sub-chat of an archived conversation, its state does.
        let listed = engine.conversations.first(where: { $0.id == id })?.parent.flatMap { parent in engine.conversations.first { $0.id == parent }?.id }
        if let parentID = listed ?? state?.agent.parent {
            Button("Parent Chat", systemImage: "arrow.turn.left.up") { engine.onNavigate(parentID, nil) }
                .labelStyle(.titleAndIcon)
                .help("Go to the conversation whose agent opened this sub-chat")
        }
        if engine.agent(state?.agent.agentId)?.browser?.enabled == true { BrowserButton(engine: engine, conversationID: id) }
        if let branch = engine.branches[id] { BranchMenu(engine: engine, id: id, status: branch) }
        // Until the conversation has come from the engine there is no model or access to show, and "Model" and
        // "Tools off" would read as if nothing were chosen; the pane says it is loading instead. They come once a pane
        // has shown it: making them takes the main thread some 20 ms, which held up its first frame (#502).
        if let state, engine.open[id]?.shown == true {
            ContextMeter(engine: engine, id: id, state: state)
            ModelMenu(engine: engine, id: id, agent: state.agent)
            ToolsMenu(engine: engine, id: id, agent: state.agent)
        }
    }
}

/// The old screens' pane tree, drawn with the split the hub's panes share (Panes.swift).
struct PaneTree: View {
    let node: PaneNode
    let model: AppModel

    var body: some View {
        let workspace = model.workspace
        PaneTreeView(node: node, space: Workspace.space, least: nil, actions: PaneSplitActions(
            resize: { workspace.resize($0, $1) },
            equalize: { workspace.equalize($0) },
            save: { workspace.save() }
        )) { pane in
            PaneView(pane: pane, model: model)
        }
    }
}

/// One pane: a header with what it shows and its controls, then the conversation, or a choice of one.
struct PaneView: View {
    let pane: PaneNode
    let model: AppModel
    @State private var dropTargeted = false
    private var engine: EngineClient { model.engine }
    private var focused: Bool { model.workspace.focused == pane.id }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: pane, model: model, focused: focused)
            Group {
                if let id = pane.conversation {
                    ChatView(engine: engine, id: id, active: focused, focusRequest: model.workspace.keyboardRequest) {
                        model.focusPane(pane.id)
                    }
                    .id(id)
                } else {
                    PanePicker(pane: pane, model: model)
                }
            }
            // A small pane gets less than its content would like; the content is cut off at the bottom rather than
            // pushing the header out of the pane.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.window)
        .clipped()
        .overlay {
            // Drawn in the gutter, around the pane rather than over its edge.
            Rectangle()
                .strokeBorder(dropTargeted ? Theme.acc : focused ? Theme.acc.opacity(0.75) : Theme.line2, lineWidth: focused || dropTargeted ? 1.5 : 1)
                .padding(-2)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Workspace.space)) } action: { frame in
            model.workspace.frames[pane.id] = frame
        }
        .dropDestination(for: ConversationDrag.self) { items, _ in
            guard let item = items.first else { return false }
            model.put(item.id, in: pane.id)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

/// A pane's title bar: who and what it shows, and splitting, switching and closing.
private struct PaneHeader: View {
    let pane: PaneNode
    let model: AppModel
    let focused: Bool
    private var engine: EngineClient { model.engine }
    private var workspace: Workspace { model.workspace }
    private var summary: ConversationSummary? { pane.conversation.flatMap { id in engine.conversations.first { $0.id == id } } }

    var body: some View {
        HStack(spacing: 6) {
            if let id = pane.conversation {
                if let wait = engine.limitWaits[id] {
                    Image(systemName: "hourglass").font(.system(size: 11)).foregroundStyle(Theme.warn).frame(width: 14)
                        .help(wait.sentence)
                } else if summary?.busy == true || engine.open[id]?.state?.busy == true {
                    Spinner().frame(width: 14)
                } else {
                    AgentAvatar(agent: engine.agent(summary?.agentId ?? engine.open[id]?.state?.agent.agentId), size: 14)
                }
                Text(engine.conversationTitle(id))
                    .font(.system(size: 12, weight: focused ? .semibold : .medium))
                    .foregroundStyle(focused ? Theme.tx : Theme.tx2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if engine.inbox.contains(where: { $0.rootConversationId == id || $0.conversationId == id }) {
                    Circle().fill(Theme.warn).frame(width: 6, height: 6)
                        .help("Waiting on you")
                        .accessibilityLabel("Needs you")
                }
            } else {
                Image(systemName: "square.dashed").font(.system(size: 11)).foregroundStyle(Theme.tx3)
                Text("Empty pane").font(.system(size: 12)).foregroundStyle(Theme.tx3)
            }
            Spacer(minLength: 4)
            Group {
                Button("Split Right", systemImage: "rectangle.split.2x1") { model.splitPane(.row, pane: pane.id) }
                    .help("Split this pane, new pane on the right (⌘D)")
                    .disabled(!workspace.canSplit)
                Button("Split Down", systemImage: "rectangle.split.1x2") { model.splitPane(.column, pane: pane.id) }
                    .help("Split this pane, new pane below (⇧⌘D)")
                    .disabled(!workspace.canSplit)
                Menu {
                    switchMenu
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Show another conversation here")
                Button("Close Pane", systemImage: "xmark") { model.closePane(pane.id) }
                    .help("Close this pane (⌃⌘W). The conversation stays in the sidebar.")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(Theme.tx3)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(focused ? Theme.acc.opacity(0.10) : Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(.rect)
        .onTapGesture { model.focusPane(pane.id) }
        .contextMenu(previewAs: pane.conversation.map { "Pane: \(engine.conversationTitle($0))" } ?? "Empty pane") { switchMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pane.conversation.map { "Pane: \(engine.conversationTitle($0))" } ?? "Empty pane")
    }

    @ViewBuilder
    private var switchMenu: some View {
        let shown = Set(workspace.panes.compactMap(\.conversation))
        Menu("Show Conversation") {
            ForEach(engine.rootConversations.prefix(30)) { conversation in
                Button {
                    model.put(conversation.id, in: pane.id)
                } label: {
                    let title = conversation.title.isEmpty ? "New conversation" : conversation.title
                    if conversation.id == pane.conversation {
                        Label(title, systemImage: "checkmark")
                    } else if shown.contains(conversation.id) {
                        Text("\(title) (swap)")
                    } else {
                        Text(title)
                    }
                }
            }
        }
        Menu("New Conversation With") {
            ForEach(engine.agents) { agent in
                Button(agent.name) { model.newConversation(agentId: agent.id, in: pane.id) }
            }
        }
        .disabled(engine.status != .connected)
        Divider()
        Button("Split Right") { model.splitPane(.row, pane: pane.id) }.disabled(!workspace.canSplit)
        Button("Split Down") { model.splitPane(.column, pane: pane.id) }.disabled(!workspace.canSplit)
        if pane.conversation != nil {
            Button("Empty This Pane") { workspace.put(nil, in: pane.id); model.selection = nil }
        }
        Button("Close Pane") { model.closePane(pane.id) }
    }
}

/// An empty pane: the conversations not on screen yet, and agents to start a new one with.
private struct PanePicker: View {
    let pane: PaneNode
    let model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        let shown = Set(model.workspace.panes.compactMap(\.conversation))
        let choices = engine.rootConversations.filter { !shown.contains($0.id) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Start a conversation").sectionLabel()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(engine.agents) { agent in
                        Button { model.newConversation(agentId: agent.id, in: pane.id) } label: {
                            HStack(spacing: 6) {
                                AgentAvatar(agent: agent, size: 16)
                                Text(agent.name).lineLimit(1)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Theme.card, in: .rect(cornerRadius: 7))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(engine.status != .connected)
                        .help("New conversation with \(agent.name) in this pane")
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Or show one here").sectionLabel().padding(.top, 4)
            if choices.isEmpty {
                Text("Every conversation is already on screen.").font(.system(size: 12)).foregroundStyle(Theme.tx3)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(choices) { conversation in
                        Button { model.put(conversation.id, in: pane.id) } label: {
                            HStack(spacing: 8) {
                                if conversation.busy {
                                    Spinner().frame(width: 16)
                                } else {
                                    AgentAvatar(agent: engine.agent(conversation.agentId), size: 16)
                                }
                                Text(conversation.title.isEmpty ? "New conversation" : conversation.title)
                                    .lineLimit(1)
                                    .foregroundStyle(conversation.title.isEmpty ? Theme.tx2 : Theme.tx)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(.rect)
                        }
                        .buttonStyle(PickerRowStyle())
                    }
                }
            }
            Text("You can also drag a conversation here from the sidebar.")
                .font(.system(size: 11)).foregroundStyle(Theme.tx3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window)
    }
}

private struct PickerRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Theme.card : .clear, in: .rect(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}

/// The toolbar button that splits the conversation area, with the ready-made layouts drawn as pictures.
struct LayoutButton: View {
    let model: AppModel
    @State private var showing = false

    var body: some View {
        Button("Layout", systemImage: model.workspace.isSplit ? "rectangle.split.2x2.fill" : "rectangle.split.2x2") { showing.toggle() }
            .help("Split the window to see several conversations at once")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                LayoutPicker(model: model) { showing = false }
            }
    }
}

private struct LayoutPicker: View {
    let model: AppModel
    let done: () -> Void
    private var workspace: Workspace { model.workspace }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Layout").font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(74), spacing: 8), count: 5), spacing: 10) {
                ForEach(PaneLayout.all) { layout in
                    Button {
                        model.applyLayout(layout)
                        done()
                    } label: {
                        VStack(spacing: 4) {
                            LayoutThumbnail(node: layout.make())
                                .frame(width: 64, height: 42)
                            Text("\(layout.count)").font(.system(size: 10.5)).foregroundStyle(Theme.tx3)
                        }
                        .padding(5)
                        .contentShape(.rect)
                    }
                    .buttonStyle(PickerRowStyle())
                    .help(layout.name)
                    .accessibilityLabel(layout.name)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button("Split Right", systemImage: "rectangle.split.2x1") { model.splitPane(.row); done() }
                    .disabled(!workspace.canSplit)
                Button("Split Down", systemImage: "rectangle.split.1x2") { model.splitPane(.column); done() }
                    .disabled(!workspace.canSplit)
                Button("Even Out", systemImage: "equal.square") { workspace.equalize(); done() }
                    .disabled(!workspace.isSplit)
                    .help("Give every pane equal room")
            }
            .buttonStyle(.piSecondary)
            Text("Drag the dividers between panes to resize them; double-click one to even out. Up to \(Workspace.maxPanes) panes; this window has \(workspace.panes.count).")
                .font(.system(size: 11)).foregroundStyle(Theme.tx3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 440)
    }
}

/// A small drawing of a layout.
private struct LayoutThumbnail: View {
    let node: PaneNode

    var body: some View {
        if node.isPane {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Theme.acc.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(Theme.acc.opacity(0.7), lineWidth: 1))
        } else {
            GeometryReader { geometry in
                let horizontal = node.axis == .row
                let gap: CGFloat = 2.5
                let room = (horizontal ? geometry.size.width : geometry.size.height) - gap * CGFloat(node.children.count - 1)
                let stack = horizontal ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
                stack {
                    ForEach(Array(node.children.enumerated()), id: \.offset) { index, child in
                        LayoutThumbnail(node: child)
                            .frame(
                                width: horizontal ? room * node.fractions[index] : geometry.size.width,
                                height: horizontal ? geometry.size.height : room * node.fractions[index]
                            )
                    }
                }
            }
        }
    }
}

// MARK: - Menu commands

/// The View menu's pane commands. They read the mode here rather than in the scene, so that switching it draws this
/// menu again and not every scene (#436).
struct PaneCommands: View {
    let model: AppModel
    private var workspace: Workspace { model.workspace }

    var body: some View {
        // With the projects preview on they act on the shown hub's panes (#657), and these panes are not drawn at all
        // (#644). Otherwise they are the agent view's; in chat mode they would change it out of sight.
        if model.engine.projectsPreview {
            HubPaneCommands(model: model)
        } else {
            Group { commands }
                .disabled(model.mode == .chat)
        }
    }

    @ViewBuilder private var commands: some View {
        Button("Split Right") { model.splitPane(.row) }
            .keyboardShortcut("d")
            .disabled(!workspace.canSplit)
        Button("Split Down") { model.splitPane(.column) }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!workspace.canSplit)
        Button("Close Pane") { model.closePane() }
            .keyboardShortcut("w", modifiers: [.command, .control])
            .disabled(!workspace.isSplit)
        Button("Next Pane") { if let next = workspace.neighbour(1) { model.focusPane(next, keyboard: true) } }
            .keyboardShortcut("]")
            .disabled(!workspace.isSplit)
        Button("Previous Pane") { if let previous = workspace.neighbour(-1) { model.focusPane(previous, keyboard: true) } }
            .keyboardShortcut("[")
            .disabled(!workspace.isSplit)
        Menu("Layout") {
            ForEach(PaneLayout.all) { layout in
                Button("\(layout.name) (\(layout.count))") { model.applyLayout(layout) }
            }
            Divider()
            Button("Even Out Panes") { workspace.equalize() }
                .disabled(!workspace.isSplit)
        }
    }
}
