
import SwiftUI
import UniformTypeIdentifiers
import PaneKit

// What both uses of panes share: the old screens' (Workspace.swift, which goes with #483) and a project's hub's
// (HubPanes.swift, #657). Moved here from Workspace.swift so that it outlasts the old screens: the split with its
// dividers, the watch on clicks that tells which pane a click landed in, a conversation dragged from the sidebar, the
// environment values a conversation in a pane reads, and a conversation's title as a pane shows it.

enum PaneMetrics {
    /// The room between two panes, which holds the divider.
    static let gutter: CGFloat = 6
}

/// What a split's dividers do to the tree they belong to.
struct PaneSplitActions {
    /// Sets a split's shares, while a divider is dragged.
    let resize: (UUID, [Double]) -> Void
    /// Gives a split's panes equal room, on a double-click of a divider.
    let equalize: (UUID) -> Void
    /// Keeps the tree, once a drag ends.
    let save: () -> Void
}

/// A node of a pane tree: a pane, drawn by `leaf`, or a split of more nodes.
struct PaneTreeView<Leaf: View>: View {
    let node: PaneNode
    /// The coordinate space the panes are measured in, which a divider's drag is measured in too.
    let space: String
    /// The least room a node keeps, for a hub's panes (#657); nil for the old panes, which share their room by their
    /// shares alone and keep 180 by 130 points only while a divider is dragged.
    let least: ((PaneNode) -> CGSize)?
    let actions: PaneSplitActions
    let leaf: (PaneNode) -> Leaf

    var body: some View {
        if node.isPane {
            leaf(node)
        } else {
            PaneSplit(node: node, space: space, least: least, actions: actions, leaf: leaf)
        }
    }
}

/// A split: its nodes with a divider between each two that slides to share the room differently.
struct PaneSplit<Leaf: View>: View {
    let node: PaneNode
    let space: String
    let least: ((PaneNode) -> CGSize)?
    let actions: PaneSplitActions
    let leaf: (PaneNode) -> Leaf
    /// The shares when the current drag began.
    @State private var dragStart: [Double]?
    @State private var dragging: Int?

    /// The least room the old panes keep when a divider is dragged towards one, when there is that much to go round.
    private static var minimumWidth: CGFloat { 180 }
    private static var minimumHeight: CGFloat { 130 }

    private var horizontal: Bool { node.axis == .row }

    /// Each child's least length along the split, when it has one.
    private var leasts: [CGFloat]? {
        guard let least else { return nil }
        return node.children.map { child in
            let size = least(child)
            return horizontal ? size.width : size.height
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let length = horizontal ? geometry.size.width : geometry.size.height
            let room = max(length - PaneMetrics.gutter * CGFloat(node.children.count - 1), 1)
            let lengths: [CGFloat] = leasts.map { leasts in
                HubLayout.lengths(fractions: node.fractions, least: leasts.map(Double.init), room: Double(room)).map { CGFloat($0) }
            } ?? node.fractions.map { room * CGFloat($0) }
            let stack = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                    let share = index < lengths.count ? lengths[index] : 0
                    PaneTreeView(node: child, space: space, least: least, actions: actions, leaf: leaf)
                        .frame(width: horizontal ? share : geometry.size.width, height: horizontal ? geometry.size.height : share)
                    if index < node.children.count - 1 {
                        SplitHandle(axis: node.axis, active: dragging == index)
                            .gesture(drag(index, room: room))
                            .onTapGesture(count: 2) { actions.equalize(node.id) }
                            .help("Drag to resize. Double-click to share the room evenly.")
                    }
                }
            }
        }
    }

    /// Moves the divider after child `index`, between it and the next.
    private func drag(_ index: Int, room: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { value in
                let start = dragStart ?? node.fractions
                if dragStart == nil {
                    dragStart = start
                    dragging = index
                }
                guard start.count == node.fractions.count, index + 1 < start.count else { return }
                let moved = Double((horizontal ? value.translation.width : value.translation.height) / room)
                let pair = start[index] + start[index + 1]
                let before: Double, after: Double
                if let leasts, index + 1 < leasts.count {
                    // Each side keeps its least; with less room than that, the divider stays.
                    before = Double(leasts[index] / room)
                    after = Double(leasts[index + 1] / room)
                    guard before + after < pair else { return }
                } else {
                    before = min(Double((horizontal ? Self.minimumWidth : Self.minimumHeight) / room), pair / 2)
                    after = before
                }
                var fractions = start
                fractions[index] = min(max(start[index] + moved, before), pair - after)
                fractions[index + 1] = pair - fractions[index]
                actions.resize(node.id, fractions)
            }
            .onEnded { _ in
                dragStart = nil
                dragging = nil
                actions.save()
            }
    }
}

/// The gutter between two panes, which can be dragged.
private struct SplitHandle: View {
    let axis: SplitAxis
    let active: Bool
    @State private var hovering = false

    var body: some View {
        let lit = hovering || active
        Rectangle()
            .fill(lit ? Theme.acc.opacity(0.18) : Color.clear)
            .frame(width: axis == .row ? PaneMetrics.gutter : nil, height: axis == .column ? PaneMetrics.gutter : nil)
            .overlay {
                Capsule()
                    .fill(lit ? Theme.acc : Theme.line2)
                    .frame(width: axis == .row ? 2 : 26, height: axis == .row ? 26 : 2)
            }
            .contentShape(.rect)
            .pointerStyle(axis == .row ? .columnResize : .rowResize)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: lit)
            .accessibilityLabel(axis == .row ? "Divider between panes side by side" : "Divider between panes one above the other")
    }
}

/// Watches clicks in the panes, without taking them, so a click anywhere in a pane — the conversation page is a web view
/// SwiftUI's gestures never see — moves the person's attention to that pane.
struct PaneClickMonitor: NSViewRepresentable {
    let onClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.onClick = onClick
    }

    static func dismantleNSView(_ view: Watcher, coordinator: ()) {
        view.stop()
    }

    final class Watcher: NSView {
        var onClick: (CGPoint) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let windowNumber = event.windowNumber
                let location = event.locationInWindow
                MainActor.assumeIsolated { self?.clicked(at: location, inWindow: windowNumber) }
                return event
            }
        }

        private func clicked(at location: NSPoint, inWindow windowNumber: Int) {
            guard let window, window.windowNumber == windowNumber else { return }
            let point = convert(location, from: nil)
            guard bounds.contains(point) else { return }
            // SwiftUI measures from the top left.
            onClick(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

extension EngineClient {
    /// A conversation's title as the window and its pane show it.
    func conversationTitle(_ id: Int) -> String {
        // One that is archived is not in the sidebar's list; its title comes with its state.
        let title = conversations.first { $0.id == id }?.title ?? archived.first { $0.id == id }?.title ?? open[id]?.state?.title ?? ""
        return title.isEmpty ? "New conversation" : title
    }

    /// Who a conversation is with, and for a sub-chat, whose it is.
    func conversationSubtitle(_ id: Int) -> String {
        let agent = agent(open[id]?.state?.agent.agentId)?.name ?? ""
        guard let parentID = conversations.first(where: { $0.id == id })?.parent,
              let parent = conversations.first(where: { $0.id == parentID }) else { return agent }
        return "\(agent) · sub-chat of “\(parent.title.isEmpty ? "New conversation" : parent.title)”"
    }
}

extension EnvironmentValues {
    /// Whether the view is in one of several panes, where room is short.
    @Entry var inSplitPane = false
    /// In a project's hub: shows a conversation in the hub, as the hub's links to another conversation do (#632). Nil
    /// elsewhere, where a link selects the conversation.
    @Entry var showInHub: ((Int) -> Void)? = nil
}

/// A conversation being dragged from the sidebar onto a pane.
struct ConversationDrag: Codable, Transferable {
    let id: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pi2Conversation)
    }
}

extension UTType {
    /// Declared in the app's Info.plist (see build.sh). Its own type, so a text field never takes it as text.
    static let pi2Conversation = UTType(exportedAs: "dev.pi2.conversation")
}
