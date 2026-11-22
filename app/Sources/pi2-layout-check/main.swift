// Checks PaneKit, the tree of panes behind a project hub's panes: splitting, closing panes down to one, giving panes
// equal room, filling them with conversations, encoding the tree and reading it back, and that a tree saved damaged or
// unreadable is not taken rather than a crash at launch. Then a project hub's panes themselves (`HubLayout`, #657): the board in one pane at most and always within reach, where an opened conversation goes, the ready-made
// layouts, the least size every pane keeps, and damaged saved panes.
//
//   cd app && swift build -c release --product pi2-layout-check && .build/release/pi2-layout-check
//
// Build it with optimisation, as above: that is how the app is released, and the crash it was written for (#134,
// closing a pane) only happened in an optimised build. CI runs it that way. Every step checks the whole tree
// (`isValid`, shares adding up to 1, encoding and decoding it), and a damaged tree may crash rather than fail, so the
// last line printed before a crash says which step it was. Exits 1 if anything failed.

import Foundation
import PaneKit

setlinebuf(stdout)
#if DEBUG
print("note  built without optimisation; the released app is optimised, so check with `swift build -c release` too")
#endif

var failures = 0
var steps = 0
var audited = 0
func check(_ name: String, _ holds: Bool, _ detail: @autoclosure () -> String = "") {
    if holds { return }
    failures += 1
    let more = detail()
    print("FAIL  \(name)" + (more.isEmpty ? "" : "\n      " + more))
}

/// Runs a group of checks and says how it went.
func group(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print(failures == before ? "ok    \(name)" : "FAIL  \(name): \(failures - before) failed")
}

/// Where a crash happened, if one does. Each step that changes a tree is noted here first, and a crash (what #134 was)
/// prints the step it happened in. `--verbose` prints every step as well.
let verbose = CommandLine.arguments.contains("--verbose")
let stepCapacity = 1024
let currentStep = UnsafeMutablePointer<CChar>.allocate(capacity: stepCapacity)
currentStep.initialize(repeating: 0, count: stepCapacity)
func step(_ what: @autoclosure () -> String) {
    steps += 1
    let text = what()
    _ = text.withCString { strlcpy(currentStep, $0, stepCapacity) }
    if verbose { print("      \(text)") }
}
for signal in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT] {
    Foundation.signal(signal) { number in
        // Only what is safe in a signal handler: write the note out, then crash as the signal would have.
        let prefix = "CRASH during: "
        _ = prefix.withCString { write(2, $0, strlen($0)) }
        _ = write(2, currentStep, strlen(currentStep))
        _ = "\n".withCString { write(2, $0, 1) }
        Foundation.signal(number, SIG_DFL)
        raise(number)
    }
}

/// A small generator with a fixed seed, so a failure can be run again.
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func describe(_ node: PaneNode) -> String {
    if node.isPane { return node.conversation.map { "\($0)" } ?? "_" }
    let shares = node.fractions.map { String(format: "%.3g", $0) }.joined(separator: ",")
    return "\(node.axis == .row ? "row" : "col")[\(shares)](\(node.children.map(describe).joined(separator: " ")))"
}

/// Every split in the tree, the root first.
func splits(_ node: PaneNode) -> [PaneNode] { node.isPane ? [] : [node] + node.children.flatMap(splits) }

/// What has to hold of any tree the app is left with: it can be laid out, every split's shares add up to 1, and it
/// encodes and reads back as itself. Reading every share is also what found #134: the save crashed on a damaged one.
func audit(_ tree: PaneNode, _ context: @autoclosure () -> String) {
    audited += 1
    check("valid: \(context())", tree.isValid, describe(tree))
    for split in splits(tree) {
        let total = split.fractions.reduce(0, +)
        check("shares add up to 1: \(context())", abs(total - 1) < 1e-9, "\(total) in \(describe(split))")
    }
    let encoded = try? JSONEncoder().encode(tree)
    check("encodes: \(context())", encoded != nil)
    if let encoded {
        let decoded = try? JSONDecoder().decode(PaneNode.self, from: encoded)
        check("decodes as itself: \(context())", decoded == tree, describe(tree))
    }
}

/// A tree read back as the app would take it, or nil when it cannot be read or laid out: a damaged tree, or more than
/// sixteen panes.
func restore(_ data: Data?) -> PaneNode? {
    guard let data, let tree = try? JSONDecoder().decode(PaneNode.self, from: data), tree.isValid, (1...16).contains(tree.leaves.count) else { return nil }
    return tree
}

/// A tree with its panes given conversations 1, 2, 3… in reading order.
func numbered(_ tree: PaneNode) -> PaneNode {
    var tree = tree
    tree.fill(Array(1...tree.leaves.count))
    return tree
}

/// Closes the panes of `tree` one by one in `order` (indexes into its panes in reading order, at the start) until one
/// is left, checking the tree after each.
func closeAll(_ start: PaneNode, order: [Int], _ name: String) {
    var tree = start
    let original = start.leaves
    for (count, which) in order.dropLast().enumerated() {
        let pane = original[which]
        let before = tree.leaves
        step("\(name): closing pane \(which + 1) of \(original.count) in \(describe(tree))")
        tree.remove(pane.id)
        let context = "\(name), pane \(which + 1) closed after \(count) others"
        audit(tree, context)
        let after = tree.leaves
        check("one pane fewer: \(context)", after.count == before.count - 1, describe(tree))
        check("the pane is gone: \(context)", tree.find(pane.id) == nil, describe(tree))
        check("the others stay, in order: \(context)", after.map(\.id) == before.map(\.id).filter { $0 != pane.id }, describe(tree))
        check("conversations stay: \(context)", after.map(\.conversation) == before.filter { $0.id != pane.id }.map(\.conversation), describe(tree))
    }
    let last = original[order.last!]
    check("\(name): one pane left, the one not closed", tree.isPane && tree.id == last.id && tree.conversation == last.conversation, describe(tree))
    check("\(name): the pane left has no shares", tree.fractions.isEmpty && tree.children.isEmpty, describe(tree))
}

let layouts = PaneLayout.all.filter { $0.count > 1 }

group("closing a pane: the shapes in #134") {
    // Two side by side: the root gives way to the pane that stays.
    for which in 0..<2 {
        var tree = numbered(.split(.row, [.pane(), .pane()]))
        let keep = tree.leaves[1 - which]
        step("two panes, closing pane \(which + 1)")
        tree.remove(tree.leaves[which].id)
        audit(tree, "two panes, pane \(which + 1) closed")
        check("two panes, pane \(which + 1) closed: the other is the whole tree", tree == keep, describe(tree))
    }
    // A row holding a column: the column gives way to the pane left in it, and the row keeps its shares.
    for which in 1...2 {
        var tree = numbered(.split(.row, [.pane(), .split(.column, [.pane(), .pane()])], [0.3, 0.7]))
        step("a row holding a column, closing pane \(which + 1)")
        tree.remove(tree.leaves[which].id)
        audit(tree, "a row holding a column, pane \(which + 1) closed")
        check("a row holding a column, pane \(which + 1) closed", describe(tree) == "row[0.3,0.7](1 \(which == 1 ? 3 : 2))", describe(tree))
    }
    // Three in a row: the room goes to the neighbour before, or after for the first.
    for (which, expected) in [(0, "row[0.5,0.5](2 3)"), (1, "row[0.5,0.5](1 3)"), (2, "row[0.2,0.8](1 2)")] {
        var tree = numbered(.split(.row, [.pane(), .pane(), .pane()], [0.2, 0.3, 0.5]))
        step("three in a row, closing pane \(which + 1)")
        tree.remove(tree.leaves[which].id)
        audit(tree, "three in a row, pane \(which + 1) closed")
        check("three in a row, pane \(which + 1) closed", describe(tree) == expected, describe(tree))
    }
}

group("closing every pane of each ready-made layout, in several orders, down to one") {
    var random = Seeded(state: 134)
    for layout in layouts {
        let tree = numbered(layout.make())
        let count = tree.leaves.count
        audit(tree, "layout \(layout.id) as made")
        var orders: [(String, [Int])] = [
            ("first to last", Array(0..<count)),
            ("last to first", Array((0..<count).reversed())),
            ("from the middle out", Array(0..<count).sorted { abs(2 * $0 - count) < abs(2 * $1 - count) }),
        ]
        for round in 1...4 { orders.append(("shuffled \(round)", Array(0..<count).shuffled(using: &random))) }
        for (name, order) in orders { closeAll(tree, order: order, "layout \(layout.id), \(name)") }
        // Each pane closed on its own, from the layout as made.
        for which in 0..<count {
            var one = tree
            step("layout \(layout.id): closing only pane \(which + 1)")
            one.remove(tree.leaves[which].id)
            audit(one, "layout \(layout.id), only pane \(which + 1) closed")
        }
    }
}

group("closing something that is not a pane, or not there, changes nothing") {
    let tree = numbered(PaneLayout.all.first { $0.id == "5-big-left" }!.make())
    var unknown = tree
    unknown.remove(UUID())
    check("an unknown id", unknown == tree, describe(unknown))
}

group("splitting") {
    var tree = PaneNode.pane(1)
    let first = tree.id
    let second = PaneNode.pane(2)
    check("a pane splits", tree.split(first, .row, adding: second))
    audit(tree, "one pane split side by side")
    check("one pane split side by side", describe(tree) == "row[0.5,0.5](1 2)", describe(tree))
    // The same way again joins the row rather than nesting a new one in it.
    check("a pane in a row splits the same way", tree.split(second.id, .row, adding: .pane(3)))
    audit(tree, "a pane in a row split the same way")
    check("a pane in a row split the same way joins the row", describe(tree) == "row[0.5,0.25,0.25](1 2 3)", describe(tree))
    check("a pane in a row splits the other way", tree.split(first, .column, adding: .pane(4)))
    audit(tree, "a pane in a row split the other way")
    check("a pane in a row split the other way holds a column", describe(tree) == "row[0.5,0.25,0.25](col[0.5,0.5](1 4) 2 3)", describe(tree))
    let unchanged = tree
    check("a split is not split", !tree.split(tree.id, .row, adding: .pane()) && tree == unchanged, describe(tree))
    check("an unknown pane is not split", !tree.split(UUID(), .row, adding: .pane()) && tree == unchanged, describe(tree))

    // Up to sixteen panes, splitting a pane at random each time, a few times over.
    var random = Seeded(state: 0x5_1157)
    for round in 1...40 {
        var tree = PaneNode.pane()
        while tree.leaves.count < 16 {
            let leaves = tree.leaves
            let pane = leaves.randomElement(using: &random)!
            let axis: SplitAxis = Bool.random(using: &random) ? .row : .column
            let new = PaneNode.pane()
            step("round \(round): splitting a pane of \(describe(tree))")
            tree.split(pane.id, axis, adding: new)
            let context = "round \(round), \(leaves.count + 1) panes"
            audit(tree, context)
            var expected = leaves.map(\.id)
            expected.insert(new.id, at: expected.firstIndex(of: pane.id)! + 1)
            check("the new pane comes right after the one split: \(context)", tree.leaves.map(\.id) == expected, describe(tree))
            check("no split holds one the same way: \(context)", splits(tree).allSatisfy { split in split.children.allSatisfy { $0.isPane || $0.axis != split.axis } }, describe(tree))
        }
        // And back down to one, in an order of its own.
        closeAll(numbered(tree), order: Array(0..<16).shuffled(using: &random), "round \(round), closing the sixteen")
    }
}

group("equal room") {
    var tree = PaneLayout.all.first { $0.id == "5-big-left" }!.make()
    tree.modify(tree.id) { $0.fractions = [0.9, 0.1] }
    let grid = tree.children[1].id
    tree.modify(grid) { $0.fractions = [0.8, 0.2] }
    var one = tree
    one.modify(grid) { $0.equalize(deep: false) }
    audit(one, "one split given equal room")
    check("one split given equal room, the rest unchanged", one.fractions == [0.9, 0.1] && one.children[1].fractions == [0.5, 0.5], describe(one))
    tree.equalize(deep: true)
    audit(tree, "every split given equal room")
    check("every split given equal room", splits(tree).allSatisfy { split in split.fractions.allSatisfy { abs($0 - 1 / Double(split.children.count)) < 1e-12 } }, describe(tree))
}

group("filling panes with conversations") {
    var tree = PaneLayout.all.first { $0.id == "4-grid" }!.make()
    tree.fill([7, nil, 9])
    audit(tree, "four panes, three conversations")
    check("four panes, three conversations, in reading order", tree.leaves.map(\.conversation) == [7, nil, 9, nil], describe(tree))
    tree.fill(Array(1...6))
    check("four panes, six conversations: the first four", tree.leaves.map(\.conversation) == [1, 2, 3, 4], describe(tree))
}

group("a long run of everything, mixed") {
    var random = Seeded(state: 0x7_2026)
    var tree = PaneNode.pane()
    for turn in 1...4000 {
        let leaves = tree.leaves
        let pick = Int.random(in: 0..<10, using: &random)
        var what = ""
        switch pick {
        case 0...3 where leaves.count < 16:
            let pane = leaves.randomElement(using: &random)!
            what = "split"
            tree.split(pane.id, Bool.random(using: &random) ? .row : .column, adding: .pane())
        case 0...5 where leaves.count > 1:
            what = "close"
            step("turn \(turn): closing a pane of \(describe(tree))")
            tree.remove(leaves.randomElement(using: &random)!.id)
        case 6:
            what = "equal room"
            if let split = splits(tree).randomElement(using: &random) {
                tree.modify(split.id) { $0.equalize(deep: Bool.random(using: &random)) }
            }
        case 7:
            what = "resize"
            if let split = splits(tree).randomElement(using: &random) {
                let weights = split.children.map { _ in Double.random(in: 0.05...1, using: &random) }
                let total = weights.reduce(0, +)
                tree.modify(split.id) { $0.fractions = weights.map { $0 / total } }
                // Rounding can leave the shares a hair off 1; the app's own divider drags keep the sum of each pair.
                tree.modify(split.id) { $0.fractions[$0.fractions.count - 1] = 1 - $0.fractions.dropLast().reduce(0, +) }
            }
        case 8:
            what = "fill"
            tree.fill(leaves.map { _ in Int.random(in: 0..<3, using: &random) == 0 ? nil : Int.random(in: 1...500, using: &random) })
        default:
            what = "save and restore"
            let restored = restore(try? JSONEncoder().encode(tree))
            if let restored { tree = restored }
            check("turn \(turn): restored", restored != nil, describe(tree))
        }
        audit(tree, "turn \(turn), after \(what)")
    }
}

group("a saved tree that is damaged or unreadable is not taken") {
    func restores(_ json: String) -> PaneNode? { restore(Data(json.utf8)) }
    let a = "00000000-0000-0000-0000-00000000000A", b = "00000000-0000-0000-0000-00000000000B"
    let r = "00000000-0000-0000-0000-000000000001"
    func pane(_ id: String, _ conversation: Int? = nil) -> String {
        #"{"id":"\#(id)","axis":"row","children":[],"fractions":[]\#(conversation.map { #","conversation":\#($0)"# } ?? "")}"#
    }
    func split(_ fractions: String, _ children: String...) -> String {
        #"{"id":"\#(r)","axis":"row","children":[\#(children.joined(separator: ","))],"fractions":\#(fractions)}"#
    }
    func saved(_ root: String) -> String { root }

    let good = restores(saved(split("[0.25,0.75]", pane(a, 4), pane(b))))
    check("a tree as the app saves it reads back", good.map { describe($0) } == "row[0.25,0.75](4 _)")
    check("a single pane reads back", restores(saved(pane(a)))?.isPane == true)

    let damaged: [(String, Data?)] = [
        ("nothing saved", nil),
        ("empty", Data()),
        ("not JSON", Data("workspace".utf8)),
        ("not a tree", Data("[1,2,3]".utf8)),
        ("a tree inside an object", Data(#"{"root":\#(pane(a)),"focused":"\#(a)"}"#.utf8)),
        ("an empty tree", Data(saved("{}").utf8)),
        ("shares missing", Data(saved(#"{"id":"\#(r)","axis":"row","children":[\#(pane(a)),\#(pane(b))]}"#).utf8)),
        ("shares null", Data(saved(split("null", pane(a), pane(b))).utf8)),
        ("fewer shares than panes", Data(saved(split("[1]", pane(a), pane(b))).utf8)),
        ("more shares than panes", Data(saved(split("[0.5,0.25,0.25]", pane(a), pane(b))).utf8)),
        ("a split holding one pane", Data(saved(split("[1]", pane(a))).utf8)),
        ("a share of nothing", Data(saved(split("[0,1]", pane(a), pane(b))).utf8)),
        ("a share below nothing", Data(saved(split("[-0.5,1.5]", pane(a), pane(b))).utf8)),
        ("a share too large to hold", Data(saved(split("[1e400,0.5]", pane(a), pane(b))).utf8)),
        ("a share that is text", Data(saved(split(#"["half",0.5]"#, pane(a), pane(b))).utf8)),
        ("an axis it does not know", Data(saved(split("[0.5,0.5]", pane(a), pane(b)).replacingOccurrences(of: #""axis":"row""#, with: #""axis":"diagonal""#)).utf8)),
        ("two panes with one id", Data(saved(split("[0.5,0.5]", pane(a), pane(a))).utf8)),
        ("a pane with the split's id", Data(saved(split("[0.5,0.5]", pane(a), pane(r))).utf8)),
        ("seventeen panes", Data(saved(#"{"id":"\#(r)","axis":"row","children":[\#((1...17).map { _ in pane(UUID().uuidString) }.joined(separator: ","))],"fractions":[\#(Array(repeating: "0.0588", count: 17).joined(separator: ","))]}"#).utf8)),
        ("cut off part way", Data(saved(split("[0.5,0.5]", pane(a), pane(b))).dropLast(20).utf8)),
        ("nested ten thousand deep", Data((String(repeating: #"{"root":"#, count: 10_000) + String(repeating: "}", count: 10_000)).utf8)),
        ("splits nested ten thousand deep", Data(saved(String(repeating: #"{"id":"\#(r)","axis":"row","fractions":[1],"children":["#, count: 10_000) + pane(a) + String(repeating: "]}", count: 10_000)).utf8)),
    ]
    for (name, data) in damaged {
        step("restoring a tree: \(name)")
        let restored = restore(data)
        check("\(name): not restored", restored == nil, restored.map { describe($0) } ?? "")
    }
}

// MARK: - A project's hub (#657)

/// What has to hold of a hub's panes whatever was done to them: the tree can be laid out and saves and reads back as
/// itself, there are at most `maxPanes` panes, the focus is on one, the board is on one at most and names no
/// conversation, no conversation shows twice, and the board can be reached: a pane shows it, or one shows a conversation.
func auditHub(_ hub: HubLayout, _ context: @autoclosure () -> String) {
    let context = context()
    audit(hub.root, "hub: \(context)")
    let leaves = hub.panes
    check("hub: at most \(HubLayout.maxPanes) panes: \(context)", leaves.count <= HubLayout.maxPanes, describe(hub.root))
    check("hub: the focus is on a pane: \(context)", hub.root.find(hub.focused)?.isPane == true, describe(hub.root))
    if let board = hub.board {
        check("hub: the board is on a pane: \(context)", hub.root.find(board)?.isPane == true, describe(hub.root))
        check("hub: the board's pane names no conversation: \(context)", hub.root.find(board)?.conversation == nil, describe(hub.root))
    }
    check("hub: the board can be reached: \(context)", hub.board != nil || !hub.conversations.isEmpty, describe(hub.root))
    check("hub: no conversation shows twice: \(context)", Set(hub.conversations).count == hub.conversations.count, describe(hub.root))
    if let last = hub.lastConversation {
        check("hub: the last conversation's pane shows one: \(context)", hub.root.find(last)?.conversation != nil, describe(hub.root))
    }
    let restored = HubLayout.restore(hub.encoded())
    check("hub: saves and reads back as itself: \(context)", restored == hub, describe(hub.root))
}

/// Lays a tree out in a room as the hub draws it, with `HubLayout.lengths`, and gives each pane its size.
func layOut(_ node: PaneNode, width: Double, height: Double, into sizes: inout [UUID: HubLayout.Size]) {
    guard !node.isPane else {
        sizes[node.id] = HubLayout.Size(width: width, height: height)
        return
    }
    let horizontal = node.axis == .row
    let length = horizontal ? width : height
    let room = length - HubLayout.gutter * Double(node.children.count - 1)
    let least = node.children.map { child in
        let size = HubLayout.minimum(child)
        return horizontal ? size.width : size.height
    }
    let lengths = HubLayout.lengths(fractions: node.fractions, least: least, room: room)
    for (child, share) in zip(node.children, lengths) {
        layOut(child, width: horizontal ? share : width, height: horizontal ? height : share, into: &sizes)
    }
}

group("a hub: the board alone, then panes beside it, closed back to the board") {
    var hub = HubLayout()
    auditHub(hub, "as made")
    check("a hub starts on the board alone", hub.isBoardOnly && hub.content(of: hub.focused) == .board)
    check("the board alone does not close", !hub.close(hub.focused) && hub.isBoardOnly)
    // Opening a conversation with one pane puts it in place of the board, as #473 did.
    hub.put(11, in: hub.openTarget)
    auditHub(hub, "a conversation in place of the board")
    check("a conversation takes the board's place", !hub.isSplit && hub.board == nil && hub.focusedConversation == 11, describe(hub.root))
    check("closing the only pane shows the board", hub.close(hub.focused) && hub.isBoardOnly, describe(hub.root))
    // Board, then two conversations beside it.
    let boardPane = hub.focused
    let first = hub.split(boardPane, .row, showing: 21)
    let second = first.flatMap { hub.split($0, .row, showing: 22) }
    auditHub(hub, "the board and two conversations")
    check("three side by side are one row", describe(hub.root) == "row[0.5,0.25,0.25](_ 21 22)", describe(hub.root))
    check("a conversation already shown is not split off again", hub.split(boardPane, .row, showing: 21) == nil)
    // From the board, a conversation goes to the one focused last, and the board stays.
    hub.focus(first!)
    hub.focus(boardPane)
    check("from the board, one opens where a conversation was focused last", hub.openTarget == first, describe(hub.root))
    hub.put(23, in: hub.openTarget)
    auditHub(hub, "one opened from the board")
    check("the board stays", hub.board == boardPane && hub.conversations == [23, 22], describe(hub.root))
    // Putting a conversation shown in another pane swaps the two, the board with them.
    hub.put(22, in: boardPane)
    auditHub(hub, "a shown conversation put in the board's pane")
    check("the board moves to the pane that had the conversation", hub.board == second && hub.content(of: boardPane) == .conversation(22), describe(hub.root))
    // The board asked for in a pane swaps with what it shows.
    hub.showBoard(in: first!)
    auditHub(hub, "the board asked for in another pane")
    check("the board is still once", hub.board == first && hub.content(of: second!) == .conversation(23), describe(hub.root))
    // Closing the board leaves the conversations; closing those brings the board back.
    hub.close(first!)
    auditHub(hub, "the board's pane closed")
    check("the board's pane closed: no board, two conversations", hub.board == nil && hub.conversations.count == 2, describe(hub.root))
    hub.close(hub.panes[0].id)
    hub.close(hub.panes[0].id)
    auditHub(hub, "every conversation closed")
    check("every conversation closed: the board alone", hub.isBoardOnly, describe(hub.root))
    // A new pane shows the picker; closing the only conversation beside it shows the board there.
    var picker = HubLayout()
    picker.put(31, in: picker.focused)
    let empty = picker.split(picker.focused, .column)
    check("a new pane shows the picker", empty.flatMap { picker.content(of: $0) } == .picker, describe(picker.root))
    picker.close(picker.panes[0].id)
    auditHub(picker, "the last conversation closed beside the picker")
    check("the last conversation closed beside the picker: the board shows", picker.isBoardOnly, describe(picker.root))
    // Archived or deleted conversations close their panes.
    var gone = HubLayout()
    gone.put(41, in: gone.focused)
    _ = gone.split(gone.focused, .row, showing: 42)
    _ = gone.split(gone.focused, .row, showing: 43)
    check("panes of conversations gone close", gone.forget { $0 != 42 } && gone.conversations == [42], describe(gone.root))
    check("and the last one gone shows the board", gone.forget { _ in true } && gone.isBoardOnly, describe(gone.root))
    // No more than six.
    var full = HubLayout()
    for number in 1...10 { _ = full.split(full.focused, number % 2 == 0 ? .row : .column, showing: 50 + number) }
    auditHub(full, "split ten times")
    check("a hub holds at most six panes", full.panes.count == HubLayout.maxPanes && !full.canSplit, describe(full.root))
}

group("a hub's ready-made layouts keep what shows, the board and the focus") {
    for layout in PaneLayout.all {
        var hub = HubLayout()
        let board = hub.focused
        _ = hub.split(board, .row, showing: 61)
        _ = hub.split(hub.focused, .row, showing: 62)
        step("hub layout \(layout.id)")
        let applied = hub.apply(layout, recent: [62, 63, 64, 65, 66, 67, 68])
        check("layout \(layout.id) applies only up to \(HubLayout.maxPanes) panes", applied == (layout.count <= HubLayout.maxPanes))
        guard applied else { continue }
        auditHub(hub, "layout \(layout.id)")
        check("layout \(layout.id): as many panes", hub.panes.count == layout.count, describe(hub.root))
        check("layout \(layout.id): the focused conversation stays, focused", hub.focusedConversation == 62, describe(hub.root))
        if layout.count >= 3 { check("layout \(layout.id): the board stays", hub.board != nil && hub.conversations.prefix(2) == [61, 62], describe(hub.root)) }
    }
}

group("a hub's panes keep their least size, and a long run of everything") {
    // How a split shares its room.
    check("even shares in room enough", HubLayout.lengths(fractions: [0.5, 0.5], least: [319, 319], room: 1000) == [500, 500])
    check("a small share gives way to its least", HubLayout.lengths(fractions: [0.9, 0.1], least: [319, 319], room: 1000) == [681, 319])
    check("too little room: each its least", HubLayout.lengths(fractions: [0.5, 0.5], least: [319, 319], room: 500) == [319, 319])
    check("one pane beside the conversation needs the 640 the hub always did", HubLayout.minimumWidth + 1 + 320 == 640)

    var random = Seeded(state: 0x6_5700)
    var hub = HubLayout()
    for turn in 1...4000 {
        let leaves = hub.panes
        let pane = leaves.randomElement(using: &random)!.id
        let conversation = Int.random(in: 1...12, using: &random)
        var what = ""
        switch Int.random(in: 0..<12, using: &random) {
        case 0...2:
            what = "split"
            step("hub turn \(turn): splitting a pane of \(describe(hub.root))")
            hub.split(pane, Bool.random(using: &random) ? .row : .column, showing: Bool.random(using: &random) ? conversation : nil)
        case 3...4:
            what = "close"
            step("hub turn \(turn): closing a pane of \(describe(hub.root))")
            hub.close(pane)
        case 5...6:
            what = "put"
            hub.put(conversation, in: Bool.random(using: &random) ? pane : hub.openTarget)
        case 7:
            what = "board"
            hub.showBoard(in: Bool.random(using: &random) ? pane : nil)
        case 8:
            what = "focus"
            hub.focus(pane)
        case 9:
            what = "forget"
            hub.forget { $0 == conversation }
        case 10:
            what = "layout"
            hub.apply(PaneLayout.all.filter { $0.count <= HubLayout.maxPanes }.randomElement(using: &random)!, recent: [1, 2, 3])
        default:
            what = "resize"
            if let split = splits(hub.root).randomElement(using: &random) {
                let weights = split.children.map { _ in Double.random(in: 0.02...1, using: &random) }
                let total = weights.reduce(0, +)
                var fractions = weights.map { $0 / total }
                fractions[fractions.count - 1] = 1 - fractions.dropLast().reduce(0, +)
                hub.resize(split.id, fractions)
            }
        }
        auditHub(hub, "turn \(turn), after \(what)")
        // Laid out in its least room, or more, every pane has its least size and the panes fill the room.
        let least = HubLayout.minimum(hub.root)
        for extra in [0.0, Double.random(in: 1...900, using: &random)] {
            var sizes: [UUID: HubLayout.Size] = [:]
            let width = least.width + extra, height = least.height + extra / 2
            layOut(hub.root, width: width, height: height, into: &sizes)
            check("turn \(turn): every pane laid out", sizes.count == hub.panes.count, describe(hub.root))
            check("turn \(turn): no pane below its least, \(Int(extra)) points over",
                  sizes.values.allSatisfy { $0.width >= HubLayout.minimumWidth - 1e-6 && $0.height >= HubLayout.minimumHeight - 1e-6 },
                  "\(describe(hub.root)) in \(width)×\(height): \(sizes.values.map { "\(Int($0.width))×\(Int($0.height))" })")
            check("turn \(turn): the fit agrees", hub.fits(width: width, height: height))
        }
        check("turn \(turn): a room smaller than the least does not fit", !hub.fits(width: least.width - 2, height: least.height))
        check("turn \(turn): across counts the widest row", Double(HubLayout.across(hub.root)) * HubLayout.minimumWidth <= least.width + 1e-6, describe(hub.root))
    }
}

group("a hub's saved panes, damaged, give the board or are put right") {
    let a = "00000000-0000-0000-0000-00000000000A", b = "00000000-0000-0000-0000-00000000000B"
    let r = "00000000-0000-0000-0000-000000000001"
    func pane(_ id: String, _ conversation: Int? = nil) -> String {
        #"{"id":"\#(id)","axis":"row","children":[],"fractions":[]\#(conversation.map { #","conversation":\#($0)"# } ?? "")}"#
    }
    func row(_ children: String...) -> String {
        #"{"id":"\#(r)","axis":"row","children":[\#(children.joined(separator: ","))],"fractions":[\#(Array(repeating: String(1 / Double(children.count)), count: children.count).joined(separator: ","))]}"#
    }
    func hub(_ root: String, focused: String = a, board: String? = nil, last: String? = nil) -> HubLayout? {
        let extra = (board.map { ",\"board\":\"\($0)\"" } ?? "") + (last.map { ",\"lastConversation\":\"\($0)\"" } ?? "")
        let json = #"{"root":\#(root),"focused":"\#(focused)"\#(extra)}"#
        return HubLayout.restore(Data(json.utf8))
    }
    check("nothing saved gives the board alone", HubLayout.restore(nil) == nil)
    check("not JSON gives the board alone", HubLayout.restore(Data("panes".utf8)) == nil)
    check("seven panes give the board alone", hub(row(pane(a), pane(b), pane(UUID().uuidString), pane(UUID().uuidString), pane(UUID().uuidString), pane(UUID().uuidString), pane(UUID().uuidString))) == nil)
    let good = hub(row(pane(a), pane(b, 5)), focused: b, board: a, last: b)
    check("a good one reads back", good.map { $0.board?.uuidString == a && $0.focusedConversation == 5 && $0.lastConversation?.uuidString == b } == true)
    check("a board on the split moves off", hub(row(pane(a, 4), pane(b, 5)), board: r).map { $0.board == nil && $0.conversations == [4, 5] } == true)
    check("a board naming a conversation names none", hub(row(pane(a, 4), pane(b, 5)), board: a).map { $0.conversations == [5] } == true)
    check("a conversation in two panes shows once", hub(row(pane(a, 4), pane(b, 4))).map { $0.conversations == [4] && $0.content(of: $0.panes[1].id) == .picker } == true)
    check("pickers alone show the board", hub(row(pane(a), pane(b))).map { $0.board?.uuidString == a } == true)
    check("a focus on no pane moves to the first", hub(row(pane(a, 4), pane(b, 5)), focused: r)?.focused.uuidString == a)
    check("a last conversation on the picker is forgotten", hub(row(pane(a, 4), pane(b)), last: b).map { $0.lastConversation == nil } == true)
}

print(failures == 0 ? "all held: \(audited) trees checked" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
