// Checks how the computer tool reaches SwiftUI controls by accessibility alone, as it must in a window in the
// background (#367, #453), against what SwiftUI really reports.
//
// The computer tool works another app through the accessibility API, which needs Accessibility, and a check must never
// ask for that. So this makes the views in windows of its own that never come on screen and reads them in-process,
// asking each element what the accessibility server would ask it for another app: its role and label, its children,
// and the actions it answers to. For SwiftUI's elements that is each `accessibilityPerform…` method they allow
// (`isAccessibilitySelectorAllowed:`), which is how AppKit lists their actions to other apps; a press is
// `accessibilityPerformPress`, what the server calls for `AXPress`. Setting `AXEnhancedUserInterface` on the app, as an
// assistive app does, makes SwiftUI build its accessibility elements. It checks:
//
// - that a disclosure group in a grouped Form, made as pi²'s are with `pressableDisclosure`, answers `AXPress` on its
//   arrow, named after its label, and that a press opens it and another closes it, once each; the same in a plain
//   stack; and that its label's parts do not each become something to press;
// - and says, without failing, whether SwiftUI's own arrow in a grouped Form still answers to nothing, which is why
//   `pressableDisclosure` exists;
// - that the element whose context menu the tool opens (`Reaching.menuTarget`) is a text with `.contextMenu` itself,
//   the row's text for a list row whose content has one, as the sidebar's rows do, and nothing for a button without one;
// - what to do with a missing or stale AX window, a parked window, and a window a menu bar item opens;
// - that a parked window joins the app's accessibility window list only after an ordering event, which is how a
//   copy exposes its own (#579), that only a window below every ordinary one is ever raised, and that the mark for
//   enhanced accessibility is put back after the raise; that the tool's request reaches the copy's control folder and
//   is taken for its answer; the words given for each reason a copy's window cannot be read; and that a click on a
//   window with no listed controls is never said to have changed nothing;
// - that a parked copy's main window is taken while the window server has it, the same size, somewhere else, as while
//   macOS moves it between Spaces, and that the copy's own answer to `can-click` turns it down exactly where the tool
//   would; and that a click at a point lands on the innermost listed control there, which a hit test cannot find off
//   the screen (#748);
// - that the size alone takes a window only as the app's main window and only when no other window of the process is
//   that size; that a click at a point acts on what the hit test found in every app but a parked copy, and there falls
//   back to the listed controls only where the hit test found nothing in the window; and that the action acts on what
//   its approval card named, or is refused once that no longer holds (#770); that a listed control a card named
//   holds only while it is among the window's controls read again, since a SwiftUI button on a tab switched away
//   still answers its old frame and its press, and is then worked through accessibility alone (#955); and that a
//   control named by number, or at a point with no card, is worked only while one walk of the window, which stops
//   once it has found what it seeks, finds it again (#969);
// - the size and direction of the wheel event (as AppKit decodes it, without posting it), and how actual movement
//   is reported;
// - that a window is pictured alone, without the windows attached to it, at its own frame's size, so that a sheet's
//   controls are where the picture has them, and that a picture at another window's proportions is refused (#798).
//   Whether ScreenCaptureKit then draws a sheet by itself takes a live capture, in a test copy.
//
//   cd app && swift build --product pi2-computer-check && .build/debug/pi2-computer-check
//
// What it cannot do is open a menu, which would put it on the screen, or reach another app the way the computer tool
// does: listing an open menu's items, choosing one and closing it are left to a try with the computer tool, in a test
// copy (docs/computer-use.md). Exits 1 if anything failed.

import AppKit
import ComputerKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

setlinebuf(stdout)

nonisolated(unsafe) var failures = 0
func check(_ name: String, _ holds: Bool, _ detail: @autoclosure () -> String = "") {
    if holds { return }
    failures += 1
    let more = detail()
    print("FAIL  \(name)" + (more.isEmpty ? "" : "\n      " + more))
}

@MainActor
func group(_ name: String, _ body: () async -> Void) async {
    let before = failures
    await body()
    print(failures == before ? "ok    \(name)" : "FAIL  \(name): \(failures - before) failed")
}

// MARK: - An element of this program's own windows, as the accessibility server sees it

/// The perform methods an element made with the NSAccessibility protocol may allow, and the actions they are to
/// another app.
private let performed: [(String, String)] = [
    ("accessibilityPerformPress", "AXPress"), ("accessibilityPerformShowMenu", "AXShowMenu"),
    ("accessibilityPerformIncrement", "AXIncrement"), ("accessibilityPerformDecrement", "AXDecrement"),
    ("accessibilityPerformCancel", "AXCancel"), ("accessibilityPerformConfirm", "AXConfirm"),
    ("accessibilityPerformPick", "AXPick"), ("accessibilityPerformDelete", "AXDelete"), ("accessibilityPerformRaise", "AXRaise"),
]

@MainActor
struct Local: @preconcurrency AccessibleElement {
    let object: NSObject

    /// An object-returning accessibility method, if the element has it. The old attribute API stands in for elements
    /// that only have that, such as a table's rows.
    private func read(_ name: String, old: NSAccessibility.Attribute) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        guard !object.responds(to: selector), object.accessibilityAttributeNames().contains(old) else { return nil }
        return object.accessibilityAttributeValue(old)
    }

    private func allows(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name), allowed = NSSelectorFromString("isAccessibilitySelectorAllowed:")
        guard object.responds(to: selector), object.responds(to: allowed) else { return false }
        typealias Allowed = @convention(c) (AnyObject, Selector, Selector) -> Bool
        return unsafeBitCast(object.method(for: allowed), to: Allowed.self)(object, allowed, selector)
    }

    var accessibleRole: String { read("accessibilityRole", old: .role) as? String ?? "" }
    var label: String { (read("accessibilityLabel", old: .description) as? String) ?? (read("accessibilityTitle", old: .title) as? String) ?? "" }
    var value: Any? { read("accessibilityValue", old: .value) }
    var accessibleChildren: [Local] { ((read("accessibilityChildren", old: .children) as? [Any]) ?? []).compactMap { ($0 as? NSObject).map(Local.init) } }
    var accessibleParent: Local? { (read("accessibilityParent", old: .parent) as? NSObject).map(Local.init) }
    var accessibleActions: [String] {
        let listed = object.accessibilityActionNames().map(\.rawValue)
        // A view lists its own; an element made with the protocol, as SwiftUI's are, has them worked out from what it allows.
        if object is NSView || object is NSWindow || !listed.isEmpty { return listed }
        return performed.filter { allows($0.0) }.map(\.1)
    }

    /// Where it is, as the accessibility server answers `AXPosition` and `AXSize` for it.
    var frame: CGRect? {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { return nil }
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Frame.self)(object, selector)
    }

    /// What the accessibility server does for another app's `AXPress`.
    func press() -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }

    /// Every element under this one, this one first.
    var all: [Local] { [self] + accessibleChildren.flatMap(\.all) }
}

// MARK: - Stand-ins for pi²'s views

@MainActor @Observable
final class Disclosure {
    var open = false
    var changes = 0
}

/// A disclosure group made as Settings › Chat makes an agent's notes: in a grouped Form, its label several views.
struct FormGroup: View {
    @Bindable var state: Disclosure
    let pressable: Bool

    var body: some View {
        let open = Binding(get: { state.open }, set: { state.open = $0; state.changes += 1 })
        Form {
            Section {
                DisclosureGroup(isExpanded: open) {
                    Text("Prefers metric units")
                } label: {
                    if pressable { label.pressableDisclosure(open) } else { label }
                }
                Button("Another button") {}
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 300)
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
            Text("Quill")
            Spacer()
            Text("2 notes").foregroundStyle(.secondary)
            Image(systemName: "lock").help("Read-only here")
        }
    }
}

/// A disclosure group outside a Form, as the thinking in the SwiftUI transcript has.
struct StackGroup: View {
    @Bindable var state: Disclosure

    var body: some View {
        let open = Binding(get: { state.open }, set: { state.open = $0; state.changes += 1 })
        VStack {
            DisclosureGroup(isExpanded: open) {
                Text("Weighing the options")
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                    Text("Thought")
                }
                .pressableDisclosure(open)
            }
        }
        .frame(width: 360, height: 200)
    }
}

@MainActor @Observable
final class Board {
    var tab = "Now"
    var hidden = false
    var pressed = 0
}

/// A board whose tabs are switched as the project hub's are, with a `switch`: the Now tab's view is removed.
struct SwitchedBoard: View {
    @Bindable var board: Board

    var body: some View {
        VStack {
            switch board.tab {
            case "Now":
                VStack {
                    Button("Beacon, · Verify the preview") { board.pressed += 1 }.accessibilityHidden(board.hidden)
                    Text("Now tab")
                }
            default: VStack { Text("Work #6"); Spacer() }
            }
        }
        .frame(width: 360, height: 300)
    }
}

/// The walk `ComputerController.stillListed` makes, over the check's own elements: in the listing's order, bounded at
/// `limit` elements as a look's is at 4000, stopping once every control sought is found.
@MainActor
func seek(_ wanted: [NSObject], in stage: Stage, limit: Int = 4000) -> (outcome: Seeking<NSObject>.Outcome, visited: Int) {
    var seeking = Seeking(wanted)
    var visited = 0
    var truncated = false
    func walk(_ element: Local) {
        if seeking.done || truncated { return }
        visited += 1
        if visited > limit { truncated = true; return }
        seeking.saw(element.object)
        for kid in element.accessibleChildren { walk(kid) }
    }
    walk(Local(object: stage.window))
    return (seeking.outcome(truncated: truncated), visited)
}

/// A window of many controls, for the cost of reading it again.
struct ManyButtons: View {
    let count: Int

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in Button("Row \(index)") {}.frame(height: 1) }
        }
        .frame(width: 360, height: 300)
    }
}

/// A text with a context menu, rows with one as the sidebar's have, and a button with none.
struct Menus: View {
    var body: some View {
        VStack {
            Text("Notes.txt").contextMenu { Button("Show in Finder") {}; Button("Copy Path") {} }
            Button("No menu here") {}
            List {
                ForEach(1..<3) { number in
                    HStack {
                        Text("Conversation \(number)")
                        Spacer()
                        Text("2h")
                    }
                    .contextMenu { Button("Rename") {}; Button("Archive") {} }
                }
            }
            .frame(height: 120)
        }
        .frame(width: 360, height: 260)
    }
}

// MARK: - Running them

@MainActor
final class Stage {
    let window: NSWindow

    init<Content: View>(_ content: Content) {
        // Far off every screen and never ordered in: SwiftUI reads it all the same.
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 360, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
    }

    var elements: [Local] { Local(object: window).all }

    /// Waits, at most ten seconds, for SwiftUI to have built the elements and for `holds` to be true of them.
    func until(_ holds: ([Local]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if holds(elements) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return holds(elements)
    }

    func first(_ role: String, _ label: String? = nil) -> Local? {
        elements.first { element in
            element.accessibleRole == role && (label.map { wanted in element.label.contains(wanted) || "\(element.value ?? "")".contains(wanted) } ?? true)
        }
    }
}

@MainActor
func pressingOpensAndCloses(_ stage: Stage, _ state: Disclosure, label: String) async {
    guard await stage.until({ list in list.contains { $0.accessibleRole == "AXDisclosureTriangle" } }), let arrow = stage.first("AXDisclosureTriangle") else {
        check("the disclosure arrow is there", false, "no AXDisclosureTriangle among \(stage.elements.map(\.accessibleRole))")
        return
    }
    check("the arrow is named after the label", arrow.label.contains(label), "its label is “\(arrow.label)”")
    check("the arrow answers AXPress", Reaching.pressable(arrow), "it answers \(arrow.accessibleActions)")
    check("the arrow says it is closed", (arrow.value as? NSNumber)?.intValue == 0, "its value is \(String(describing: arrow.value))")
    check("a press is taken", arrow.press())
    let opened = await stage.until { _ in state.open }
    check("a press opens it", opened)
    check("once", state.changes == 1, "it changed \(state.changes) times")
    let shown = await stage.until { list in list.contains { ($0.value as? NSNumber)?.intValue == 1 && $0.accessibleRole == "AXDisclosureTriangle" } }
    check("the arrow then says it is open", shown)
    guard let again = stage.first("AXDisclosureTriangle") else { return check("the arrow is still there", false) }
    check("a second press is taken", again.press())
    let closed = await stage.until { _ in !state.open }
    check("a second press closes it", closed)
    check("once more", state.changes == 2, "it changed \(state.changes) times")
}

@MainActor
final class StandInStatusItem: NSAccessibilityElement {
    let panel = Stage(Button("Review request") {})
    private(set) var pressed = false

    override func accessibilityPerformPress() -> Bool {
        pressed = true
        return true
    }
}

@MainActor
final class TallDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
func scrollView(documentHeight: CGFloat) -> NSScrollView {
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 200))
    scroll.drawsBackground = false
    scroll.documentView = TallDocument(frame: CGRect(x: 0, y: 0, width: 360, height: documentHeight))
    return scroll
}

/// A folder standing in for a test copy's control folder, under `base`.
@MainActor
func standInFolder(_ base: URL) -> URL {
    let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A stand-in copy answering expose requests in `folder`: watches for one naming its pid and the command,
/// and replies with `answer`. Returns the request it answered, for checking what was asked.
func standInCopy(_ folder: URL, _ answer: [String: String]) -> Task<[String: Any]?, Never> {
    Task.detached(priority: .high) { () -> [String: Any]? in
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix("request-expose-") {
                let dir = folder.appendingPathComponent(name, isDirectory: true)
                if let data = try? Data(contentsOf: dir.appendingPathComponent("request.json")),
                   let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let answer = try? JSONSerialization.data(withJSONObject: answer) {
                    try? answer.write(to: dir.appendingPathComponent("response.json"), options: .atomic)
                    return read
                }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }
}

let app = NSApplication.shared
// No Dock icon, no menu bar, and never made active: the person's focus stays where it is.
app.setActivationPolicy(.prohibited)
// What an assistive app asks of an app it connects to; SwiftUI builds its accessibility elements once it is set.
app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))

Task { @MainActor in
    await group("a control of a tab switched away still answers, but is no longer among the window's controls (#955)") {
        // The board switches its tabs with a `switch`, so the Now tab's view is removed, not hidden. In the live trial
        // of #955, a click at a point on its Beacon button, after the board had switched to Work, was not refused: the
        // kept element still gave a frame holding the point. Here it is read in-process, as the check reads its own views.
        let board = Board()
        let stage = Stage(SwitchedBoard(board: board))
        defer { stage.window.close() }
        _ = await stage.until { list in list.contains { $0.accessibleRole == "AXButton" } }
        guard let beacon = stage.first("AXButton", "Beacon"), let frame = beacon.frame else {
            return check("the Beacon button is there, with a frame", false, "roles: \(stage.elements.map(\.accessibleRole))")
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        // What the tool asks: is the kept control among the window's controls read now (`listedNow`, by identity here,
        // as `CFEqual` compares two AXUIElements), and does its frame hold the point.
        let listedNow: (NSObject) -> Bool = { kept in stage.elements.contains { $0.object === kept } }
        let frameNow: (NSObject) -> CGRect? = { Local(object: $0).frame }
        var kept = AtPoint.Kept<NSObject>()
        kept.keep(beacon.object, for: "click@1")
        check("still there, and at the point, it is acted on through accessibility alone",
              kept.settle(beacon.object, hit: nil, for: "click@1", at: point, frameNow: frameNow, present: listedNow) == .only(beacon.object))
        check("and its press is taken, once", beacon.press() && board.pressed == 1, "pressed \(board.pressed) times")

        kept.keep(beacon.object, for: "click@1")
        board.tab = "Work"
        let switched = await stage.until { list in !list.contains { $0.object === beacon.object } && list.contains { "\($0.value ?? "")\($0.label)".contains("Work #6") } }
        check("the board switched to Work, and the Beacon button is no longer among the window's elements", switched,
              "roles now: \(stage.elements.map(\.accessibleRole))")
        check("its parent no longer has it", beacon.accessibleParent.map { parent in parent.accessibleChildren.contains { $0.object === beacon.object } } != true)
        // What made the trial's click go through: the removed element still answers, at its old frame. A note either
        // way, since it is SwiftUI's behaviour, not the tool's; the refusal below does not depend on it.
        let still = beacon.frame
        print("note  after the switch the removed Beacon element answers role \u{201C}\(beacon.accessibleRole)\u{201D}, frame \(still.map { "\($0)" } ?? "none")\(still == frame ? ", its old one" : ""), actions \(beacon.accessibleActions)")
        check("it is refused with look again, though it still answers its old frame",
              kept.settle(beacon.object, hit: nil, for: "click@1", at: point, frameNow: { _ in frame }, present: listedNow) == .changed)
        let before = board.pressed
        let pressed = beacon.press()
        print("note  a press on the removed Beacon element \(pressed ? "is taken" : "is refused"), and the removed button's action ran \(board.pressed - before) time\(board.pressed - before == 1 ? "" : "s"): only its absence from the window's controls stops it")

        // Hidden rather than removed: what a hidden control gives the window's controls.
        board.tab = "Now"
        _ = await stage.until { list in list.contains { $0.accessibleRole == "AXButton" } }
        guard let shown = stage.first("AXButton", "Beacon") else { return check("the Beacon button is back", false) }
        kept.keep(shown.object, for: "click@1")
        board.hidden = true
        let hidden = await stage.until { list in !list.contains { $0.object === shown.object } }
        check("a control hidden from accessibility is no longer among the window's elements either", hidden)
        check("and is refused with look again",
              kept.settle(shown.object, hit: nil, for: "click@1", at: point, frameNow: { _ in frame }, present: listedNow) == .changed)
        check("with no card, the hidden one is refused too (#969)",
              kept.settle(shown.object, hit: nil, for: "click@1", at: point, frameNow: { _ in frame }, present: listedNow) == .stale)
    }

    await group("a control named by number, or with no card, is worked only while it is among the window's controls (#969)") {
        // `control(_:in:)` and a click at a point with no card ask `stillListed`: one walk of the window, as a look's,
        // stopping once each control sought is found (`Seeking`). Here the walk goes over the check's own SwiftUI board.
        let board = Board()
        let stage = Stage(SwitchedBoard(board: board))
        defer { stage.window.close() }
        _ = await stage.until { list in list.contains { $0.accessibleRole == "AXButton" } }
        guard let beacon = stage.first("AXButton", "Beacon"), let text = stage.first("AXStaticText", "Now tab"), let frame = beacon.frame else {
            return check("the Beacon button and the Now tab's text are there", false, "roles: \(stage.elements.map(\.accessibleRole))")
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        check("a control still there is found", seek([beacon.object], in: stage).outcome == .found)
        let both = seek([beacon.object, text.object], in: stage)
        check("one walk finds two controls an action names", both.outcome == .found && both.visited <= stage.elements.count,
              "visited \(both.visited) of \(stage.elements.count)")
        check("a walk that runs out before finding it cannot say, and is not taken for found",
              seek([text.object], in: stage, limit: 1).outcome == .unsure)
        board.tab = "Work"
        _ = await stage.until { list in !list.contains { $0.object === beacon.object } }
        check("a removed control is not found, though it still answers its role and old frame",
              seek([beacon.object], in: stage).outcome == .gone && beacon.accessibleRole == "AXButton" && beacon.frame == frame)
        check("nor is a pair one of which was removed", seek([beacon.object, text.object], in: stage).outcome == .gone)
        var kept = AtPoint.Kept<NSObject>()
        check("with no card, a click at the point of the removed control is refused with look again",
              kept.settle(beacon.object, hit: nil, for: "click@1", at: point, frameNow: { _ in frame },
                          present: { seek([$0], in: stage).outcome == .found }) == .stale)

        // The cost: one walk per action that names a listed control, stopping where it is found. Timed in-process,
        // as a floor: another app answers each element in a message of its own.
        let many = Stage(ManyButtons(count: 1500))
        defer { many.window.close() }
        _ = await many.until { list in list.filter { $0.accessibleRole == "AXButton" }.count >= 1500 }
        let buttons = many.elements.filter { $0.accessibleRole == "AXButton" }
        guard let first = buttons.first, let last = buttons.last else { return check("the many buttons are there", false) }
        _ = seek([first.object], in: many) // warms the in-process reads, which the first call pays for
        var start = Date()
        let early = seek([first.object], in: many)
        let earlyTook = Date().timeIntervalSince(start)
        start = Date()
        let late = seek([last.object], in: many)
        let lateTook = Date().timeIntervalSince(start)
        check("a control early in a window of many is found without reading the rest", early.outcome == .found && early.visited < 10,
              "visited \(early.visited)")
        check("and the last is found by reading the window up to it", late.outcome == .found && late.visited >= buttons.count,
              "visited \(late.visited) of \(many.elements.count)")
        print("note  finding a control again in a window of \(many.elements.count) elements: \(early.visited) read, \(Int(earlyTook * 1_000_000)) µs, for the first; \(late.visited) read, \(Int(lateTook * 1000)) ms, for the last, in-process")
    }

    await group("reading the window's controls again, for a card's listed control, costs one walk of the window (#955)") {
        // Asked only for a click or context menu at a point with a card, on a listed control, which only a parked test
        // copy falls back to; never in any other app, Electron or web views among them, where the hit test's own find
        // is acted on. The walk is bounded as a look's listing is (4000 elements, 40 deep, 2.5 seconds). Timed here
        // in-process, as a floor: another app answers each element in a message of its own.
        let stage = Stage(ManyButtons(count: 1500))
        defer { stage.window.close() }
        _ = await stage.until { list in list.filter { $0.accessibleRole == "AXButton" }.count >= 1500 }
        let start = Date()
        let elements = stage.elements
        let took = Date().timeIntervalSince(start)
        check("a window of many controls is read", elements.filter { $0.accessibleRole == "AXButton" }.count >= 1500, "\(elements.count) elements")
        print("note  one read of a window of \(elements.count) elements took \(Int(took * 1000)) ms in-process")
    }

    await group("a disclosure group in a grouped Form, made as pi²'s are, opens and closes with a press") {
        let state = Disclosure()
        let stage = Stage(FormGroup(state: state, pressable: true))
        await pressingOpensAndCloses(stage, state, label: "Quill")
        let buttons = stage.elements.filter { $0.accessibleRole == "AXButton" }.map(\.label)
        check("its label's parts do not each become a button", buttons == ["Another button"], "buttons: \(buttons)")
        stage.window.close()
    }

    await group("a disclosure group outside a Form opens and closes with a press, once each") {
        let state = Disclosure()
        let stage = Stage(StackGroup(state: state))
        await pressingOpensAndCloses(stage, state, label: "Thought")
        stage.window.close()
    }

    await group("SwiftUI's own disclosure arrow in a grouped Form") {
        let state = Disclosure()
        let stage = Stage(FormGroup(state: state, pressable: false))
        guard await stage.until({ list in list.contains { $0.accessibleRole == "AXDisclosureTriangle" } }), let arrow = stage.first("AXDisclosureTriangle") else {
            return check("the disclosure arrow is there", false)
        }
        // Not a failure either way: it says whether pressableDisclosure is still what makes such a group work.
        if Reaching.pressable(arrow) {
            print("note  SwiftUI's own arrow in a grouped Form now answers AXPress; pressableDisclosure may no longer be needed (#367)")
        } else {
            print("note  SwiftUI's own arrow in a grouped Form answers \(arrow.accessibleActions): without pressableDisclosure only a click opens it")
        }
        stage.window.close()
    }

    await group("the context menu the computer tool opens is the one on the control, or inside it") {
        let stage = Stage(Menus())
        let built = await stage.until { list in list.filter { $0.accessibleRole == "AXRow" }.count == 2 && list.contains { $0.accessibleActions.contains(Reaching.showMenu) } }
        check("the views are built", built, "roles: \(stage.elements.map(\.accessibleRole))")
        if let text = stage.first("AXStaticText", "Notes.txt") {
            let target = Reaching.menuTarget(of: text)
            check("a text with a context menu is its own target", target?.object === text.object, "target: \(target.map { "\($0.accessibleRole) “\($0.label)”" } ?? "none")")
        } else {
            check("the text with a menu is there", false)
        }
        let rows = stage.elements.filter { $0.accessibleRole == "AXRow" }
        for (index, row) in rows.enumerated() {
            let target = Reaching.menuTarget(of: row)
            let named = target.map { "\($0.label) \($0.value ?? "")" } ?? ""
            check("row \(index + 1)'s menu is found inside it", target != nil && named.contains("Conversation \(index + 1)"),
                  "target: \(target.map { "\($0.accessibleRole) “\(named)”" } ?? "none"); the row answers \(row.accessibleActions)")
        }
        if let button = stage.first("AXButton", "No menu here") {
            check("a button without a menu has no target", Reaching.menuTarget(of: button) == nil)
            check("and a press is how it is clicked", Reaching.pressable(button), "it answers \(button.accessibleActions)")
        } else {
            check("the button is there", false)
        }
        stage.window.close()
    }

    await group("missing or stale AX windows do not hide the parked main window") {
        let main = Stage(Text("Main")), settings = Stage(Text("Settings")), stale = Stage(Text("Closed"))
        defer { main.window.close(); settings.window.close(); stale.window.close() }
        let frame: (NSWindow) -> CGRect? = { $0 === stale.window ? nil : $0.frame }
        let minimized: (NSWindow) -> Bool = { _ in false }
        check("a focused Settings window takes precedence over main", WindowChoice.first(in: [settings.window, main.window], minimized: minimized, frame: frame)?.0 === settings.window)
        check("skip a stale focused window and use the next usable one", WindowChoice.first(in: [stale.window, main.window], minimized: minimized, frame: frame)?.0 === main.window)
        check("skip a minimized window", WindowChoice.first(in: [settings.window, main.window], minimized: { $0 === settings.window }, frame: frame)?.0 === main.window)
        check("no usable AX window", WindowChoice.first(in: [stale.window], minimized: minimized, frame: frame) == nil)
        let pid: pid_t = 42
        let mainBounds = CGRect(x: 1400, y: 1000, width: 900, height: 550)
        let windows = [
            ServerWindow(id: 1, pid: pid, layer: -1, frame: mainBounds),
            ServerWindow(id: 2, pid: pid, layer: -1, frame: CGRect(x: 0, y: 0, width: 660, height: 320)),
            ServerWindow(id: 3, pid: pid, layer: 25, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
            ServerWindow(id: 4, pid: pid + 1, layer: -1, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
            ServerWindow(id: 5, pid: pid, layer: 0, frame: CGRect(x: 0, y: 0, width: 99, height: 1000)),
        ]
        check("use the largest eligible window for this PID, even offscreen and at layer -1", ServerWindow.parkedCopy(in: windows, pid: pid)?.id == 1)
        check("use the parked window ID for input without needing an image", ServerWindow.matching(mainBounds, in: windows, pid: pid)?.id == 1)
        check("never pair controls with another window's image or ID", ServerWindow.matching(mainBounds.offsetBy(dx: 200, dy: 0), in: windows, pid: pid) == nil)
    }

    await group("a parked copy's main window is taken while the window server has it elsewhere (#748)") {
        // What a live copy gave while macOS moved its parked window between Spaces: accessibility answered the main
        // window with its frame, and the window server had the same window, the same size, somewhere else. The exact
        // match turned it down, so the tool listed no controls and said the copy "still cannot read its controls".
        let pid: pid_t = 42
        let ax = CGRect(x: 1760, y: 1130, width: 1120, height: 740)
        let moving = ServerWindow(id: 1, pid: pid, layer: -1, frame: ax.offsetBy(dx: 1800, dy: 0))
        let helper = ServerWindow(id: 2, pid: pid, layer: 0, frame: CGRect(x: 0, y: 682, width: 500, height: 500))
        let server = [moving, helper]
        let parked = ServerWindow.parkedCopy(in: server, pid: pid)
        check("an exact match alone turns it down, as the tool did", ServerWindow.matching(ax, in: server, pid: pid) == nil)
        check("the parked window of the same size backs it", ServerWindow.backing(ax, in: server, pid: pid, parked: parked)?.id == 1)
        check("an exact match is still preferred",
              ServerWindow.backing(helper.frame, in: server, pid: pid, parked: parked)?.id == 2)
        let settings = CGRect(x: 600, y: 300, width: 660, height: 420)
        check("a closed window's stale frame, another size, is still turned down",
              ServerWindow.backing(settings, in: server, pid: pid, parked: parked) == nil)
        check("another process's window never backs it",
              ServerWindow.backing(ax, in: [ServerWindow(id: 3, pid: pid + 1, layer: -1, frame: moving.frame)], pid: pid,
                                   parked: ServerWindow(id: 3, pid: pid + 1, layer: -1, frame: moving.frame)) == nil)
        // can-click asks the copy the same question, from its side, so that it says no where the tool would.
        check("the copy says yes for its window where the tool would take it",
              ParkedWindow.refusal(id: 1, frame: ax, server: server, pid: pid, main: true) == nil)
        let resized = ParkedWindow.refusal(id: 1, frame: CGRect(x: 1760, y: 1130, width: 1120, height: 700), server: server, pid: pid, main: true)
        check("and no, with both places, where the window server has it at another size",
              resized?.contains("window server has the main window at 1120×740 at (3560, 1130)") == true
                  && resized?.contains("accessibility gives it at 1120×700 at (1760, 1130)") == true, resized ?? "nil")
        let missing = ParkedWindow.refusal(id: 9, frame: ax, server: server, pid: pid, main: true)
        check("and no where the window server has no record of it", missing?.contains("no record of the main window") == true, missing ?? "nil")
        check("and no where the window server's parked window is another one",
              ParkedWindow.refusal(id: 2, frame: CGRect(x: 0, y: 0, width: 500, height: 500), server: server, pid: pid, main: true) != nil)
    }

    await group("a window is taken by its size alone only as the main window, and only when no other is that size (#770)") {
        // The size alone said which window it was: a stale focused window, or a second window of the copy at the
        // parked window's size, was taken for the parked one, and its controls paired with the other's picture and
        // clicks. Each is a window of the same throwaway copy, never another app's.
        let pid: pid_t = 42
        let ax = CGRect(x: 1760, y: 1130, width: 1120, height: 740)
        let moving = ServerWindow(id: 1, pid: pid, layer: -1, frame: ax.offsetBy(dx: 1800, dy: 0))
        let twin = ServerWindow(id: 4, pid: pid, layer: 0, frame: ax.offsetBy(dx: -900, dy: -600))
        let helper = ServerWindow(id: 2, pid: pid, layer: 0, frame: CGRect(x: 0, y: 682, width: 500, height: 500))
        let alone = [moving, helper]
        let twinned = [moving, twin, helper]
        let parked = ServerWindow.parkedCopy(in: twinned, pid: pid)
        check("a window accessibility does not give as the main one is not taken by its size",
              ServerWindow.backing(ax, in: alone, pid: pid, parked: nil) == nil)
        check("a second window of the process at that size elsewhere is refused, for either of the two",
              ServerWindow.backing(ax, in: twinned, pid: pid, parked: parked) == nil
                  && ServerWindow.backing(ax, in: twinned, pid: pid, parked: twin) == nil)
        check("a window of another process at that size does not stop it",
              ServerWindow.backing(ax, in: alone + [ServerWindow(id: 9, pid: pid + 1, layer: 0, frame: twin.frame)], pid: pid,
                                   parked: ServerWindow.parkedCopy(in: alone, pid: pid))?.id == 1)
        check("an exact match is still taken beside a window of the same size",
              ServerWindow.backing(twin.frame, in: twinned, pid: pid, parked: parked)?.id == 4)
        // can-click turns them down where the tool would, saying why.
        let notMain = ParkedWindow.refusal(id: 1, frame: ax, server: alone, pid: pid, main: false)
        check("the copy says no for a window that is not the app's main window, and why",
              notMain?.contains("does not give it as the app's main window") == true && notMain?.contains(ParkedWindow.notTaken) == true,
              notMain ?? "nil")
        let twice = ParkedWindow.refusal(id: 1, frame: ax, server: twinned, pid: pid, main: true)
        check("and for a window another of the copy's windows is the size of, and why",
              twice?.contains("another window of the copy is that size") == true && twice?.contains(ParkedWindow.notTaken) == true,
              twice ?? "nil")
        check("and yes for a window at its own frame, main or not",
              ParkedWindow.refusal(id: 1, frame: moving.frame, server: twinned, pid: pid, main: false) == nil)
    }

    await group("a click at a point acts on what the hit test found, but in a parked copy where it found nothing (#770)") {
        // What a click or a context menu at a point acts on, and what its approval card names: the hit test's find
        // in every app, as before #748; in a parked copy, the innermost listed control where the hit test, which reads
        // the screen, found nothing in the window. Stand-ins: a button listed over a row, and what a hit test gave.
        let row = CGRect(x: 1770, y: 1440, width: 270, height: 30)
        let button = CGRect(x: 1800, y: 1445, width: 80, height: 20)
        let listed = [(element: "row", frame: row), (element: "button", frame: button), (element: "menu bar item", frame: CGRect.null)]
        let point = CGPoint(x: 1810, y: 1450)
        var asked = 0
        func target(hit: String?, parked: Bool, inWindow: Bool = true) -> String? {
            AtPoint.target(at: point, hit: hit, listed: listed, parked: parked) { _ in asked += 1; return inWindow }
        }
        check("a hit that can be pressed wins, in any app and in a parked copy",
              target(hit: "Send", parked: false) == "Send" && target(hit: "Send", parked: true) == "Send")
        check("a hit that cannot be pressed, such as an overlay, is not replaced by a listed control outside a parked copy",
              target(hit: "overlay", parked: false) == "overlay")
        check("nor in a parked copy, where it is in the window", target(hit: "overlay", parked: true) == "overlay")
        check("outside a parked copy, no hit is a real click, whatever is listed there", target(hit: nil, parked: false) == nil)
        asked = 0
        _ = target(hit: "Send", parked: false)
        _ = target(hit: nil, parked: false)
        check("outside a parked copy nothing more is asked of the hit than before", asked == 0)
        check("in a parked copy with no hit, the innermost listed control holding the point", target(hit: nil, parked: true) == "button")
        check("and the same where the hit is outside the window read",
              target(hit: "another window's button", parked: true, inWindow: false) == "button")
        check("and a real click where no listed control holds the point, never the outside hit",
              AtPoint.target(at: CGPoint(x: 0, y: 0), hit: "another app's button", listed: listed, parked: true) { _ in false } == nil)

        // What counts as in the window read (#879). Off the screen a hit test finds none of the copy's windows and can
        // answer with the application element, which has no window; that once counted as in, so a parked copy's click
        // at a point went as a real click, which it ignored. Stand-ins: each element's enclosing window, as read.
        let enclosing: [String: String] = ["Send": "main", "button": "main", "row": "main", "overlay": "main", "main": "main",
                                           "Settings' tab": "Settings", "Cancel": "sheet", "sheet": "sheet"]
        func parkedTarget(hit: String?, window: String?, ofCopy: Bool = true, at spot: CGPoint = point,
                          listed controls: [(element: String, frame: CGRect)]? = nil) -> String? {
            AtPoint.target(at: spot, hit: hit, listed: controls ?? listed, parked: true) { hit in
                AtPoint.inWindow(hit, ofCopy: ofCopy, enclosing: enclosing[hit], window: window)
            }
        }
        check("the application element as the hit is not in the window: the listed control at the point is taken",
              parkedTarget(hit: "application", window: "main") == "button")
        check("nor is an element with no enclosing window", parkedTarget(hit: "detached text", window: "main") == "button")
        check("nor the window itself, which names nothing in it", parkedTarget(hit: "main", window: "main") == "button")
        check("nor an element of another of the copy's windows", parkedTarget(hit: "Settings' tab", window: "main") == "button")
        check("nor one of another process, even in a window of that name",
              parkedTarget(hit: "overlay", window: "main", ofCopy: false) == "button")
        check("a hit in the window read is acted on as it is, an overlay too",
              parkedTarget(hit: "Send", window: "main") == "Send" && parkedTarget(hit: "overlay", window: "main") == "overlay"
                  && parkedTarget(hit: "row", window: "main") == "row")
        check("with no window read nothing is in it, and the listed control is taken",
              parkedTarget(hit: "overlay", window: nil) == "button")
        check("the application element where no listed control holds the point is a real click, naming nothing",
              parkedTarget(hit: "application", window: "main", at: CGPoint(x: 0, y: 0)) == nil)
        // A sheet parked off the screen is read as the window, with only its own controls listed (#798).
        let cancel = CGRect(x: 1740, y: 1130, width: 70, height: 24)
        let sheetListed = [(element: "Cancel", frame: cancel), (element: "Get", frame: cancel.offsetBy(dx: 90, dy: 0))]
        check("in a sheet parked off the screen, the application element as the hit gives the sheet's listed Cancel",
              parkedTarget(hit: "application", window: "sheet", at: CGPoint(x: 1770, y: 1140), listed: sheetListed) == "Cancel")
        check("and the sheet's own Cancel, where a hit test finds it, is acted on as it is",
              parkedTarget(hit: "Cancel", window: "sheet", at: CGPoint(x: 1770, y: 1140), listed: sheetListed) == "Cancel"
                  && AtPoint.inWindow("Cancel", ofCopy: true, enclosing: "sheet", window: "sheet"))
        check("the sheet itself, or the window under it, is not in the sheet",
              !AtPoint.inWindow("sheet", ofCopy: true, enclosing: "sheet", window: "sheet")
                  && !AtPoint.inWindow("button", ofCopy: true, enclosing: "main", window: "sheet"))
        asked = 0
        _ = AtPoint.target(at: point, hit: "application", listed: listed, parked: false) { _ in asked += 1; return false }
        check("outside a parked copy the application element is still the hit, and nothing more is asked of it",
              AtPoint.target(at: point, hit: "application", listed: listed, parked: false) { _ in false } == "application" && asked == 0)

        // The card and the action choose once: the card's choice is acted on, or refused once it no longer holds.
        var kept = AtPoint.Kept<String>()
        let here: (String) -> CGRect? = { $0 == "button" ? button : $0 == "row" ? row : nil }
        // Whether a kept control is among the window's controls read now (#955); counted, since it is a read of the window.
        var reads = 0
        let listedNow: (String) -> Bool = { reads += 1; return ["button", "row"].contains($0) }
        kept.keep("Send", for: "click@1")
        check("the card and the press act on the same element",
              kept.settle("Send", hit: "Send", for: "click@1", at: point, frameNow: here, present: listedNow) == .act("Send"))
        check("a choice is used once; an action with no card acts on what is there",
              kept.settle("Cancel", hit: "Cancel", for: "click@1", at: point, frameNow: here, present: listedNow) == .act("Cancel"))
        kept.keep("Send", for: "click@1")
        check("a window that changed during the wait refuses, and is not redirected",
              kept.settle("Cancel", hit: "Cancel", for: "click@1", at: point, frameNow: here, present: listedNow) == .changed)
        kept.keep(nil, for: "click@1")
        check("a card that named a real click refuses where something can be named there now",
              kept.settle("Send", hit: "Send", for: "click@1", at: point, frameNow: here, present: listedNow) == .changed)
        kept.keep(nil, for: "click@1")
        check("and is a real click where nothing still is",
              kept.settle(nil, hit: nil, for: "click@1", at: point, frameNow: here, present: listedNow) == .act(nil))
        check("the window is read again for none of these: no listed control was kept", reads == 0, "read \(reads) times")
        kept.keep("button", for: "click@1")
        check("a listed control the card named, still there and at the point, is acted on through accessibility alone",
              kept.settle("button", hit: nil, for: "click@1", at: point, frameNow: here, present: listedNow) == .only("button"))
        check("after one read of the window", reads == 1, "read \(reads) times")
        kept.keep("button", for: "click@1")
        check("one that is gone refuses", kept.settle("button", hit: nil, for: "click@1", at: point, frameNow: { _ in nil }, present: listedNow) == .changed)
        kept.keep("button", for: "click@1")
        check("one that moved off the point refuses",
              kept.settle("button", hit: nil, for: "click@1", at: point, frameNow: { _ in button.offsetBy(dx: 0, dy: 200) }, present: listedNow) == .changed)
        // What the live trial of #955 met: the Beacon button of a tab switched away still answered its old frame.
        kept.keep("button", for: "click@1")
        check("one that still answers its old frame but is no longer among the window's controls refuses (#955)",
              kept.settle("button", hit: nil, for: "click@1", at: point, frameNow: here, present: { _ in false }) == .changed)
        kept.keep("button", for: "click@1")
        check("and so does one hidden, which the window's controls read now leave out as they leave out a removed one",
              kept.settle("button", hit: nil, for: "click@1", at: point, frameNow: here, present: { $0 != "button" }) == .changed)
        reads = 0
        kept.keep("button", for: "click@1")
        _ = kept.settle("button", hit: nil, for: "click@1", at: point, frameNow: { _ in nil }, present: listedNow)
        check("the window is not read for one whose frame already refuses it", reads == 0, "read \(reads) times")
        kept.keep("button", for: "click@1")
        check("a listed control that is the hit test's own find is acted on as any hit is, a real click allowed",
              kept.settle("button", hit: "button", for: "click@1", at: point, frameNow: here, present: listedNow) == .act("button"))
        // With no card (Ask before each action off, or the app allowed), a listed control from the last look is held
        // to the same test, and refused without one (#969).
        reads = 0
        check("with nothing kept, a listed control still there and at the point is acted on, after one read of the window",
              kept.settle("button", hit: nil, for: "click@1", at: point, frameNow: here, present: listedNow) == .act("button") && reads == 1,
              "read \(reads) times")
        check("with nothing kept, one no longer among the window's controls is refused, though it answers its old frame (#969)",
              kept.settle("button", hit: nil, for: "click@1", at: point, frameNow: here, present: { _ in false }) == .stale)
        check("and so is one that is gone, or moved off the point",
              kept.settle("button", hit: nil, for: "click@1", at: point, frameNow: { _ in nil }, present: listedNow) == .stale
                  && kept.settle("button", hit: nil, for: "click@1", at: point, frameNow: { _ in button.offsetBy(dx: 0, dy: 200) }, present: listedNow) == .stale)
        reads = 0
        check("with nothing kept, the hit test's own find, or nothing, is acted on as before, the window not read",
              kept.settle("Send", hit: "Send", for: "click@1", at: point, frameNow: here, present: listedNow) == .act("Send")
                  && kept.settle(nil, hit: nil, for: "click@1", at: point, frameNow: here, present: listedNow) == .act(nil) && reads == 0,
              "read \(reads) times")
        kept.keep("Send", for: "click@1")
        check("a card's choice is kept for its own action and point only",
              kept.settle("Cancel", hit: "Cancel", for: "context_menu@1", at: point, frameNow: here, present: listedNow) == .act("Cancel")
                  && kept.settle("Send", hit: "Send", for: "click@1", at: point, frameNow: here, present: listedNow) == .act("Send"))
        let stale = AtPoint.stale("no menu was opened", x: 120, y: 80)
        check("with no card, the refusal says the window changed since the last look, names no approval, and says to look again",
              stale.contains("changed since the last look") && !stale.contains("approval") && stale.contains("(120, 80)")
                  && stale.contains("so no menu was opened") && stale.contains("Take a screenshot"), stale)
        let refused = AtPoint.changed("nothing was clicked", x: 120, y: 80)
        check("the refusal says the window changed and to look again",
              refused.contains("window changed since the last look, or while this waited") && refused.contains("(120, 80)") && refused.contains("Take a screenshot"))
        let unanswered = AtPoint.unanswered("the \u{201C}Beacon\u{201D} button", "nothing was clicked", x: 1032, y: 680)
        check("a card's listed control that does not answer is said so, with no real click claimed",
              unanswered.hasPrefix("The \u{201C}Beacon\u{201D} button, which the approval named, did not answer")
                  && unanswered.contains("so nothing was clicked") && unanswered.contains("Take a screenshot"), unanswered)
    }

    await group("a click at a point in a parked copy lands on the listed control there (#748)") {
        // A hit test reads the screen, and all of a parked copy's window but its corner is off it, so the tool's
        // clicks at a point went as real clicks, which a copy in the background ignores. The listed controls say.
        let row = CGRect(x: 1770, y: 1440, width: 270, height: 30)
        let label = CGRect(x: 1800, y: 1445, width: 80, height: 20)
        let tab = CGRect(x: 2660, y: 1250, width: 50, height: 24)
        let frames = [row, label, tab, .zero, CGRect.null]
        check("the innermost control holding the point", WindowChoice.innermost(containing: CGPoint(x: 1810, y: 1450), in: frames) == 1)
        check("its container where only that holds it", WindowChoice.innermost(containing: CGPoint(x: 2000, y: 1450), in: frames) == 0)
        check("another control elsewhere", WindowChoice.innermost(containing: CGPoint(x: 2680, y: 1260), in: frames) == 2)
        check("nothing where no control is, and never a menu bar item's empty frame",
              WindowChoice.innermost(containing: CGPoint(x: 0, y: 0), in: frames) == nil
                  && WindowChoice.innermost(containing: CGPoint(x: 2300, y: 1300), in: frames) == nil)
    }

    await group("a parked window joins the app's accessibility list when the copy raises it once") {
        // As scripts/test-copy parks a copy's main window: never front, behind every ordinary window at level -1,
        // title bar's corner kept on screen. macOS leaves a window that has never been ordered out of the app's
        // accessibility window list until an ordering event joins it (#579), which is why every parked copy read
        // as "did not expose it through Accessibility" with no controls and no text.
        // A real app has a menu bar among the app element's children, which once hid the window behind a cast;
        // give this one a menu so the listing is read the way a real copy's is.
        NSApp.mainMenu = NSMenu(title: "Main")
        // This check app marked itself as wanting enhanced accessibility at launch, as an assistive app does. Turn that
        // off for this case: the raise then has to set the mark for a copy with no reader attached, and is seen to put
        // it back as it found it.
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(false, forAttribute: enhanced)
        let parked = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
        parked.isReleasedWhenClosed = false
        parked.title = "Parked"
        parked.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        check("a window that has never been ordered is not where another app's accessibility search finds it", !ParkedWindow.isReachable(parked))
        check("raising it once within its own level joins it to the list", ParkedWindow.expose(parked))
        check("it stays where the search finds it after it is put back behind everything", ParkedWindow.isReachable(parked))
        check("the mark for enhanced accessibility is put back as it was found", ParkedWindow.enhancedMark == false)
        let before = parked.frame
        _ = ParkedWindow.expose(parked)
        check("exposing does not move the window", parked.frame == before, "frame was \(before), now \(parked.frame)")
        let bounds = CGRect(x: before.minX, y: 900 - before.maxY, width: before.width, height: before.height)
        let record = ServerWindow(id: 7, pid: 42, layer: -1, frame: bounds)
        check("the parked record still pairs with the exposed window",
              ServerWindow.parkedCopy(in: [record], pid: 42)?.id == 7 && ServerWindow.matching(bounds, in: [record], pid: 42)?.id == 7)
        // A copy opened by hand gets no PI2_WINDOW_BEHIND: its window is among ordinary windows, where raising it
        // would put it over the person's work, so it is never raised (#579).
        let ordinary = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        ordinary.isReleasedWhenClosed = false
        check("a window among ordinary windows is not parked, and is never raised",
              !ParkedWindow.isParked(ordinary) && !ParkedWindow.expose(ordinary) && !ParkedWindow.isReachable(ordinary))
        ordinary.close()
        parked.close()
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        check("the mark reads as set again, as an assistive app leaves it", ParkedWindow.enhancedMark == true)
    }

    await group("a parked window the app answers as its main or focused window is reachable, listed or not (#612)") {
        // What a live copy's app element answered once AppKit stopped counting its parked window as on the active
        // Space: the window as its main and focused window, an empty window list, and only the menu bar among its
        // children. The computer tool read and clicked it through the main window; test-copy can-click, which asked
        // the children alone, said no. A check cannot move a window off the active Space, so these are the answers.
        let parked = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        parked.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer { parked.close(); other.close() }
        let menuBar = NSMenu(title: "Main")
        check("answered as the main window, though out of the windows and the children, it is reachable",
              ParkedWindow.reachable(parked, main: parked, focused: nil, windows: [], children: [menuBar]))
        check("answered as the focused window alone, it is reachable",
              ParkedWindow.reachable(parked, main: nil, focused: parked, windows: [], children: []))
        check("listed among the children beside a menu bar, it is reachable",
              ParkedWindow.reachable(parked, main: nil, focused: nil, windows: [], children: [menuBar, parked]))
        check("in none of them, it is not, though another window is the main one",
              !ParkedWindow.reachable(parked, main: other, focused: other, windows: [other], children: [menuBar, other]))
    }

    await group("the tool's expose request reaches the copy's control folder and is taken for its answer") {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi2-computer-check-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var folder = standInFolder(base)
        var copy = standInCopy(folder, ["result": "Exposed the parked main window"])
        check("a copy that answers success is taken as exposed",
              await ComputerController.exposeParkedCopy(pid: 42, folder: folder) == .listed)
        let asked = await copy.value
        check("the request names the copy's pid and the expose command",
              (asked?["pid"] as? Int) == 42 && (asked?["command"] as? String) == "expose",
              "request: \(String(describing: asked))")
        check("the tool cleans its request up afterwards",
              (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true)
        folder = standInFolder(base)
        copy = standInCopy(folder, ["error": "unknown test-copy window command"])
        check("a copy whose build predates the request says so",
              await ComputerController.exposeParkedCopy(pid: 42, folder: folder) == .oldBuild)
        folder = standInFolder(base)
        copy = standInCopy(folder, ["error": "the main window did not join the app's accessibility window list when raised"])
        let refused = "the main window did not join the app's accessibility window list when raised"
        check("a copy that says its window did not join the list is a failure, in its own words",
              await ComputerController.exposeParkedCopy(pid: 42, folder: folder) == .failed(refused))
        // A copy that raised its window and found the window server's record of it disagrees did not fail to raise it.
        let disagrees = "the window server has the main window at 1120×740 at (3560, 1130) and accessibility gives it at 1120×700 at (1760, 1130), \(ParkedWindow.notTaken) as the same window"
        folder = standInFolder(base)
        copy = standInCopy(folder, ["error": disagrees])
        check("a copy whose window the tool would turn down is told apart from one that did not raise it (#770)",
              await ComputerController.exposeParkedCopy(pid: 42, folder: folder) == .turnedDown(disagrees))
        folder = standInFolder(base)
        check("a copy that never answers is busy, and its request is cleaned up",
              await ComputerController.exposeParkedCopy(pid: 42, folder: folder) == .busy
                  && (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true)
        // A symlink for the control folder or its data folder is refused before anything is written.
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        try? FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let linked = base.appendingPathComponent("linked", isDirectory: true)
        try? FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: elsewhere.path)
        check("a symlinked control folder is refused without a request",
              await ComputerController.exposeParkedCopy(pid: 42, folder: linked) == .failed("its control folder is not a folder or is a symbolic link")
                  && (try? FileManager.default.contentsOfDirectory(atPath: elsewhere.path))?.isEmpty == true)
        check("a control folder under a symlinked data folder is refused too",
              await ComputerController.exposeParkedCopy(pid: 42, folder: linked.appendingPathComponent("test-copy-control"))
                  == .failed("its data folder is missing or a symbolic link"))
        // A copy from a build before #579 has no folder of its own to make one in: the request has to reach it, so that
        // its answer is that its build predates the request rather than silence.
        let absent = standInFolder(base).appendingPathComponent("test-copy-control", isDirectory: true)
        let unanswered = await ComputerController.exposeParkedCopy(pid: 42, folder: absent)
        check("a control folder the copy has not made yet is made, and the request is sent",
              unanswered == .busy && FileManager.default.fileExists(atPath: absent.path))
    }

    await group("each reason a parked copy's window cannot be read is said with what to do next") {
        let old = ComputerController.unreadableParkedCopy(.oldBuild)
        check("a copy from an older build is told to rebuild it and reopen it",
              old.contains("rebuild") && old.contains("scripts/test-copy reopen"))
        let busy = ComputerController.unreadableParkedCopy(.busy)
        check("a copy that did not answer is told to take another screenshot shortly",
              busy.contains("did not answer") && busy.contains("in a moment"))
        let listed = ComputerController.unreadableParkedCopy(.listed)
        check("a copy that raised its window is not said to have failed to join it",
              listed.contains("raised") && !listed.contains("did not"))
        let failed = ComputerController.unreadableParkedCopy(.failed("the main window is not parked behind other windows, so it was not raised"))
        check("a copy that refused says why in the copy's own words",
              failed.contains("not parked behind other windows"))
        let why = ParkedWindow.refusal(id: 1, frame: CGRect(x: 0, y: 0, width: 900, height: 550),
                                       server: [ServerWindow(id: 1, pid: 42, layer: -1, frame: CGRect(x: 2000, y: 0, width: 900, height: 500))],
                                       pid: 42, main: true) ?? ""
        let turnedDown = ComputerController.unreadableParkedCopy(.turnedDown(why))
        check("a copy that raised its window, which the tool then turned down, is said to have raised it, and where each has it (#770)",
              turnedDown.contains("raised") && !turnedDown.contains("did not raise")
                  && turnedDown.contains("window server and accessibility disagree on where it is") && turnedDown.contains("900×500 at (2000, 0)"),
              turnedDown)
        check("every reason says what still works",
              [old, busy, listed, failed, turnedDown, ComputerController.unreadableParkedCopy(nil)].allSatisfy { $0.contains("click at a point") })
    }

    await group("what a click is told when the window could not be read") {
        // A parked copy before #579 had no listed controls, so every click's fingerprint was empty before and
        // after, and each click — working or not — was answered "Nothing in the window appears to have changed".
        let unreadable = ComputerController.clickOutcome(before: "", after: "", atPoint: true)
        check("never say a click changed nothing from a fingerprint with nothing in it",
              unreadable?.contains("cannot say whether the click changed anything") == true,
              "note: \(String(describing: unreadable))")
        check("a comparable fingerprint that did not change still says so",
              ComputerController.clickOutcome(before: "button|Send| |false|false|20", after: "button|Send| |false|false|20", atPoint: true)?.contains("Nothing in the window appears to have changed") == true)
        check("a click on a listed control is told in the control's words",
              ComputerController.clickOutcome(before: "button|Send| |false|false|20", after: "button|Send| |false|false|20", atPoint: false)?.contains("answers to no accessibility press") == true)
        check("a fingerprint that changed says nothing at all",
              ComputerController.clickOutcome(before: "button|Send| |false|false|20", after: "button|Send|x|false|false|20", atPoint: true) == nil)
        check("the control folder is the data folder a test copy's bundle id names",
              TestCopy.controlFolder(bundleID: "DEV.PI2.APP.TEST-579")?.path.hasSuffix("Application Support/pi2-test-579/test-copy-control") == true)
        check("an id that is not a test copy's has no control folder",
              TestCopy.controlFolder(bundleID: "dev.pi2.app.dev") == nil && TestCopy.controlFolder(bundleID: "com.apple.TextEdit") == nil
                  && TestCopy.controlFolder(bundleID: "dev.pi2.app.test-") == nil)
    }

    await group("a menu bar item is named by its count and its new window takes precedence") {
        let item = StandInStatusItem()
        item.setAccessibilityLabel("2 requests waiting")
        let main = Stage(Text("Main"))
        defer { main.window.close(); item.panel.window.close() }
        check("show the accessible label when it carries the count", StatusItems.label(title: "pi²", description: Local(object: item).label, help: nil) == "2 requests waiting")
        check("use the title when the description is empty", StatusItems.label(title: "pi²", description: " ", help: nil) == "pi²")
        check("use AXPress rather than a screen click", StatusItems.action(in: ["AXPress", "AXShowMenu"]) == "AXPress" && Local(object: item).press())
        check("use AXShowMenu when it is the only advertised action", StatusItems.action(in: ["AXShowMenu"]) == "AXShowMenu")
        let before = [main.window]
        let after = item.pressed ? before + [item.panel.window] : before
        let order = WindowChoice.order(after, beforePress: before, preferred: nil)
        check("the popup wins even if main is listed first", order.first === item.panel.window)
        check("read the popup as a normal window", await item.panel.until { $0.contains { $0.label == "Review request" } })
        check("keep the popup through a subsequent look", WindowChoice.order(after, beforePress: nil, preferred: item.panel.window).first === item.panel.window)
        check("return to main after the popup closes", WindowChoice.order(before, beforePress: nil, preferred: item.panel.window).first === main.window)
        let panel = ServerWindow(id: 2, pid: 42, layer: 8, frame: CGRect(x: 50, y: 0, width: 360, height: 300), onScreen: true)
        let icon = ServerWindow(id: 3, pid: 42, layer: 25, frame: CGRect(x: 50, y: 0, width: 110, height: 24), onScreen: true)
        check("a newly shown popup can be found by ID instead of AX", ServerWindow.statusPopup(in: [icon, panel], pid: 42, before: [1], preferred: nil)?.id == 2)
        check("a hidden popup is not reused", ServerWindow.statusPopup(in: [ServerWindow(id: 2, pid: 42, layer: 8, frame: item.panel.window.frame)], pid: 42, before: nil, preferred: 2) == nil)
    }

    await group("a precise scroll-wheel page uses the viewport, and its reply uses observed movement") {
        let short = scrollView(documentHeight: 900), long = scrollView(documentHeight: 90_000)
        let point = CGPoint(x: 100, y: 100)
        let shortPage = Scrolling.distance(pages: 1, viewport: short.contentView.bounds)
        let longPage = Scrolling.distance(pages: 1, viewport: long.contentView.bounds)
        check("the same height requests the same wheel distance whatever the document length", shortPage == 200 && longPage == shortPage)
        check("up reverses the delta and multi-page requests are bounded", Scrolling.distance(pages: Int.min, viewport: long.contentView.bounds) == -2000)
        if let event = Input.scrollEvent(at: point, points: longPage) {
            check("the event is a precise wheel at the destination", event.type == .scrollWheel && event.location == point && event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
            let wheel = NSEvent(cgEvent: event)
            check("AppKit reads one precise vertical page and no horizontal movement", wheel?.hasPreciseScrollingDeltas == true
                  && wheel?.scrollingDeltaY == -CGFloat(longPage) && wheel?.scrollingDeltaX == 0)
            let up = Input.scrollEvent(at: point, points: -longPage).flatMap(NSEvent.init(cgEvent:))
            check("AppKit reads the opposite delta for an upward page", up?.scrollingDeltaY == CGFloat(longPage))
        } else {
            check("synthesized a wheel event without posting it", false)
        }
        let move = Input.moveEvent(at: point, windowID: 17)
        let fields: [CGEventField] = [.mouseEventWindowUnderMousePointer, .mouseEventWindowUnderMousePointerThatCanHandleThisEvent]
        check("the companion mouse move carries the destination window ID", move?.location == point && fields.allSatisfy { move?.getIntegerValueField($0) == 17 })
        // Simulate a view that clips a 200-point page at its end after only 85. Unordered NSScrollViews on a
        // headless runner may not process scrollWheel(with:) like a visible view, so don't rely on event delivery.
        let clip = short.contentView
        let limit = 900 - clip.bounds.height
        let start = limit - 85
        clip.scroll(to: CGPoint(x: 0, y: start))
        let before = clip.bounds.minY
        clip.scroll(to: CGPoint(x: 0, y: min(limit, start + CGFloat(shortPage))))
        let moved = clip.bounds.minY - before
        let anchors = [CGRect(x: 20, y: 20, width: 100, height: 18), CGRect(x: 20, y: 85, width: 100, height: 18)]
        check("report the measured partial page, not the request", moved == 85 && Scrolling.movement(before: anchors, after: anchors.map { $0.offsetBy(dx: 0, dy: -moved) }, oldValue: nil, newValue: nil) == .points(85), "clip view moved \(moved)")
        check("report a scrollbar-only change as a fraction", Scrolling.movement(before: anchors, after: [nil, nil], oldValue: 0.5, newValue: 0.625) == .fraction(0.125))
        check("distinguish no measured movement from no measurement", Scrolling.movement(before: anchors, after: anchors, oldValue: 1, newValue: 1) == .still
              && Scrolling.movement(before: anchors, after: [nil, nil], oldValue: nil, newValue: nil) == .unknown)
    }

    await group("a window's picture is that window alone, at its own frame, so a point read off it is the point clicked (#798)") {
        // What #793 saw: a Models sheet of 520×592 points over Settings, its Done button listed at (952,1124), and a
        // picture of Settings with the sheet over it, scaled into the sheet's size, Done elsewhere in it. ScreenCaptureKit
        // draws a window with the windows attached to it unless told not to; a parked copy's sheet was not drawn at all.
        // Whether it honours that for a sheet is for a live capture (docs/development.md); this checks what is asked of it.
        let parent = CGRect(x: 1760, y: 1154, width: 660, height: 680)
        let sheet = CGRect(x: parent.minX + 70, y: parent.minY + 28, width: 520, height: 592)
        let done = CGPoint(x: sheet.minX + 476, y: sheet.minY + 562)
        let asked = WindowCapture.configuration(for: sheet)
        check("the window is pictured without the windows attached to it", !asked.includeChildWindows)
        check("without its shadow or the pointer", asked.ignoreShadowsSingleWindow && !asked.showsCursor)
        check("at its own frame's size, at two pixels a point", asked.width == 1040 && asked.height == 1184, "asked for \(asked.width)×\(asked.height)")
        // The controls are listed as the look lists them: their place in the window's frame, at the picture's scale.
        let scale = CGFloat(asked.width) / sheet.width
        let listed = CGPoint(x: ((done.x - sheet.minX) * scale).rounded(), y: ((done.y - sheet.minY) * scale).rounded())
        check("a control is listed where it is in that picture", listed == CGPoint(x: 952, y: 1124)
              && CGRect(x: 0, y: 0, width: asked.width, height: asked.height).contains(listed), "listed at \(listed)")
        check("and the picture's point is the control's point on the screen",
              CGPoint(x: sheet.minX + listed.x / scale, y: sheet.minY + listed.y / scale) == done)
        check("a picture that came back at the sheet's size, or a pixel off by rounding, is taken",
              WindowCapture.fits(CGSize(width: 1040, height: 1184), frame: sheet) && WindowCapture.fits(CGSize(width: 1040, height: 1185), frame: sheet))
        check("one at the parent's proportions is refused, rather than listing controls off it",
              !WindowCapture.fits(CGSize(width: 1320, height: 1360), frame: sheet) && !WindowCapture.fits(CGSize(width: 1040, height: 1071), frame: sheet))
        let wide = WindowCapture.configuration(for: CGRect(x: 0, y: 0, width: 2000, height: 1000))
        check("a window wider than the limit is pictured at one scale on both axes", wide.width == 1280 && wide.height == 640
              && WindowCapture.fits(CGSize(width: wide.width, height: wide.height), frame: CGRect(x: 0, y: 0, width: 2000, height: 1000)),
              "asked for \(wide.width)×\(wide.height)")
        check("nothing is taken for a window with no size", !WindowCapture.fits(CGSize(width: 1, height: 1), frame: .zero))
    }

    print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
    exit(failures == 0 ? 0 : 1)
}
app.run()
