// Checks the conversation page loaded ahead for the next pane (#441, TranscriptKit's SparePage): that the page handed
// over is the one loaded ahead and has never shown a conversation, that it shows the conversation it is sent next and
// nothing of another, that a page taken while still loading says it is ready once it is, that no page is handed over
// twice, and that a page loaded ahead whose process ends is let go and another loaded in its place. Also where a page
// waits: in the window, unseen, out of reach of clicks, focus and VoiceOver, and that it moves into its pane without
// ever leaving the window (WebKit is slow to draw a page put back in one); or in no window, when none keeps a place.
// Then the page's layouts (#671): the Mac's page unmarked and the phone's marked before its scripts run; the page drawn
// at a phone's width, 390 points, as the phone's view marks it (Narrow.swift), and at the Mac's narrowest pane as before.
// Then a `present` call's card (#967, Presenting.swift), wide and at a phone's width. `--pictures <folder>` writes them
// as drawn there.
//
// The real page is loaded from the repository (`Web/transcript`; run it from `app/`, or pass `--page <folder>`), in
// web views of this program's own, in a window that never comes on screen, holding a place for the page loaded ahead
// and panes for the pages handed over, as the app's window does.
// To end a page's process it asks WebKit for the process's id, through a call that is not public
// (`_webProcessIdentifier`), and ends it by that id: a process its own web view started, never another's.
//
//   cd app && swift build --product pi2-transcript-check && .build/debug/pi2-transcript-check [--pictures build/shots/671]
//
// What it cannot see is the app's own bridge feeding a pane's page (the engine is not here): that is tried by hand in a
// throwaway copy. Exits 1 if anything failed.

import AppKit
import TranscriptKit
import WebKit

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

/// Waits for something, for as long as it takes on a loaded Mac; the limit only stops a hang.
@MainActor
func until(_ what: String, _ holds: () async -> Bool) async -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < 120 {
        if await holds() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    check(what, false, "not after two minutes")
    return false
}

@MainActor
func js(_ view: WKWebView, _ script: String) async -> Any? { try? await view.evaluateJavaScript(script) }

/// The page's web content process, which this program's own web view started, through a WebKit call that is not public.
@MainActor
func process(of view: WKWebView) -> pid_t? {
    guard view.responds(to: NSSelectorFromString("_webProcessIdentifier")),
          let pid = (view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
    return pid
}

/// What the page shows of a conversation: the text of its rows.
@MainActor
func shown(_ view: WKWebView) async -> String {
    await js(view, "document.getElementById('transcript').textContent") as? String ?? "(no page)"
}

/// A conversation as the app sends it to a page that has just loaded: from the start, with its names.
func conversation(_ id: Int, _ words: String) -> String {
    let message: [String: Any] = [
        "reset": true,
        "names": ["conversationId": id, "agentName": "Atlas", "mcp": [:], "agents": [], "apps": [:], "folder": false],
        "items": [
            ["id": id * 10 + 1, "kind": "user", "text": "A message to \(words)", "timestamp": 0],
            ["id": id * 10 + 2, "kind": "assistant", "text": "An answer from \(words)", "timestamp": 0],
        ],
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
}

@MainActor
func send(_ view: WKWebView, _ json: String) async {
    _ = try? await view.callAsyncJavaScript("window.pi2.receive(message)", arguments: ["message": json], in: nil, contentWorld: .page)
}

/// A window that never comes on screen, holding the place where a page waits (`SparePageHost`) and the panes the pages
/// handed over go into, as the app's window does.
@MainActor
final class Window {
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))

    init() {
        window.isReleasedWhenClosed = false
        window.contentView = root
    }

    /// Puts a view in the window, filling it.
    func add(_ view: NSView) {
        view.frame = root.bounds
        root.addSubview(view)
    }

    /// A pane showing the page, as the app makes one for a conversation.
    @discardableResult
    func pane(_ page: TranscriptWebKitView) -> TranscriptPane {
        let pane = TranscriptPane(page: page)
        add(pane)
        return pane
    }
}

@MainActor
func run(folder: URL) async {
    let spare = SparePage(folder: folder, delay: .milliseconds(50))
    var handed: [TranscriptWebKitView] = []
    let window = Window()
    let host = SparePageHost(spare: spare)
    window.add(host)

    await group("before any page is taken, none is loaded ahead; the first is new, and one is loaded ahead after it") {
        check("nothing is loaded ahead before the first pane", spare.page == nil)
        let first = spare.take()
        handed.append(first)
        check("nothing is loaded ahead at once", spare.page == nil)
        guard await until("a page is loaded ahead after a moment", { spare.page != nil }) else { return }
        check("it is another view", spare.page !== first)
        guard await until("the first page says it is ready", { first.isReady }) else { return }
        window.pane(first)
    }

    await group("the page loaded ahead says it is ready with nobody listening, and holds nothing") {
        guard let ahead = spare.page, await until("it says it is ready", { ahead.isReady }) else { return }
        let text = await shown(ahead)
        check("it shows nothing", text == "", "shows \(text.debugDescription)")
        check("it waits where the window keeps it", ahead.superview === host && ahead.window === window.window)
        check("unseen", ahead.alphaValue == 0)
        check("taking no focus", !ahead.acceptsFirstResponder && !ahead.canBecomeKeyView)
        check("no clicks", host.hitTest(NSPoint(x: 10, y: 10)) == nil)
        check("and out of VoiceOver's view", host.accessibilityChildren()?.isEmpty == true)
    }

    await group("a pane gets the page loaded ahead, and it shows the conversation it is sent") {
        let ahead = spare.page
        let page = spare.take()
        check("it is the page loaded ahead", page === ahead && ahead != nil)
        check("it is ready already", page.isReady)
        check("nothing is loaded ahead at once after", spare.page == nil)
        handed.append(page)
        let pane = TranscriptPane(page: page)
        check("it stays where it waited until its pane is in the window", page.superview === host)
        window.add(pane)
        check("then it is in its pane", page.superview === pane && page.frame == pane.bounds, "in \(String(describing: page.superview)), \(page.frame)")
        check("having never left the window", page.window === window.window && page.timesOutOfWindow == 0, "out \(page.timesOutOfWindow) times")
        check("and takes focus again", page.acceptsFirstResponder)
        await send(page, conversation(7, "conversation seven"))
        guard await until("it shows conversation seven", { await shown(page).contains("A message to conversation seven") }) else { return }
        check("and its answer", await shown(page).contains("An answer from conversation seven"))
    }

    await group("the next pane gets a clean page: nothing of the conversation the one before it shows") {
        guard await until("another page is loaded ahead", { spare.page?.isReady == true }), let ahead = spare.page else { return }
        let empty = await shown(ahead)
        check("the page loaded ahead shows nothing", empty == "", "shows \(empty.debugDescription)")
        let page = spare.take()
        check("it is the page loaded ahead", page === ahead)
        check("it is not a page handed over before", !handed.contains { $0 === page })
        handed.append(page)
        window.pane(page)
        await send(page, conversation(8, "conversation eight"))
        guard await until("it shows conversation eight", { await shown(page).contains("A message to conversation eight") }) else { return }
        let text = await shown(page)
        check("and nothing of conversation seven", !text.contains("seven"), "shows \(text.debugDescription)")
        let before = await shown(handed[1])
        check("the pane before still shows conversation seven alone", before.contains("conversation seven") && !before.contains("eight"), "shows \(before.debugDescription)")
    }

    await group("a page taken while it is still loading says it is ready once it has loaded") {
        _ = await until("a page is loaded ahead", { spare.page != nil })
        handed.append(spare.take())
        // Taken in the same turn as another is loaded ahead: it cannot have loaded yet.
        spare.load()
        let page = spare.take()
        var readies = 0
        page.onMessage = { body in
            if (body as? [String: Any])?["type"] as? String == "ready" { readies += 1 }
        }
        check("it is not ready yet", !page.isReady)
        handed.append(page)
        window.pane(page)
        guard await until("it says it is ready", { readies == 1 }) else { return }
        check("and is", page.isReady)
        await send(page, conversation(9, "conversation nine"))
        check("it shows the conversation it is sent", await until("it shows conversation nine", { await shown(page).contains("conversation nine") }))
    }

    await group("a page loaded ahead whose process ends is let go, and another loaded in its place") {
        guard await until("a page is loaded ahead", { spare.page?.isReady == true }), let dead = spare.page else { return }
        guard let pid = process(of: dead) else {
            check("WebKit names the page's process for this check", false, "no _webProcessIdentifier")
            return
        }
        Darwin.kill(pid, SIGKILL)
        guard await until("it is let go", { spare.replaced == 1 }) else { return }
        guard await until("another is loaded ahead", { spare.page?.isReady == true }), let next = spare.page else { return }
        check("the new one is another view", next !== dead)
        check("it shows nothing", await shown(next) == "")
        let page = spare.take()
        check("the pane gets the new one", page === next)
        handed.append(page)
        window.pane(page)
    }

    await group("no page is handed over twice, and one at most is loaded ahead") {
        for _ in 0..<3 { handed.append(spare.take()) }
        check("every page handed over is another view", Set(handed.map(ObjectIdentifier.init)).count == handed.count, "\(handed.count) pages")
        guard await until("a page is loaded ahead", { spare.page != nil }), let ahead = spare.page else { return }
        spare.load()
        check("loading again keeps the same page", spare.page === ahead)
        try? await Task.sleep(for: .milliseconds(200))
        check("and loads no other", spare.page === ahead)
    }

    if let ahead = spare.page, let pid = process(of: ahead) {
        // For the record: what a page waiting costs (its web content process).
        let ps = Process()
        let out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "rss=", "-p", String(pid)]
        ps.standardOutput = out
        if (try? ps.run()) != nil {
            ps.waitUntilExit()
            let rss = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let kb = Int(rss) { print("info  the page loaded ahead: its process holds \(kb / 1024) MB resident") }
        }
    }
    await group("a page waits in no window while no place in a window is kept for it, and comes into its pane at once") {
        guard await until("a page is loaded ahead", { spare.page?.isReady == true }), let ahead = spare.page else { return }
        host.removeFromSuperview()
        check("it is in no window", ahead.window == nil)
        let page = spare.take()
        let pane = TranscriptPane(page: page)
        check("its pane takes it at once", page === ahead && page.superview === pane)
        window.add(pane)
        handed.append(page)
        guard await until("another is loaded ahead", { spare.page != nil }), let next = spare.page else { return }
        check("which waits in no window", next.window == nil)
        let another = SparePageHost(spare: spare)
        window.add(another)
        check("until a place is kept for it again", next.superview === another && next.window === window.window)
    }

    window.window.close()
    for page in handed { page.close() }
}

/// The classes the page's root element has.
@MainActor
func marks(_ view: WKWebView) async -> String {
    await js(view, "document.documentElement.className") as? String ?? "(no page)"
}

/// The page as the Mac draws it is not marked for a phone; marked, it is before its own scripts run, whatever its
/// Content-Security-Policy says of scripts (the mark is the app's, not the page's).
@MainActor
func layouts(folder: URL) async {
    await group("the Mac's page is not marked for a phone, and the phone's is, before its first drawing") {
        let mac = TranscriptWebKitView(folder: folder)
        let phone = TranscriptWebKitView(folder: folder, layout: .phone)
        defer { mac.close(); phone.close() }
        guard await until("both pages say they are ready", { mac.isReady && phone.isReady }) else { return }
        let wide = await marks(mac)
        check("the Mac's page has no mark", wide == "", "classes \(wide.debugDescription)")
        let narrow = await marks(phone)
        check("the phone's page is marked narrow and touch", narrow == "narrow touch", "classes \(narrow.debugDescription)")
        // The page's own scripts ran after the mark was set: what they saw is what the page draws with.
        let early = await js(phone, "document.documentElement.classList.contains('narrow') && typeof window.pi2?.receive === 'function'") as? Bool
        check("and the page's scripts ran with it", early == true)
    }
}

let app = NSApplication.shared
// No Dock icon, no menu bar, and never made active: the person's focus stays where it is.
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let arguments = CommandLine.arguments
    let folder = arguments.firstIndex(of: "--page").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "Web/transcript"
    let url = URL(fileURLWithPath: folder, isDirectory: true)
    if FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) {
        await run(folder: url)
        await layouts(folder: url)
        let pictures = arguments.firstIndex(of: "--pictures").flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1], isDirectory: true) : nil }
        if let pictures { try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true) }
        await narrow(folder: url, pictures: pictures)
        await presenting(folder: url, pictures: pictures)
        await presentingBridge(folder: url)
    } else {
        check("the conversation page is found", false, "no index.html in \(url.path); run from app/ or pass --page <folder>")
    }
    print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
    exit(failures == 0 ? 0 : 1)
}
app.run()
