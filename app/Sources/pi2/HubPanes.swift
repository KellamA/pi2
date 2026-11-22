
import SwiftUI
import PaneKit
import WindowKit

// A project's hub in panes (#657): the place beside the conversation with the orchestrator, where the board shows,
// divided with the pane tree of the old screens. Each pane shows the board, one of the project's conversations, or, just
// made, a choice of them. `HubLayout` (PaneKit) is the tree and its rules; `ProjectHubs` keeps one for each project; the
// View menu's pane commands act on the shown hub's (`HubPaneCommands`); and every way to open one of the project's
// conversations goes to its focused pane, or with ⌥ to a new one beside it (`AppModel.openAgent`). docs/projects.md,
// 10.1 and 10.3, say what is kept and shown.

extension ProjectHubs {
    /// A project's panes: as changed this launch, or as the preferences kept them, or the board alone.
    func layout(_ id: String) -> HubLayout {
        if let layout = layouts[id] { return layout }
        if let saved = savedLayouts[id] { return saved }
        let saved = HubLayout.restore(UserDefaults.standard.data(forKey: Self.key(id, "panes"))) ?? HubLayout()
        savedLayouts[id] = saved
        return saved
    }

    /// Changes a project's panes, and keeps them unless `save` is false (while a divider is dragged).
    func update(_ id: String, save: Bool = true, _ change: (inout HubLayout) -> Void) {
        var layout = self.layout(id)
        change(&layout)
        if layouts[id] != layout { layouts[id] = layout }
        if save { self.save(id) }
    }

    /// Keeps a project's panes in the preferences; the board alone, which is what a hub has at first, is kept as nothing.
    func save(_ id: String) {
        let layout = self.layout(id)
        let key = Self.key(id, "panes")
        if layout.isBoardOnly {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = layout.encoded() {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Shows a conversation in a project's panes: in the pane that has it, else in a new pane beside the focused one (or
    /// beside the pane of `parent`) when `beside`, else in the focused pane, or the conversation pane focused last when
    /// the board has the focus. A new pane that does not fit is said why, and the conversation shows in place instead.
    func open(_ conversation: Int, in id: String, beside: Bool, from parent: Int?) {
        orchestratorKeyed[id] = false
        var why: String?
        update(id) { layout in
            if let pane = layout.pane(showing: conversation) {
                layout.focus(pane)
                return
            }
            if beside {
                let near = parent.flatMap { layout.pane(showing: $0) } ?? layout.focused
                why = split(&layout, near, [.row, .column], showing: conversation, in: id)
                if why == nil { return }
            }
            layout.put(conversation, in: layout.openTarget)
        }
        refusals[id] = why.map { "\($0) It shows in a pane already there instead." }
    }

    /// Splits `pane` the first of `axes` ways that fits the hub's room, or says why none does.
    func split(_ layout: inout HubLayout, _ pane: UUID, _ axes: [SplitAxis], showing conversation: Int?, in id: String) -> String? {
        guard layout.canSplit else { return "A hub holds up to \(HubLayout.maxPanes) panes. Close one first." }
        var why: String?
        for axis in axes {
            var copy = layout
            guard copy.split(pane, axis, showing: conversation) != nil else { continue }
            if let room = rooms[id], !copy.fits(width: room.width, height: room.height) {
                if why == nil { why = Self.noRoom(axis, room: room) }
                continue
            }
            layout = copy
            return nil
        }
        return why ?? "That pane cannot be split."
    }

    static func noRoom(_ axis: SplitAxis, room: CGSize) -> String {
        axis == .row
            ? "There is no room for another pane side by side: each needs \(Int(HubFold.columnWidth)) points across, and the hub is \(Int(room.width)) points wide. Widen the window, or split down (⇧⌘D)."
            : "There is no room for another pane one above another: each needs \(Int(HubLayout.minimumHeight)) points of height, and the panes have \(Int(room.height)). Make the window taller, or split right (⌘D)."
    }

    /// Moves the attention to a pane, and with `keyboard` its message field takes the keyboard.
    func focus(_ pane: UUID, in id: String, keyboard: Bool = false) {
        orchestratorKeyed[id] = false
        if layout(id).focused != pane { update(id) { $0.focus(pane) } }
        if keyboard { keyboardRequests[id, default: 0] += 1 }
    }

    /// Gives the keyboard to the conversation with the orchestrator, as a click in its field does.
    func keyOrchestrator(_ id: String, keyboard: Bool = false) {
        orchestratorKeyed[id] = true
        if keyboard { keyboardRequests[id, default: 0] += 1 }
    }

    /// Closes, in the panes of these projects, those whose conversations are gone: archived or deleted (#657).
    func forget(projects: [String], where gone: (Int) -> Bool) {
        for id in projects where layout(id).conversations.contains(where: gone) {
            update(id) { $0.forget(where: gone) }
        }
    }

    /// The pane under a point in a hub's panes.
    func pane(at point: CGPoint, in layout: HubLayout) -> UUID? {
        let ids = Set(layout.panes.map(\.id))
        return frames.first { ids.contains($0.key) && $0.value.contains(point) }?.key
    }
}

extension AppModel {
    /// Why the View menu's pane commands do not apply to what the window shows, or nil when they act on a hub's panes.
    var paneRefusal: String? {
        if mode == .chat { return "Panes are the agent view's. Chat mode shows one chat at a time." }
        if shownProject != nil { return nil }
        if selection == .dashboard { return "The Dashboard shows every project. Open a project to split its hub." }
        return "Panes divide a project's hub. Open a project first."
    }

    /// Splits the focused pane of the shown hub, the new one showing the picker, or says why it cannot.
    func splitHubPane(_ axis: SplitAxis) {
        guard let id = shownProject else { return }
        if hubs.fold(id) == .boardFolded { hubs.setFold(.both, for: id) }
        var why: String?
        hubs.update(id) { layout in
            let pane = layout.focused
            why = hubs.split(&layout, pane, [axis], showing: nil, in: id)
        }
        if why == nil { hubs.orchestratorKeyed[id] = false }
        hubs.refusals[id] = why
    }

    /// Closes the shown hub's focused pane, or `pane`.
    func closeHubPane(_ pane: UUID? = nil) {
        guard let id = shownProject else { return }
        hubs.update(id) { $0.close(pane ?? $0.focused) }
        hubs.refusals[id] = nil
    }

    /// Whether Close Pane has anything to close: not the board alone.
    var canCloseHubPane: Bool {
        guard let id = shownProject else { return false }
        return !hubs.layout(id).isBoardOnly
    }

    /// Moves to the next or the previous of the hub's conversations and panes, the orchestrator's first, with the keyboard.
    func moveHubPane(_ step: Int) {
        guard let id = shownProject else { return }
        let fold = hubs.drawnFolds[id] ?? hubs.fold(id)
        let layout = hubs.layout(id)
        var stops: [UUID?] = []
        if fold != .conversationFolded { stops.append(nil) }
        if fold != .boardFolded { stops += layout.panes.map { Optional($0.id) } }
        guard stops.count > 1 else { return }
        let current: UUID? = fold == .boardFolded || (fold != .conversationFolded && hubs.orchestratorKeyed[id] == true) ? nil : layout.focused
        let index = stops.firstIndex { $0 == current } ?? 0
        if let next = stops[((index + step) % stops.count + stops.count) % stops.count] {
            hubs.focus(next, in: id, keyboard: true)
        } else {
            hubs.keyOrchestrator(id, keyboard: true)
        }
    }

    /// How many stops Next Pane has: the orchestrator's conversation and the panes, as shown.
    var hubPaneStops: Int {
        guard let id = shownProject else { return 0 }
        let fold = hubs.drawnFolds[id] ?? hubs.fold(id)
        return (fold != .conversationFolded ? 1 : 0) + (fold != .boardFolded ? hubs.layout(id).panes.count : 0)
    }

    /// Gives the shown hub's panes equal room.
    func evenOutHubPanes() {
        guard let id = shownProject else { return }
        hubs.update(id) { $0.equalize() }
    }

    /// Why a ready-made layout cannot be had in the shown hub, or nil when it can.
    func hubLayoutRefusal(_ layout: PaneLayout) -> String? {
        guard let id = shownProject else { return paneRefusal }
        if layout.count > HubLayout.maxPanes { return "A hub holds up to \(HubLayout.maxPanes) panes." }
        guard let room = hubs.rooms[id] else { return nil }
        let least = HubLayout.minimum(layout.make())
        if least.width > room.width + 0.5 { return "The hub is too narrow for this layout: it needs \(Int(least.width + 1)) points across." }
        if least.height > room.height + 0.5 { return "The hub is too low for this layout: it needs \(Int(least.height)) points of height." }
        return nil
    }

    /// Switches the shown hub to a ready-made layout: what shows stays, and panes left over get the project's working
    /// agents' conversations, then its others.
    func applyHubLayout(_ layout: PaneLayout) {
        guard let id = shownProject, hubLayoutRefusal(layout) == nil else { return }
        if hubs.fold(id) == .boardFolded { hubs.setFold(.both, for: id) }
        let live = engine.projectStore.live(id)
        hubs.update(id) { $0.apply(layout, recent: live.runs + live.others.map(\.id)) }
        hubs.refusals[id] = nil
    }

    /// A conversation dropped on one of a hub's panes, from the sidebar: shown there, or in a new pane split off it
    /// `splitting` that way, if it is one of the project's. One a pane already shows moves to the new pane.
    @discardableResult
    func dropInHub(_ conversation: Int, on pane: UUID, in id: String, splitting axis: SplitAxis? = nil) -> Bool {
        guard case .board(let project) = place(of: conversation), project == id else {
            hubs.refusals[id] = "Only this project's conversations show in its panes. The Dashboard shows every project."
            return false
        }
        engine.openConversation(conversation)
        hubs.orchestratorKeyed[id] = false
        var why: String?
        hubs.update(id) { layout in
            if let axis {
                if let shown = layout.pane(showing: conversation), shown != pane, layout.panes.count > 1 { layout.close(shown) }
                if layout.pane(showing: conversation) == nil {
                    why = hubs.split(&layout, pane, [axis], showing: conversation, in: id)
                    if why == nil { return }
                }
            }
            layout.put(conversation, in: pane)
        }
        hubs.refusals[id] = why.map { "\($0) It shows in this pane instead." }
        return true
    }
}

// MARK: - The panes

/// The place beside the conversation with the orchestrator: one pane, which is the hub as it always was, or several,
/// with dividers between them. The panes keep their least sizes: a window too small for them scrolls them rather than
/// crushing their message fields.
struct HubPaneArea: View {
    let model: AppModel
    let project: ProjectRow
    let layout: HubLayout
    let shown: HubFold
    /// Whether the conversation with the orchestrator has the keyboard rather than the focused pane.
    let orchestratorKeyed: Bool
    private var hubs: ProjectHubs { model.hubs }
    private var space: String { "pi2.hub.\(project.id)" }

    var body: some View {
        if layout.isSplit {
            let least = HubLayout.minimum(layout.root)
            GeometryReader { geometry in
                // Only a window too small for the panes scrolls them: the conversation pages in them scroll themselves.
                if least.width <= geometry.size.width + 0.5 && least.height <= geometry.size.height + 0.5 {
                    tree.frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        tree.frame(width: max(geometry.size.width, least.width), height: max(geometry.size.height, least.height))
                    }
                }
            }
            .background(Theme.side)
            .environment(\.inSplitPane, true)
        } else {
            HubPane(model: model, project: project, layout: layout, pane: layout.root.id, shown: shown, orchestratorKeyed: orchestratorKeyed, space: space)
        }
    }

    /// The panes, with the dividers between them and the watch on clicks that moves the focus to the pane clicked in.
    private var tree: some View {
        let id = project.id
        return PaneTreeView(node: layout.root, space: space, least: { CGSize(width: HubLayout.minimum($0).width, height: HubLayout.minimum($0).height) }, actions: PaneSplitActions(
            resize: { split, fractions in hubs.update(id, save: false) { $0.resize(split, fractions) } },
            equalize: { split in hubs.update(id) { $0.equalize(split) } },
            save: { hubs.save(id) }
        )) { pane in
            HubPane(model: model, project: project, layout: layout, pane: pane.id, shown: shown, orchestratorKeyed: orchestratorKeyed, space: space)
        }
        .coordinateSpace(.named(space))
        .background(PaneClickMonitor { point in
            let current = hubs.layout(id)
            guard let pane = hubs.pane(at: point, in: current) else { return }
            if pane != current.focused || hubs.orchestratorKeyed[id] == true { hubs.focus(pane, in: id) }
        })
    }
}

/// One of a hub's panes: the board, a conversation under the agent panel's header, or the picker of a pane just made.
/// Among several, the focused one is ringed, and each takes a conversation dragged onto it from the sidebar.
private struct HubPane: View {
    let model: AppModel
    let project: ProjectRow
    let layout: HubLayout
    let pane: UUID
    let shown: HubFold
    let orchestratorKeyed: Bool
    let space: String
    /// Where a conversation dragged over the pane would go, while one is.
    @State private var drop: HubDrop.Zone?
    @State private var size: CGSize = .zero
    private var hubs: ProjectHubs { model.hubs }

    var body: some View {
        let dropTargeted = drop == .here
        let split = layout.isSplit
        let focused = layout.focused == pane
        // The keyboard is this pane's when it has the focus and the orchestrator's field does not have it.
        let active = focused && !orchestratorKeyed
        let id = project.id
        Group {
            switch layout.content(of: pane) {
            case .board?:
                HubBoard(model: model, project: project, tab: hubs.tab(id), shown: shown, pane: split ? HubPaneHeader(focused: focused) { hubs.update(id) { $0.close(pane) } } : nil)
            case .conversation(let conversation)?:
                HubAgentPanel(model: model, project: project, conversation: conversation, shown: shown, active: active,
                              pane: HubPaneHeader(focused: split && focused, close: split ? { hubs.update(id) { $0.close(pane) } } : nil),
                              boardShown: layout.board != nil, focusRequest: hubs.keyboardRequests[id] ?? 0) {
                    hubs.focus(pane, in: id)
                } backToBoard: {
                    hubs.update(id) { $0.showBoard(in: pane) }
                }
            case .picker?, nil:
                HubPanePicker(model: model, project: project, layout: layout, pane: pane, focused: active)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background(Theme.window)
        .clipped()
        .overlay {
            if split || dropTargeted {
                // Drawn in the gutter, around the pane rather than over its edge.
                Rectangle()
                    .strokeBorder(dropTargeted ? Theme.acc : active ? Theme.acc.opacity(0.75) : Theme.line2, lineWidth: active || dropTargeted ? 1.5 : 1)
                    .padding(split ? -2 : 0)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: drop == .right ? .trailing : .bottom) {
            // Onto its right or bottom edge, a new pane is split off there.
            if let drop, drop != .here {
                Rectangle()
                    .fill(Theme.acc.opacity(0.16))
                    .overlay(Rectangle().strokeBorder(Theme.acc, lineWidth: 1.5))
                    .frame(width: drop == .right ? size.width / 2 : nil, height: drop == .below ? size.height / 2 : nil)
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frame in
            hubs.frames[pane] = frame
            size = frame.size
        }
        .onDrop(of: [.pi2Conversation], delegate: HubDrop(size: size, zone: $drop) { conversation, zone in
            model.dropInHub(conversation, on: pane, in: id, splitting: zone == .right ? .row : zone == .below ? .column : nil)
        })
    }
}

/// A conversation dragged from the sidebar over one of a hub's panes: onto the pane it shows there, onto its right or
/// bottom edge (the outer quarter) it gets a new pane split off on that side.
private struct HubDrop: DropDelegate {
    enum Zone { case here, right, below }

    let size: CGSize
    @Binding var zone: Zone?
    let dropped: @MainActor (Int, Zone) -> Bool

    private func zone(at point: CGPoint) -> Zone {
        if size.width > 0, point.x > size.width * 0.75 { return .right }
        if size.height > 0, point.y > size.height * 0.75 { return .below }
        return .here
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.pi2Conversation]) }
    func dropEntered(info: DropInfo) { zone = zone(at: info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = zone(at: info.location)
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target = zone(at: info.location)
        zone = nil
        guard let provider = info.itemProviders(for: [.pi2Conversation]).first else { return false }
        let dropped = self.dropped
        _ = provider.loadTransferable(type: ConversationDrag.self) { result in
            guard case .success(let item) = result else { return }
            Task { @MainActor in _ = dropped(item.id, target) }
        }
        return true
    }
}

/// What a header of one of several panes has besides its own: whether the pane has the focus, which tints it, and its
/// close button.
struct HubPaneHeader {
    let focused: Bool
    let close: (() -> Void)?
}

/// The close button of one of several panes.
struct HubPaneClose: View {
    let close: () -> Void
    var help = "Close this pane (⌃⌘W). The conversation stays in the sidebar."

    var body: some View {
        Button("Close Pane", systemImage: "xmark", action: close)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(Theme.tx3)
            .help(help)
    }
}

/// A pane just made: the project's working agents first, then its other conversations, and the board when no pane shows
/// it, to choose what the pane shows. A field at the top takes the keyboard and narrows the list; the arrow keys move
/// through it, Return shows the one marked, and Escape closes the pane.
private struct HubPanePicker: View {
    let model: AppModel
    let project: ProjectRow
    let layout: HubLayout
    let pane: UUID
    /// Whether this pane has the person's attention, so its field takes the keyboard.
    let focused: Bool
    @State private var query = ""
    @State private var marked = 0
    @FocusState private var fieldFocused: Bool
    private var engine: EngineClient { model.engine }

    private struct Choice: Identifiable, Equatable {
        enum Kind: Equatable { case board, working, other }
        let kind: Kind
        let conversation: Int?
        let title: String
        let agentId: String?
        let waiting: Bool
        var id: String { conversation.map(String.init) ?? "board" }
    }

    private var choices: [Choice] {
        let live = engine.projectStore.live(project.id)
        let shown = Set(layout.conversations)
        var all: [Choice] = []
        if layout.board == nil { all.append(Choice(kind: .board, conversation: nil, title: "The board", agentId: nil, waiting: false)) }
        for id in live.runs where !shown.contains(id) {
            guard let run = engine.projectStore.run(id) else { continue }
            all.append(Choice(kind: .working, conversation: id, title: run.title, agentId: run.agentId, waiting: run.waiting))
        }
        for other in live.others where !shown.contains(other.id) {
            all.append(Choice(kind: .other, conversation: other.id, title: other.title, agentId: other.agentId, waiting: false))
        }
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { choice in
            let text = "\(choice.title) \(engine.agent(choice.agentId)?.name ?? "")".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        let choices = self.choices
        let marked = min(self.marked, max(choices.count - 1, 0))
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.dashed").font(.system(size: 11)).foregroundStyle(Theme.tx3)
                Text("New pane").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tx)
                Spacer(minLength: 4)
                HubPaneClose(close: close, help: "Close this pane (Escape)")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(focused ? Theme.acc.opacity(0.10) : Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Show a conversation of \(project.name)…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Theme.card, in: .rect(cornerRadius: 8))
                    .focused($fieldFocused)
                    // Read as the key is pressed, not as the field was made: the field keeps the first closure it was given.
                    .onSubmit { chooseMarked() }
                    .onKeyPress(.downArrow) { step(1); return .handled }
                    .onKeyPress(.upArrow) { step(-1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onChange(of: query) { self.marked = 0 }
                if choices.isEmpty {
                    Text(query.isEmpty ? "Every conversation of the project is already in a pane." : "No conversation of the project matches.")
                        .font(.system(size: 12)).foregroundStyle(Theme.tx3)
                        .padding(.top, 4)
                }
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                                if index == 0 || choices[index - 1].kind != choice.kind {
                                    Text(choice.kind == .board ? "The project" : choice.kind == .working ? "Working now" : "Other conversations")
                                        .sectionLabel()
                                        .padding(.top, index == 0 ? 2 : 8).padding(.horizontal, 8)
                                }
                                row(choice, marked: index == marked)
                                    .id(choice.id)
                            }
                        }
                    }
                    .onChange(of: marked) { if choices.indices.contains(marked) { scroller.scrollTo(choices[marked].id) } }
                }
                Text("↑↓ to choose, Return to show it here, Escape to close the pane. You can also drag a conversation here from the sidebar.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tx3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window)
        .onAppear { if focused { fieldFocused = true } }
        .onChange(of: focused) { _, focused in fieldFocused = focused }
    }

    private func row(_ choice: Choice, marked: Bool) -> some View {
        Button { choose(choice) } label: {
            HStack(spacing: 8) {
                switch choice.kind {
                case .board:
                    Image(systemName: "rectangle.grid.1x2").foregroundStyle(Theme.tx2).frame(width: 16)
                case .working:
                    if choice.waiting {
                        Circle().fill(Theme.warn).frame(width: 7, height: 7).frame(width: 16)
                    } else {
                        Spinner().frame(width: 16)
                    }
                case .other:
                    AgentAvatar(agent: engine.agent(choice.agentId), size: 16)
                }
                Text(choice.kind == .board ? choice.title : choice.title.isEmpty ? "New conversation" : choice.title)
                    .lineLimit(1)
                    .foregroundStyle(Theme.tx)
                Spacer(minLength: 4)
                if let agent = engine.agent(choice.agentId) {
                    Text(agent.name).font(.system(size: 11)).foregroundStyle(Theme.tx3).lineLimit(1)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(marked ? Theme.card2 : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(choice.kind == .board ? "Show the project's board in this pane" : "Show this conversation in this pane")
    }

    private func step(_ by: Int) {
        let count = choices.count
        marked = min(max(min(marked, max(count - 1, 0)) + by, 0), max(count - 1, 0))
    }

    private func chooseMarked() {
        let choices = self.choices
        guard !choices.isEmpty else { return }
        choose(choices[min(marked, choices.count - 1)])
    }

    private func choose(_ choice: Choice) {
        let id = project.id
        if let conversation = choice.conversation {
            model.engine.openConversation(conversation)
            model.hubs.update(id) { $0.put(conversation, in: pane) }
            model.hubs.focus(pane, in: id, keyboard: true)
        } else {
            model.hubs.update(id) { $0.showBoard(in: pane) }
        }
    }

    private func close() {
        model.hubs.update(project.id) { $0.close(pane) }
    }
}

// MARK: - Commands

/// The View menu's pane commands with the projects preview on: they act on the shown hub's panes, and say why they do
/// not apply elsewhere (the Dashboard, a shared page, chat mode). A view of its own, so that what it reads draws this menu
/// again and not every scene (#436).
struct HubPaneCommands: View {
    let model: AppModel

    var body: some View {
        let refusal = model.paneRefusal
        let project = model.shownProject
        let layout = project.map { model.hubs.layout($0) }
        let full = layout.map { !$0.canSplit } ?? false
        let full6 = "A hub holds up to \(HubLayout.maxPanes) panes. Close one first."
        Button("Split Right") { model.splitHubPane(.row) }
            .keyboardShortcut("d")
            .disabled(refusal != nil || full)
            .help(refusal ?? (full ? full6 : "Split the focused pane, with a new pane on its right"))
        Button("Split Down") { model.splitHubPane(.column) }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(refusal != nil || full)
            .help(refusal ?? (full ? full6 : "Split the focused pane, with a new pane below it"))
        Button("Close Pane") { model.closeHubPane() }
            .keyboardShortcut("w", modifiers: [.command, .control])
            .disabled(refusal != nil || !model.canCloseHubPane)
            .help(refusal ?? (model.canCloseHubPane ? "Close the focused pane. Its conversation stays in the sidebar." : "The board alone stays: there is no pane to close."))
        let stops = model.hubPaneStops
        Button("Next Pane") { model.moveHubPane(1) }
            .keyboardShortcut("]")
            .disabled(refusal != nil || stops < 2)
            .help(refusal ?? (stops < 2 ? "There is one pane on screen." : "Move to the next pane, the conversation with the orchestrator among them"))
        Button("Previous Pane") { model.moveHubPane(-1) }
            .keyboardShortcut("[")
            .disabled(refusal != nil || stops < 2)
            .help(refusal ?? (stops < 2 ? "There is one pane on screen." : "Move to the previous pane, the conversation with the orchestrator among them"))
        Menu("Layout") {
            ForEach(PaneLayout.all.filter { $0.count <= HubLayout.maxPanes }) { layout in
                let why = model.hubLayoutRefusal(layout)
                Button("\(layout.name) (\(layout.count))") { model.applyHubLayout(layout) }
                    .disabled(why != nil)
                    .help(why ?? "Show the hub's panes this way. What they show stays; panes left over show the project's working agents.")
            }
            Divider()
            Button("Even Out Panes") { model.evenOutHubPanes() }
                .disabled(refusal != nil || layout?.isSplit != true)
                .help(refusal ?? (layout?.isSplit == true ? "Give every pane equal room" : "There is one pane."))
        }
        .disabled(refusal != nil)
        .help(refusal ?? "Ready-made ways to divide the hub's panes")
    }
}
