import AppKit
import WebKit

/// The answer field for an agent's question on the conversation page (`app/Web/transcript`), which is a web page and
/// has its own copy of the rule (`keys.js`). The real page is loaded from the repository in a web view in a window that
/// never comes on screen, given a question as the app gives it one, and key presses are handed to that window.
@MainActor
final class Page: NSObject, WKScriptMessageHandler {
    let folder: URL
    let window: NSWindow
    let web: WKWebView
    /// What the page posted to the app, other than that it is ready.
    var posts: [[String: Any]] = []

    init(folder: URL) {
        self.folder = folder
        let config = WKWebViewConfiguration()
        // Nothing kept on disk: no website data or cache left behind under this program's name.
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), configuration: config)
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init()
        config.userContentController.add(self, name: "pi2")
        window.contentView = web
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            if let body = message.body as? [String: Any], body["type"] as? String != "ready" { posts.append(body) }
        }
    }

    func js(_ script: String) async -> Any? { try? await web.evaluateJavaScript(script) }

    var value: String { get async { await js("document.querySelector('.answer-field').value") as? String ?? "(no field)" } }

    /// Waits for something on the page, for as long as it takes on a loaded Mac; the limit only stops a hang.
    func until(_ what: String, _ script: String) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < 120 {
            if await js(script) as? Bool == true { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        check(what, false, "not after two minutes")
        return false
    }

    /// Presses Return with the given modifiers, then waits for the page to have handled it: a script sent after the
    /// key reaches the page after it, and so does anything the page posts back before that script's answer.
    func press(_ modifiers: NSEvent.ModifierFlags = []) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36)!
            window.sendEvent(event)
        }
        _ = await js("true")
    }

    /// Puts text in the field with the cursor or a selection, as typing would leave it.
    func set(_ text: String, from start: Int, to end: Int) async {
        let literal = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        // A block, so that `field` is declared afresh each time.
        _ = await js("{ const field = document.querySelector('.answer-field'); field.focus(); field.value = \(literal); field.setSelectionRange(\(start), \(end)); field.dispatchEvent(new Event('input')); } true")
    }

    func run() async {
        web.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder)
        guard await until("the page loads", "typeof pi2 === 'object'") else { return }
        _ = await js(#"pi2.receive(JSON.stringify({reset: true, inbox: [{id: "q1", callId: "c1", kind: "question", question: "Which name should the file have?", agentName: "Atlas"}]})); true"#)
        guard await until("the question's card shows", "document.querySelector('.answer-field') !== null") else { return }
        window.makeFirstResponder(web)

        await group("the answer to a question: Shift-Return and Option-Return start a new line") {
            await set("hello world", from: 5, to: 5)
            let oneLine = await js("document.querySelector('.answer-field').offsetHeight") as? Int ?? 0
            await press(.shift)
            var text = await value
            check("Shift-Return puts a line break at the cursor", text == "hello\n world", "text is \(text.debugDescription)")
            let twoLines = await js("document.querySelector('.answer-field').offsetHeight") as? Int ?? 0
            check("the field grows", twoLines > oneLine, "height \(twoLines), one line \(oneLine)")
            await set("hello world", from: 6, to: 11)
            await press(.option)
            text = await value
            check("Option-Return replaces the selection with a line break", text == "hello \n", "text is \(text.debugDescription)")
            await press(.control)
            text = await value
            check("Control-Return does nothing", text == "hello \n", "text is \(text.debugDescription)")
            check("none of them sent", posts.isEmpty, "posted \(posts)")
        }

        await group("the answer to a question: Return while an input method is composing does not send") {
            await set("name ", from: 5, to: 5)
            _ = await js("window.composing = []; document.querySelector('.answer-field').addEventListener('keydown', (e) => composing.push(e.isComposing || e.keyCode === 229), true); true")
            // What an input method does while a candidate is being chosen: marked text at the cursor.
            guard let client = window.firstResponder as? NSTextInputClient else {
                check("the web view takes typing", false, "first responder is \(String(describing: window.firstResponder))")
                return
            }
            client.setMarkedText("なまえ", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            _ = await js("true")
            await press()
            let saw = await js("JSON.stringify(composing)") as? String ?? "nothing"
            check("the page saw the key as composing", saw == "[true]", "saw \(saw)")
            check("Return while composing does not send", posts.isEmpty, "posted \(posts)")
            client.unmarkText()
        }

        await group("the answer to a question: Return sends") {
            await set("line one\nline two", from: 17, to: 17)
            await press()
            check("Return sends the answer with its line break", posts.count == 1 && posts.last?["text"] as? String == "line one\nline two", "posted \(posts)")
            check("the answer is the question's", posts.last?["type"] as? String == "answer" && posts.last?["inbox"] as? String == "q1", "posted \(posts)")
        }
    }
}
