// How a project's hub divides the room beside its orchestrator into panes, as a tree (#657). Its own module so that
// `pi2-layout-check` can check it built with optimisation, which is how the released app is built (#134). Nothing here
// knows about SwiftUI or the engine; `HubLayout` keeps the tree for each project and the app draws it (HubPanes.swift).

import Foundation

/// Which way a split lays out what it holds.
public enum SplitAxis: String, Codable, Sendable {
    /// Side by side, with dividers that slide left and right.
    case row
    /// One above another, with dividers that slide up and down.
    case column
}

/// The conversation area as a tree: a pane showing one conversation, or a split dividing its room between the nodes it
/// holds. A node with no children is a pane.
///
/// Never give a node a value it still holds, such as `self = children[0]`. Optimised builds (Swift 6.4) copy straight
/// from the child's place in `children` into the node, field by field, and release the node's old `children` (the
/// array the child lives in) before the last field is copied: the result had a `fractions` array with a null buffer,
/// and the app crashed saving it (#134). Take the child out of the array first, as `collapse` does.
public struct PaneNode: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// For a pane: the conversation it shows. Nil is an empty pane, which offers a choice.
    public var conversation: Int?
    /// For a split: which way it divides.
    public var axis: SplitAxis
    public var children: [PaneNode]
    /// For a split: each child's share of the room, adding up to 1.
    public var fractions: [Double]

    public init(id: UUID = UUID(), conversation: Int? = nil, axis: SplitAxis = .row, children: [PaneNode] = [], fractions: [Double] = []) {
        self.id = id
        self.conversation = conversation
        self.axis = axis
        self.children = children
        self.fractions = fractions
    }

    public var isPane: Bool { children.isEmpty }

    public static func pane(_ conversation: Int? = nil) -> PaneNode { PaneNode(conversation: conversation) }

    public static func split(_ axis: SplitAxis, _ children: [PaneNode], _ fractions: [Double]? = nil) -> PaneNode {
        PaneNode(axis: axis, children: children, fractions: fractions ?? Array(repeating: 1 / Double(children.count), count: children.count))
    }

    /// Panes in reading order: left to right, top to bottom within each split.
    public var leaves: [PaneNode] { isPane ? [self] : children.flatMap(\.leaves) }

    public func find(_ id: UUID) -> PaneNode? {
        if self.id == id { return self }
        for child in children { if let found = child.find(id) { return found } }
        return nil
    }

    /// Changes the node with `id`, wherever it is. Says whether it found it.
    @discardableResult
    public mutating func modify(_ id: UUID, _ change: (inout PaneNode) -> Void) -> Bool {
        if self.id == id {
            change(&self)
            return true
        }
        for index in children.indices where children[index].modify(id, change) { return true }
        return false
    }

    /// The split directly holding the node with `id`, and where in it that node is.
    public func parent(of id: UUID) -> (split: PaneNode, index: Int)? {
        for (index, child) in children.enumerated() {
            if child.id == id { return (self, index) }
            if let found = child.parent(of: id) { return found }
        }
        return nil
    }

    /// Splits the pane with `id` in two, with `new` after it. A pane already in a split the same way joins it as a
    /// sibling, taking half of this pane's room, so three side by side stay one row with two dividers. Says whether
    /// there was such a pane.
    @discardableResult
    public mutating func split(_ id: UUID, _ axis: SplitAxis, adding new: PaneNode) -> Bool {
        guard find(id)?.isPane == true else { return false }
        if let (parent, index) = parent(of: id), parent.axis == axis {
            modify(parent.id) { split in
                let half = split.fractions[index] / 2
                split.fractions[index] = half
                split.fractions.insert(half, at: index + 1)
                split.children.insert(new, at: index + 1)
            }
        } else {
            // The new split is built around a copy of the pane, in an array of its own, before it takes the pane's
            // place, so the pane is never given a value it still holds.
            modify(id) { node in
                let old = node
                node = .split(axis, [old, new])
            }
        }
        return true
    }

    /// Takes the pane with `id` out of the tree. Its room goes to the neighbour before it, or the one after. A split
    /// left with one child is replaced by that child.
    public mutating func remove(_ id: UUID) {
        if let index = children.firstIndex(where: { $0.id == id }) {
            children.remove(at: index)
            let share = fractions.remove(at: index)
            if !fractions.isEmpty { fractions[max(index - 1, 0)] += share }
        } else {
            // A child split left with one child has already given way to it, in its own call.
            for index in children.indices { children[index].remove(id) }
        }
        if children.count == 1 { collapse() }
    }

    /// Replaces a split holding one child by that child. The child is taken out of `children` first: see the note on
    /// `PaneNode` for why `self = children[0]` must not be written here.
    private mutating func collapse() {
        let only = children.removeLast()
        self = only
    }

    /// Gives the panes, in reading order, these conversations.
    public mutating func fill(_ conversations: [Int?]) {
        var next = 0
        fill(conversations, from: &next)
    }

    private mutating func fill(_ conversations: [Int?], from next: inout Int) {
        if isPane {
            conversation = next < conversations.count ? conversations[next] : nil
            next += 1
        } else {
            for index in children.indices { children[index].fill(conversations, from: &next) }
        }
    }

    public mutating func equalize(deep: Bool) {
        guard !isPane else { return }
        fractions = Array(repeating: 1 / Double(children.count), count: children.count)
        if deep { for index in children.indices { children[index].equalize(deep: true) } }
    }

    /// Whether the tree is one this app can lay out: every split's shares match its children and are sensible, and no
    /// two nodes share an id.
    public var isValid: Bool {
        guard isWellFormed else { return false }
        var seen = Set<UUID>()
        return allIDs.allSatisfy { seen.insert($0).inserted }
    }

    private var isWellFormed: Bool {
        if isPane { return true }
        guard children.count >= 2, fractions.count == children.count, fractions.allSatisfy({ $0 > 0 && $0.isFinite }) else { return false }
        return children.allSatisfy(\.isWellFormed)
    }

    private var allIDs: [UUID] { [id] + children.flatMap(\.allIDs) }
}

/// A ready-made arrangement of panes, each within the six a hub holds (`HubLayout.maxPanes`).
public struct PaneLayout: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let make: @Sendable () -> PaneNode

    public var count: Int { make().leaves.count }

    private static func row(_ count: Int) -> PaneNode { .split(.row, (0..<count).map { _ in .pane() }) }
    private static func column(_ count: Int) -> PaneNode { .split(.column, (0..<count).map { _ in .pane() }) }
    /// Rows of panes, each row with its own dividers.
    private static func grid(columns: Int, rows: Int) -> PaneNode { .split(.column, (0..<rows).map { _ in row(columns) }) }

    public static let all: [PaneLayout] = [
        PaneLayout(id: "1", name: "Single") { .pane() },
        PaneLayout(id: "2-row", name: "Side by side") { row(2) },
        PaneLayout(id: "2-column", name: "One above the other") { column(2) },
        PaneLayout(id: "3-row", name: "Three columns") { row(3) },
        PaneLayout(id: "3-big-left", name: "One big, two on the right") { .split(.row, [.pane(), column(2)]) },
        PaneLayout(id: "3-big-right", name: "Two on the left, one big") { .split(.row, [column(2), .pane()]) },
        PaneLayout(id: "3-big-top", name: "One big, two below") { .split(.column, [.pane(), row(2)]) },
        PaneLayout(id: "3-column", name: "Three rows") { column(3) },
        PaneLayout(id: "4-grid", name: "Two by two") { grid(columns: 2, rows: 2) },
        PaneLayout(id: "4-row", name: "Four columns") { row(4) },
        PaneLayout(id: "4-big-left", name: "One big, three on the right") { .split(.row, [.pane(), column(3)]) },
        PaneLayout(id: "5-big-left", name: "One big, four around it") { .split(.row, [.pane(), grid(columns: 2, rows: 2)]) },
        PaneLayout(id: "6-grid", name: "Three by two") { grid(columns: 3, rows: 2) },
    ]
}
