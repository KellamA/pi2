
// The panes of a project's hub (#657): the place beside the conversation with the orchestrator, where the board shows,
// divided with the same tree the old screens' panes use. Here, apart from SwiftUI and the engine, so that
// `pi2-layout-check` checks its rules built with optimisation, as it checks the tree's (#134). The app keeps one for each
// project (`ProjectHubs`) and draws it (`HubPanes.swift`); docs/projects.md, 10.1, says what is remembered of it.

import Foundation

/// What one of a hub's panes shows.
public enum HubPaneContent: Equatable, Sendable {
    /// The project's board, its tabs and what they show. At most one pane shows it.
    case board
    /// One of the project's conversations: an agent's, a sub-chat, an earlier one.
    case conversation(Int)
    /// A pane just made, which offers the project's conversations to choose from.
    case picker
}

/// A hub's panes: the tree, the pane with the person's attention, and the one pane that shows the board, if one does. One
/// pane showing the board is the hub as it always was; one pane showing a conversation is an agent's conversation in place
/// of the board (#473). Whatever is done to it, the board can be reached: when no pane shows a conversation, one shows the
/// board.
public struct HubLayout: Codable, Equatable, Sendable {
    /// More would not fit beside the conversation on any screen: six is two rows of three at the smallest width each.
    public static let maxPanes = 6
    /// A pane's least width, in points: with the divider beside it, the 320 points each column of the hub needs, so that
    /// one pane beside the conversation needs the 640 the hub always needed for both panels (`HubFold.narrowWidth`).
    public static let minimumWidth: Double = 319
    /// A pane's least height: its header, a message field of one line, and a little of the conversation above it.
    public static let minimumHeight: Double = 180
    /// The room between two panes, which holds the divider.
    public static let gutter: Double = 6

    public private(set) var root: PaneNode
    public private(set) var focused: UUID
    /// The pane that shows the board. Its own `conversation` is always nil.
    public private(set) var board: UUID?
    /// The pane showing a conversation that had the person's attention last: where a conversation opened from the board
    /// goes, so that the board one is working from stays (`openTarget`).
    public private(set) var lastConversation: UUID?

    /// The board alone.
    public init() {
        let pane = PaneNode.pane()
        root = pane
        focused = pane.id
        board = pane.id
        lastConversation = nil
    }

    public var panes: [PaneNode] { root.leaves }
    public var isSplit: Bool { !root.isPane }
    public var canSplit: Bool { panes.count < Self.maxPanes }
    /// The hub as it always was: one pane, showing the board.
    public var isBoardOnly: Bool { root.isPane && board == root.id }
    /// The conversations shown, in reading order.
    public var conversations: [Int] { panes.compactMap(\.conversation) }
    public var focusedConversation: Int? { root.find(focused)?.conversation }

    public func content(of pane: UUID) -> HubPaneContent? {
        guard let node = root.find(pane), node.isPane else { return nil }
        if pane == board { return .board }
        return node.conversation.map { .conversation($0) } ?? .picker
    }

    public func pane(showing conversation: Int) -> UUID? { panes.first { $0.conversation == conversation }?.id }

    public mutating func focus(_ pane: UUID) {
        guard let node = root.find(pane), node.isPane else { return }
        focused = pane
        if node.conversation != nil { lastConversation = pane }
    }

    /// Where a conversation opened from elsewhere (the sidebar, Now, the Work tab, a link) goes when no pane shows it and
    /// it is not given a pane of its own: the focused pane, unless that shows the board beside other panes. Then it is the
    /// pane whose conversation was focused last, or the first other pane, so that opening one from the board keeps the
    /// board in view.
    public var openTarget: UUID {
        guard isSplit, focused == board else { return focused }
        if let last = lastConversation, last != board, root.find(last)?.isPane == true { return last }
        return panes.first { $0.id != board }?.id ?? focused
    }

    /// Shows a conversation in a pane, which takes the person's attention. A pane that already shows it is given this
    /// pane's content instead, so the two swap, the board with them.
    public mutating func put(_ conversation: Int, in pane: UUID) {
        guard let previous = content(of: pane) else { return }
        if let other = self.pane(showing: conversation), other != pane { set(previous, in: other) }
        set(.conversation(conversation), in: pane)
        focus(pane)
    }

    /// Brings the board into view: its own pane, focused, if one shows it; else in place of what `pane` shows, or the
    /// focused pane. Asked for in another pane than its own, the board moves there and the two panes swap.
    public mutating func showBoard(in pane: UUID? = nil) {
        if let board, pane == nil || pane == board {
            focused = board
            return
        }
        let target = pane ?? focused
        guard let here = content(of: target) else { return }
        if let old = board { set(here, in: old) }
        set(.board, in: target)
        focused = target
    }

    /// Splits a pane in two, the new one after it showing `conversation`, or the picker, and focused. A pane in a split the
    /// same way joins it, as the old panes do. Nil when there is no room for another pane, or no such pane.
    @discardableResult
    public mutating func split(_ pane: UUID, _ axis: SplitAxis, showing conversation: Int? = nil) -> UUID? {
        guard canSplit, root.find(pane)?.isPane == true else { return nil }
        if let conversation, self.pane(showing: conversation) != nil { return nil }
        let new = PaneNode.pane(conversation)
        root.split(pane, axis, adding: new)
        focus(new.id)
        return new.id
    }

    /// Closes a pane: its room goes to its neighbour, and the attention to the pane before it. The only pane, closed,
    /// shows the board instead; and when the last pane showing a conversation closes and none shows the board, the focused
    /// pane shows it. Says whether anything changed: the board alone stays as it is.
    @discardableResult
    public mutating func close(_ pane: UUID) -> Bool {
        guard root.find(pane)?.isPane == true else { return false }
        guard isSplit else {
            guard board != pane else { return false }
            set(.board, in: pane)
            focused = pane
            lastConversation = nil
            return true
        }
        let order = panes.map(\.id)
        let index = order.firstIndex(of: pane) ?? 0
        root.remove(pane)
        if board == pane { board = nil }
        if lastConversation == pane { lastConversation = nil }
        let remaining = panes
        if focused == pane { focused = remaining[min(max(index - 1, 0), remaining.count - 1)].id }
        if board == nil, !remaining.contains(where: { $0.conversation != nil }) { set(.board, in: focused) }
        return true
    }

    /// Closes the panes showing conversations that are gone (archived or deleted). Says whether any did.
    @discardableResult
    public mutating func forget(where gone: (Int) -> Bool) -> Bool {
        var changed = false
        for pane in panes where pane.conversation.map(gone) == true { changed = close(pane.id) || changed }
        return changed
    }

    /// Sets how a split divides its room.
    public mutating func resize(_ split: UUID, _ fractions: [Double]) {
        root.modify(split) { node in
            guard !node.isPane, node.fractions.count == fractions.count, fractions.allSatisfy({ $0 > 0 && $0.isFinite }) else { return }
            node.fractions = fractions
        }
    }

    /// Gives one split's panes, or with nil every pane, equal room.
    public mutating func equalize(_ split: UUID? = nil) {
        if let split {
            root.modify(split) { $0.equalize(deep: false) }
        } else {
            root.equalize(deep: true)
        }
    }

    /// Switches to a ready-made layout of up to `maxPanes` panes. What the panes show stays, the board with it, in reading
    /// order, with the focused one kept if there is not room for all; panes left over get `recent`'s conversations not yet
    /// shown, then the picker. Says whether it was applied.
    @discardableResult
    public mutating func apply(_ layout: PaneLayout, recent: [Int]) -> Bool {
        var tree = layout.make()
        let room = tree.leaves.count
        guard room <= Self.maxPanes else { return false }
        let current = content(of: focused)
        var items: [HubPaneContent] = panes.compactMap { content(of: $0.id) }.filter { $0 != .picker }
        if let current, current != .picker, let index = items.firstIndex(of: current), index >= room {
            items.remove(at: index)
            items.insert(current, at: room - 1)
        }
        items += recent.filter { !items.contains(.conversation($0)) }.map { HubPaneContent.conversation($0) }
        items = Array(items.prefix(room))
        tree.fill(items.map { if case .conversation(let id) = $0 { id } else { nil } })
        let leaves = tree.leaves
        root = tree
        board = zip(leaves, items).first { $0.1 == .board }?.0.id
        lastConversation = nil
        focused = zip(leaves, items).first { $0.1 == current }?.0.id ?? leaves[0].id
        if board == nil, !leaves.contains(where: { $0.conversation != nil }) { set(.board, in: leaves[0].id) }
        if let id = root.find(focused), id.conversation != nil { lastConversation = focused }
        return true
    }

    private mutating func set(_ content: HubPaneContent, in pane: UUID) {
        if content == .board || content == .picker, lastConversation == pane { lastConversation = nil }
        switch content {
        case .board:
            board = pane
            root.modify(pane) { $0.conversation = nil }
        case .conversation(let id):
            if board == pane { board = nil }
            root.modify(pane) { $0.conversation = id }
        case .picker:
            if board == pane { board = nil }
            root.modify(pane) { $0.conversation = nil }
        }
    }

    // MARK: Keeping

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// A hub's panes read back, or nil when nothing is saved, it cannot be read, or it is not a tree the app can lay out
    /// (a damaged one, or more than `maxPanes` panes): the hub then shows the board alone. What does not hold of a good
    /// layout is put right: a focus or a board that is not on a pane, a board that also names a conversation, a
    /// conversation in two panes (the later shows the picker), and no conversation with no board.
    public static func restore(_ data: Data?) -> HubLayout? {
        guard let data, var saved = try? JSONDecoder().decode(HubLayout.self, from: data),
              saved.root.isValid, (1...maxPanes).contains(saved.root.leaves.count) else { return nil }
        saved.normalise()
        return saved
    }

    private mutating func normalise() {
        let leaves = panes
        if root.find(focused)?.isPane != true { focused = leaves[0].id }
        if let board, root.find(board)?.isPane != true { self.board = nil }
        if let board { root.modify(board) { $0.conversation = nil } }
        var seen = Set<Int>()
        for pane in leaves {
            guard let conversation = pane.conversation else { continue }
            if !seen.insert(conversation).inserted { root.modify(pane.id) { $0.conversation = nil } }
        }
        if let last = lastConversation, root.find(last).map({ $0.isPane && $0.conversation != nil }) != true { lastConversation = nil }
        if board == nil, !panes.contains(where: { $0.conversation != nil }) { set(.board, in: focused) }
    }

    // MARK: Sizes

    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// The least room a node needs for every pane in it to have its least size, with the gutters between them.
    public static func minimum(_ node: PaneNode, pane: Size = Size(width: minimumWidth, height: minimumHeight), gutter: Double = gutter) -> Size {
        guard !node.isPane else { return pane }
        let sizes = node.children.map { minimum($0, pane: pane, gutter: gutter) }
        let gutters = gutter * Double(node.children.count - 1)
        switch node.axis {
        case .row: return Size(width: sizes.map(\.width).reduce(0, +) + gutters, height: sizes.map(\.height).max() ?? pane.height)
        case .column: return Size(width: sizes.map(\.width).max() ?? pane.width, height: sizes.map(\.height).reduce(0, +) + gutters)
        }
    }

    /// How many panes are side by side where the tree is widest: the hub counts each as a column beside the conversation.
    public static func across(_ node: PaneNode) -> Int {
        guard !node.isPane else { return 1 }
        let counts = node.children.map(across)
        return node.axis == .row ? counts.reduce(0, +) : counts.max() ?? 1
    }

    /// Whether every pane of the tree has its least size in a room this big.
    public func fits(width: Double, height: Double) -> Bool {
        let least = Self.minimum(root)
        return least.width <= width + 0.5 && least.height <= height + 0.5
    }

    /// How a split shares `room` (its length less the gutters) among its children: by their shares, except that none gets
    /// less than its least, the others giving way in proportion to their shares. With less room than all the leasts
    /// together, each gets its least, and the split is longer than its room: what holds it then scrolls.
    public static func lengths(fractions: [Double], least: [Double], room: Double) -> [Double] {
        guard fractions.count == least.count, !least.isEmpty else { return least }
        guard room > least.reduce(0, +) else { return least }
        var lengths = fractions.map { $0 * room }
        var fixed = Set<Int>()
        while true {
            let short = lengths.indices.filter { !fixed.contains($0) && lengths[$0] < least[$0] }
            if short.isEmpty { break }
            for index in short {
                fixed.insert(index)
                lengths[index] = least[index]
            }
            let free = lengths.indices.filter { !fixed.contains($0) }
            let shares = free.map { fractions[$0] }.reduce(0, +)
            guard !free.isEmpty, shares > 0 else { break }
            let left = room - fixed.map { lengths[$0] }.reduce(0, +)
            for index in free { lengths[index] = left * fractions[index] / shares }
        }
        return lengths
    }
}
