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
//   copy exposes its own (#579), that the tool's request reaches the copy's control folder and is taken for its
//   answer, and that a click on a window with no listed controls is never said to have changed nothing;
// - the size and direction of the wheel event (as AppKit decodes it, without posting it), and how actual movement
//   is reported.
//
//   cd app && swift build --product pi2-computer-check && .build/debug/pi2-computer-check
//
// What it cannot do is open a menu, which would put it on the screen, or reach another app the way the computer tool
// does: listing an open menu's items, choosing one and closing it are left to a try with the computer tool, in a test
// copy (docs/computer-use.md). Exits 1 if anything failed.

import AppKit
import ComputerKit
import CoreGraphics
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

    await group("a parked window joins the app's accessibility list when the copy raises it once") {
        // As scripts/test-copy parks a copy's main window: never front, behind every ordinary window at level -1,
        // title bar's corner kept on screen. macOS leaves a window that has never been ordered out of the app's
        // accessibility window list until an ordering event joins it (#579), which is why every parked copy read
        // as "did not expose it through Accessibility" with no controls and no text.
        // A real app has a menu bar among the app element's children, which once hid the window behind a cast;
        // give this one a menu so the listing is read the way a real copy's is.
        NSApp.mainMenu = NSMenu(title: "Main")
        let parked = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
        parked.isReleasedWhenClosed = false
        parked.title = "Parked"
        parked.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        check("a window that has never been ordered is not in the app's accessibility window list", !ParkedWindow.isListed(parked))
        check("raising it once within its own level joins it to the list", ParkedWindow.expose(parked))
        check("it stays in the list after it is put back behind everything", ParkedWindow.isListed(parked))
        let before = parked.frame
        _ = ParkedWindow.expose(parked)
        check("exposing does not move the window", parked.frame == before, "frame was \(before), now \(parked.frame)")
        let bounds = CGRect(x: before.minX, y: 900 - before.maxY, width: before.width, height: before.height)
        let record = ServerWindow(id: 7, pid: 42, layer: -1, frame: bounds)
        check("the parked record still pairs with the exposed window",
              ServerWindow.parkedCopy(in: [record], pid: 42)?.id == 7 && ServerWindow.matching(bounds, in: [record], pid: 42)?.id == 7)
        parked.close()
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
        check("a copy that says its window did not join the list is a failure",
              await ComputerController.exposeParkedCopy(pid: 42, folder: folder) == .failed)
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
              await ComputerController.exposeParkedCopy(pid: 42, folder: linked) == .failed
                  && (try? FileManager.default.contentsOfDirectory(atPath: elsewhere.path))?.isEmpty == true)
        check("a control folder under a symlinked data folder is refused too",
              await ComputerController.exposeParkedCopy(pid: 42, folder: linked.appendingPathComponent("test-copy-control")) == .failed)
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

    print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
    exit(failures == 0 ? 0 : 1)
}
app.run()
