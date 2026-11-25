// A `present` call's card (#946, #967; docs/design/presenting.md, "The transcript page"), drawn by the real page from
// the contract's messages alone: a conversation as the mockups have it (docs/design/presenting/mockups.html#take=A),
// with one picture presented alone, three sign-in screens (B a page) whose version 1 has a newer version below, and
// that version 2 asking which to build. The pictures are drawn here and given only when the page asks for them
// (`presentedImage`), as the app's bridge will. Checks the cards, the rows folded under them, what Expand and the
// question's buttons post, and, at a phone's width, the tabs and that nothing reaches past the page's edge. With
// `--pictures <folder>`, writes them as drawn: wide and narrow, dark and light, and at a larger text size.

import AppKit
import TranscriptKit
import WebKit

/// The width of a pane that shows the page's column whole (its `max-width`, 816 points).
let wideWidth: CGFloat = 816

// MARK: - What the agent made: small sign-in screens, drawn as the mockups draw them

@MainActor
func screenPNG(_ kind: String, version: Int = 1, width: Int = 1440, height: Int = 900) -> String {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let graphics = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    let w = CGFloat(width), h = CGFloat(height)
    func fill(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 0) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    func text(_ string: String, _ point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, centredIn: CGFloat? = nil) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let words = NSAttributedString(string: string, attributes: attributes)
        var at = point
        if let width = centredIn { at.x += (width - words.size().width) / 2 }
        words.draw(at: at)
    }
    let field = NSColor(srgbRed: 0.84, green: 0.85, blue: 0.89, alpha: 1)
    let accent = NSColor(srgbRed: 0.36, green: 0.39, blue: 0.93, alpha: 1)
    let button: CGFloat = version > 1 ? 70 : 50
    switch kind {
    case "signin-a":
        fill(NSRect(x: 0, y: 0, width: w, height: h), NSColor(srgbRed: 0.93, green: 0.94, blue: 0.99, alpha: 1))
        let card = NSRect(x: w / 2 - 230, y: h / 2 - 280, width: 460, height: 560)
        fill(card.offsetBy(dx: 0, dy: 6), NSColor(white: 0, alpha: 0.06), radius: 22)
        fill(card, .white, radius: 22)
        fill(NSRect(x: w / 2 - 26, y: card.minY + 40, width: 52, height: 52), accent, radius: 14)
        text("Welcome back", NSPoint(x: card.minX, y: card.minY + 110), size: 34, weight: .bold, color: NSColor(white: 0.1, alpha: 1), centredIn: card.width)
        for (index, words) in ["name@example.com", "Password"].enumerated() {
            let box = NSRect(x: card.minX + 40, y: card.minY + 180 + CGFloat(index) * 78, width: card.width - 80, height: 58)
            fill(box, field, radius: 12)
            fill(box.insetBy(dx: 2, dy: 2), .white, radius: 11)
            text(words, NSPoint(x: box.minX + 18, y: box.minY + 16), size: 20, color: NSColor(white: 0.6, alpha: 1))
        }
        text("⚠︎ Caps Lock is on", NSPoint(x: card.minX + 40, y: card.minY + 340), size: 17, color: NSColor(srgbRed: 0.8, green: 0.45, blue: 0.05, alpha: 1))
        fill(NSRect(x: card.minX + 40, y: card.minY + 380, width: card.width - 80, height: button), accent, radius: 12)
        text("Sign in", NSPoint(x: card.minX, y: card.minY + 380 + button / 2 - 13), size: 21, weight: .semibold, color: .white, centredIn: card.width)
        text("Forgot your password?", NSPoint(x: card.minX, y: card.minY + 400 + button), size: 17, color: accent, centredIn: card.width)
    case "signin-b":
        fill(NSRect(x: 0, y: 0, width: w, height: h), .white)
        fill(NSRect(x: 0, y: 0, width: w * 0.48, height: h), NSColor(srgbRed: 0.12, green: 0.13, blue: 0.24, alpha: 1))
        fill(NSRect(x: 80, y: 90, width: 56, height: 56), accent, radius: 14)
        text("Plan less.", NSPoint(x: 80, y: 250), size: 64, weight: .bold, color: .white)
        text("Ship more.", NSPoint(x: 80, y: 330), size: 64, weight: .bold, color: .white)
        fill(NSRect(x: 80, y: 450, width: 380, height: 14), NSColor(white: 1, alpha: 0.25), radius: 7)
        fill(NSRect(x: 80, y: 480, width: 260, height: 14), NSColor(white: 1, alpha: 0.25), radius: 7)
        let left = w * 0.48 + 110
        text("Sign in", NSPoint(x: left, y: 150), size: 36, weight: .bold, color: NSColor(white: 0.1, alpha: 1))
        for (index, label) in ["Email", "Password"].enumerated() {
            let y = 230 + CGFloat(index) * 110
            text(label, NSPoint(x: left, y: y), size: 18, weight: .medium, color: NSColor(white: 0.35, alpha: 1))
            fill(NSRect(x: left, y: y + 32, width: 440, height: 56), field, radius: 10)
            fill(NSRect(x: left + 2, y: y + 34, width: 436, height: 52), .white, radius: 9)
        }
        fill(NSRect(x: left, y: 470, width: 440, height: button), accent, radius: 10)
        text("Continue", NSPoint(x: left, y: 470 + button / 2 - 13), size: 21, weight: .semibold, color: .white, centredIn: 440)
        text("or continue with", NSPoint(x: left, y: 500 + button), size: 16, color: NSColor(white: 0.55, alpha: 1), centredIn: 440)
        for (index, name) in ["Apple", "Google"].enumerated() {
            let box = NSRect(x: left + CGFloat(index) * 230, y: 540 + button, width: 210, height: 54)
            fill(box, field, radius: 10)
            fill(box.insetBy(dx: 2, dy: 2), .white, radius: 9)
            text(name, NSPoint(x: box.minX, y: box.minY + 15), size: 19, weight: .semibold, color: NSColor(white: 0.15, alpha: 1), centredIn: box.width)
        }
    case "signin-c":
        fill(NSRect(x: 0, y: 0, width: w, height: h), NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1))
        text("northwind", NSPoint(x: 160, y: 110), size: 26, weight: .heavy, color: NSColor(srgbRed: 0.1, green: 0.4, blue: 0.3, alpha: 1))
        text("Sign in", NSPoint(x: 160, y: 190), size: 80, weight: .bold, color: NSColor(white: 0.08, alpha: 1))
        for (index, words) in ["Email", "Password"].enumerated() {
            let y = 340 + CGFloat(index) * 100
            text(words, NSPoint(x: 160, y: y), size: 30, color: NSColor(white: 0.55, alpha: 1))
            fill(NSRect(x: 160, y: y + 54, width: 700, height: 3), NSColor(white: 0.1, alpha: 1))
        }
        fill(NSRect(x: 160, y: 590, width: 300, height: button + 10), NSColor(white: 0.08, alpha: 1))
        text("Sign in →", NSPoint(x: 160, y: 590 + button / 2 - 12), size: 26, weight: .semibold, color: .white, centredIn: 300)
        text("New here? Make an account", NSPoint(x: 160, y: 700 + button), size: 22, color: NSColor(white: 0.4, alpha: 1))
    default:
        // Settings › General, light text on dark, as a screenshot of the app.
        fill(NSRect(x: 0, y: 0, width: w, height: h), NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        fill(NSRect(x: 0, y: 0, width: w, height: 56), NSColor(srgbRed: 0.17, green: 0.17, blue: 0.2, alpha: 1))
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            fill(NSRect(x: 22 + CGFloat(index) * 26, y: 20, width: 16, height: 16), color, radius: 8)
        }
        text("Settings", NSPoint(x: 0, y: 14), size: 22, weight: .semibold, color: .white, centredIn: w)
        fill(NSRect(x: 0, y: 56, width: 300, height: h - 56), NSColor(srgbRed: 0.15, green: 0.15, blue: 0.18, alpha: 1))
        for (index, name) in ["General", "Chat", "Providers", "Tools", "Storage"].enumerated() {
            if index == 0 { fill(NSRect(x: 16, y: 80, width: 268, height: 44), accent, radius: 8) }
            text(name, NSPoint(x: 36, y: 88 + CGFloat(index) * 54), size: 21, color: .white)
        }
        text("General", NSPoint(x: 360, y: 90), size: 34, weight: .bold, color: .white)
        let rows = ["Appearance", "Notify when an agent finishes", "Notify at a limit", "Keep the Mac awake while agents work", "Default model for agents", "Check for updates"]
        for (index, name) in rows.enumerated() {
            let y = 170 + CGFloat(index) * 100
            fill(NSRect(x: 360, y: y + 80, width: w - 420, height: 1), NSColor(white: 1, alpha: 0.12))
            text(name, NSPoint(x: 360, y: y + 28), size: 22, color: NSColor(white: 0.92, alpha: 1))
            if index == 0 || index == 4 {
                fill(NSRect(x: w - 300, y: y + 20, width: 240, height: 44), NSColor(white: 1, alpha: 0.12), radius: 8)
                text(index == 0 ? "Dark" : "Claude Sonnet", NSPoint(x: w - 284, y: y + 29), size: 20, color: .white)
            } else {
                let on = index != 3
                fill(NSRect(x: w - 140, y: y + 22, width: 80, height: 40), on ? accent : NSColor(white: 1, alpha: 0.2), radius: 20)
                fill(NSRect(x: on ? w - 100 : w - 136, y: y + 26, width: 32, height: 32), .white, radius: 16)
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.base64EncodedString()
}

// MARK: - The conversation

func presentedPicture(_ label: String, _ name: String, _ caption: String, kind: String = "picture", width: Int = 1440, height: Int = 900, bytes: Int = 212_000) -> [String: Any] {
    var item: [String: Any] = ["label": label, "caption": caption, "kind": kind, "name": name, "sha256": String(repeating: "a", count: 64), "bytes": bytes,
                               "files": kind == "page" ? 7 : 1, "width": width, "height": height]
    if kind == "page" {
        item["mimeType"] = "text/html"
        item["snapshot"] = ["state": "drawn", "sha256": String(repeating: "b", count: 64)]
        item["drawn"] = ["loadMs": 412, "blank": false, "console": [], "blocked": []]
    } else {
        item["mimeType"] = name.hasSuffix(".svg") ? "image/svg+xml" : "image/png"
        item["snapshot"] = NSNull()
        item["drawn"] = NSNull()
    }
    return item
}

func signinItems() -> [[String: Any]] { [
    presentedPicture("A", "mockups/signin-a.png", "Today’s form in a card, on a soft wash"),
    presentedPicture("B", "mockups/signin-b/index.html", "The product’s promise beside the form; Apple and Google", kind: "page", width: 1280, height: 900, bytes: 1_200_000),
    presentedPicture("C", "mockups/signin-c.png", "Nothing but the fields, large type"),
] }
/// What each item of the fixture is drawn as, by "presentation/version/item".
let fixtureScreens: [String: (String, Int, Int, Int)] = [
    "p1/1/0": ("settings", 1, 1440, 900),
    "p2/1/0": ("signin-a", 1, 1440, 900), "p2/1/1": ("signin-b", 1, 1280, 900), "p2/1/2": ("signin-c", 1, 1440, 900),
    "p2/2/0": ("signin-a", 2, 1440, 900), "p2/2/1": ("signin-b", 2, 1280, 900), "p2/2/2": ("signin-c", 2, 1440, 900),
]

func presentQuestion() -> [String: Any] { [
    "text": "Which one should I build?", "choices": [["id": "1", "label": "Use A"], ["id": "2", "label": "Use B"], ["id": "3", "label": "Use C"]],
    "words": true, "need": "q-present-1", "answer": NSNull(),
] }

func presentedVersion(_ version: Int, _ callId: String, title: String, items: [[String: Any]], question: Any = NSNull()) -> [String: Any] {
    ["version": version, "callId": callId, "createdAt": 0, "title": title, "items": items, "question": question]
}

/// The conversation of the mockups, as the app would send it: entries, the live state, the question waiting, and the
/// presentations' records (`presented`).
func presentingConversation() -> String {
    let settings = [presentedPicture("", "app/build/shots/946/settings.png", "As it is now, in a throwaway copy (light text on dark)")]
    let p1 = presentedVersion(1, "c2", title: "Settings › General, as it is now", items: settings)
    let p2v1 = presentedVersion(1, "c4", title: "Sign-in screen, three layouts", items: signinItems())
    let p2v2 = presentedVersion(2, "c6", title: "Sign-in screen, three layouts", items: signinItems(), question: presentQuestion())
    func details(_ id: String, _ version: [String: Any]) -> [String: Any] { version.merging(["presentation": id]) { $1 } }
    let message: [String: Any] = [
        "reset": true,
        "names": ["conversationId": 7, "agentName": "Forge", "mcp": [:], "agents": [], "apps": [:], "folder": true],
        "items": [
            ["id": 1, "kind": "user", "text": "Show me three ideas for the sign-in screen. And the settings page as it is now, for comparison.", "timestamp": 0],
            ["id": 2, "kind": "assistant", "text": "", "timestamp": 0, "toolCalls": [
                ["callId": "c1", "name": "bash", "arguments": ["command": "scripts/test-copy shot test-946 app/build/shots/946/settings.png"]],
                ["callId": "c2", "name": "present", "arguments": ["title": "Settings › General, as it is now", "items": [["path": "app/build/shots/946/settings.png"]]]],
            ]],
            ["id": 3, "kind": "tool", "callId": "c1", "name": "bash", "isError": false, "timestamp": 0, "text": "Pictured test-946's window: 1440×900\n", "details": ["exitCode": 0]],
            ["id": 4, "kind": "tool", "callId": "c2", "name": "present", "isError": false, "timestamp": 0,
             "text": "Presented \"Settings › General, as it is now\" as p1, version 1.\n  app/build/shots/946/settings.png: PNG, 1440×900, 212 KB", "details": details("p1", p1)],
            ["id": 5, "kind": "assistant", "text": "Three ideas for the sign-in screen. A keeps today’s form, B puts the product’s promise beside it, C is the plainest.", "timestamp": 0, "toolCalls": [
                ["callId": "c3", "name": "write", "arguments": ["path": "mockups/signin-b/index.html", "content": "<!doctype html>\n<title>Sign in</title>\n"]],
                ["callId": "c4", "name": "present", "arguments": ["title": "Sign-in screen, three layouts", "items": [["path": "mockups/signin-a.png"], ["path": "mockups/signin-b/index.html"], ["path": "mockups/signin-c.png"]]]],
            ]],
            ["id": 6, "kind": "tool", "callId": "c3", "name": "write", "isError": false, "timestamp": 0, "text": "Wrote mockups/signin-b/index.html"],
            ["id": 7, "kind": "tool", "callId": "c4", "name": "present", "isError": false, "timestamp": 0,
             "text": "Presented \"Sign-in screen, three layouts\" as p2, version 1.\nB  mockups/signin-b/index.html: page, 7 files, 1.2 MB; loaded in 0.4 s; drawn 1280×900", "details": details("p2", p2v1)],
            ["id": 8, "kind": "user", "text": "Make the buttons bigger in all three, then I’ll pick.", "timestamp": 0],
            ["id": 9, "kind": "assistant", "text": "", "timestamp": 0, "toolCalls": [
                ["callId": "c5", "name": "edit", "arguments": ["path": "mockups/signin-a.html", "edits": [["oldText": "height: 50px", "newText": "height: 70px"]]]],
                ["callId": "c6", "name": "present", "arguments": ["title": "Sign-in screen, three layouts", "update": "p2", "question": "Which one should I build?",
                                                               "items": [["path": "mockups/signin-a.png"], ["path": "mockups/signin-b/index.html"], ["path": "mockups/signin-c.png"]]]],
            ]],
            ["id": 10, "kind": "tool", "callId": "c5", "name": "edit", "isError": false, "timestamp": 0, "text": "Edited mockups/signin-a.html"],
        ],
        "live": ["busy": true, "tools": [["callId": "c6", "name": "present", "status": "running"]]],
        "inbox": [["id": "q-present-1", "callId": "c6", "kind": "question", "tool": "present", "agentName": "Forge", "conversationId": 7, "question": "Which one should I build?"]],
        "presented": ["records": [
            ["id": "p1", "versions": [p1], "network": false],
            ["id": "p2", "versions": [p2v1, p2v2], "network": false],
        ]],
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
}

// MARK: - Drawing it

/// The page showing the conversation, `width` points wide, in a window that never comes on screen, answering the page's
/// `presentedImage` as the app's bridge will; `zoom` stands in for a larger text size. Every message the page posts is
/// kept in `posted`.
@MainActor
final class PresentingPage {
    let window: NSWindow
    let view: TranscriptWebKitView
    var posted: [[String: Any]] = []
    var asked: Set<String> = []

    init(folder: URL, layout: TranscriptLayout, width: CGFloat, appearance: NSAppearance.Name, zoom: CGFloat) {
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        view = TranscriptWebKitView(folder: folder, layout: layout)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        view.pageZoom = zoom
        window.contentView = view
        view.onMessage = { [weak self] body in
            guard let self, let message = body as? [String: Any] else { return }
            self.posted.append(message)
            if message["type"] as? String == "presentedImage" { Task { @MainActor in await self.answer(message) } }
        }
    }

    /// Answers a `presentedImage` as the app does: an `image` message with the picture, or without `data` for one it
    /// does not have.
    func answer(_ message: [String: Any]) async {
        guard let presentation = message["presentation"] as? String, let version = message["version"] as? Int, let item = message["item"] as? Int else { return }
        let key = "\(presentation)/\(version)/\(item)"
        asked.insert(key)
        var reply: [String: Any] = ["presented": ["presentation": presentation, "version": version, "item": item]]
        if let (kind, look, width, height) = fixtureScreens[key] {
            reply["mimeType"] = "image/png"
            reply["data"] = screenPNG(kind, version: look, width: width, height: height)
        }
        await send(view, String(data: try! JSONSerialization.data(withJSONObject: ["image": reply]), encoding: .utf8)!)
    }

    func load() async -> Bool {
        guard await until("the page says it is ready", { view.isReady }) else { return false }
        await send(view, presentingConversation())
        guard await until("it draws the cards", { await js(view, "document.querySelectorAll('.card.present').length") as? Int == 3 }) else { return false }
        // The page asks for the pictures near the screen; a page taller than its window asks for the rest as it is
        // scrolled, so it is scrolled down the whole page, and every frame waits for its picture.
        let height = (await js(view, "document.documentElement.scrollHeight") as? Double).map { ceil(CGFloat($0) * view.pageZoom) } ?? 900
        view.frame = NSRect(x: 0, y: 0, width: view.frame.width, height: max(900, height))
        window.setContentSize(view.frame.size)
        return await until("and every picture it shows comes", {
            await js(view, "[...document.querySelectorAll('.pa-frame')].every((f) => f.classList.contains('ready') && f.querySelector('img').complete && f.querySelector('img').naturalWidth > 0)") as? Bool == true
        })
    }

    func close() {
        view.close()
        window.close()
    }
}

/// What the cards say, read from the page.
let cardsScript = """
    const cards = [...document.querySelectorAll('.card.present')];
    return JSON.stringify(cards.map((card) => ({
        title: card.querySelector('.card-title')?.textContent ?? '',
        note: card.querySelector('.card-note')?.textContent ?? '',
        grid: card.querySelector('.pa-grid')?.className ?? '',
        frames: card.querySelectorAll('.pa-frame').length,
        labels: [...card.querySelectorAll('.pa-label')].map((e) => e.textContent),
        tabs: [...card.querySelectorAll('.pa-tabs button')].map((e) => e.textContent),
        dots: card.querySelectorAll('.dots i').length,
        mark: card.querySelector('.page-mark')?.textContent ?? '',
        newer: card.querySelector('.present-newer')?.textContent ?? '',
        choices: [...card.querySelectorAll('.card-buttons button')].map((e) => e.textContent),
        field: !!card.querySelector('.present-ask .answer-field'),
        row: card.parentElement.querySelector(':scope > .tool .row-head')?.textContent ?? '',
        columns: card.querySelector('.pa-grid') ? getComputedStyle(card.querySelector('.pa-grid')).gridTemplateColumns.split(' ').length : 0,
    })));
    """

@MainActor
func presenting(folder: URL, pictures: URL?) async {
    await group("a present call is a card, wide: items side by side, labelled and captioned, its row folded under it") {
        let page = PresentingPage(folder: folder, layout: .wide, width: wideWidth, appearance: .darkAqua, zoom: 1)
        defer { page.close() }
        guard await page.load() else { return }
        guard let data = (await js(page.view, "(() => { \(cardsScript) })()") as? String)?.data(using: .utf8),
              let cards = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], cards.count == 3 else {
            check("the page says what its cards show", false)
            return
        }
        let (alone, older, asking) = (cards[0], cards[1], cards[2])
        check("one item alone has a column of its own and no label", alone["grid"] as? String == "pa-grid n1" && (alone["labels"] as? [String])?.isEmpty == true, "\(alone)")
        check("its row says what was presented", alone["row"] as? String == "Presented 1 picture · 1440×900, 212 KB", "\(alone["row"] ?? "")")
        check("three items are three equal columns, labelled A, B and C", older["columns"] as? Int == 3 && older["labels"] as? [String] == ["A", "B", "C"], "\(older)")
        check("the page is marked with its drawn size", older["mark"] as? String == "Page · 1280×900", "\(older["mark"] ?? "")")
        check("the older version says a newer one is below", older["newer"] as? String == "A newer version is below." && asking["newer"] as? String == "", "\(older["newer"] ?? "") / \(asking["newer"] ?? "")")
        check("and its row how the page drew", older["row"] as? String == "Presented 2 pictures and a page · the page loaded, no errors", "\(older["row"] ?? "")")
        check("the head names the presentation and the version", older["note"] as? String == "p2 · version 1" && asking["note"] as? String == "p2 · version 2 · waits for you", "\(older["note"] ?? "") / \(asking["note"] ?? "")")
        check("the question has its choices and the field for words", asking["choices"] as? [String] == ["Use A", "Use B", "Use C"] && asking["field"] as? Bool == true, "\(asking)")
        check("and its row says it waits", asking["row"] as? String == "Presented version 2 of p2 · waits for your answer", "\(asking["row"] ?? "")")
        check("no other card stands for the question", await js(page.view, "document.querySelectorAll('.card.question').length") as? Int == 0)
        check("the page asked for every picture it shows, once", page.asked.count == 7 && page.posted.filter { $0["type"] as? String == "presentedImage" }.count == 7, "asked \(page.asked.sorted())")

        if let pictures {
            await picture(of: page.view, width: wideWidth, to: pictures.appendingPathComponent("present-wide-dark.png"))
        }

        // Expand, a click on an item, a choice: each posts what the contract says, once.
        page.posted.removeAll()
        _ = await js(page.view, "document.querySelectorAll('.card.present')[2].querySelector('.expand').click()")
        _ = await js(page.view, "document.querySelectorAll('.card.present')[1].querySelectorAll('.pa-frame')[1].click()")
        _ = await js(page.view, "const b = document.querySelectorAll('.card.present')[2].querySelectorAll('.card-buttons button')[1]; b.click(); b.click(); true")
        _ = await until("the page posts them", { page.posted.count >= 3 })
        try? await Task.sleep(for: .milliseconds(300))
        let posts = page.posted.map { message in message.keys.sorted().map { "\($0)=\(message[$0]!)" }.joined(separator: " ") }
        check("Expand posts expand for the version's first item", posts.first == "item=0 presentation=p2 type=expand version=2", posts.joined(separator: "\n      "))
        check("a click on an item posts expand for it", posts.count > 1 && posts[1] == "item=1 presentation=p2 type=expand version=1", posts.joined(separator: "\n      "))
        check("a choice posts choose once, with the need and the choice's id", posts.count == 3 && posts[2] == "choice=2 need=q-present-1 type=choose", posts.joined(separator: "\n      "))
        let after = await js(page.view, "(() => { const c = document.querySelectorAll('.card.present')[2]; return [...c.querySelectorAll('.card-buttons button, .answer-field')].every((b) => b.disabled) && !c.querySelector('.card-note').textContent.includes('waits') })()") as? Bool
        check("and the card waits no more for a second answer", after == true)
    }

    if let pictures {
        let light = PresentingPage(folder: folder, layout: .wide, width: wideWidth, appearance: .aqua, zoom: 1)
        if await light.load() { await picture(of: light.view, width: wideWidth, to: pictures.appendingPathComponent("present-wide-light.png")) }
        light.close()
    }

    await group("at a phone's width, one item at a time with the labels as tabs, and nothing reaches past the page's edge") {
        let page = PresentingPage(folder: folder, layout: .phone, width: phoneWidth, appearance: .darkAqua, zoom: 1)
        defer { page.close() }
        guard await page.load() else { return }
        guard let data = (await js(page.view, "(() => { \(cardsScript) })()") as? String)?.data(using: .utf8),
              let cards = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], cards.count == 3 else {
            check("the page says what its cards show", false)
            return
        }
        check("one item alone is drawn as it is wide", cards[0]["grid"] as? String == "pa-grid n1" && (cards[0]["tabs"] as? [String])?.isEmpty == true, "\(cards[0])")
        check("several are one at a time, with the labels as tabs and a dot each", cards[2]["tabs"] as? [String] == ["A", "B", "C"] && cards[2]["frames"] as? Int == 1 && cards[2]["dots"] as? Int == 3, "\(cards[2])")
        if let fit = await pageJSON(page.view, overflowScript) {
            check("the page does not scroll sideways", (fit["scrollWidth"] as? Int ?? 0) <= (fit["width"] as? Int ?? 0), "\(fit)")
            let out = fit["out"] as? [String] ?? []
            check("nothing reaches past its edge", out.isEmpty, out.joined(separator: "\n      "))
        }
        let small = await pageJSON(page.view, "return JSON.stringify({ small: JSON.parse((() => { \(smallButtonsScript) })()) })")?["small"] as? [String] ?? ["(no answer)"]
        check("every button shown is at least 32 points either way", small.isEmpty, small.joined(separator: "\n      "))
        if let pictures { await picture(of: page.view, width: phoneWidth, to: pictures.appendingPathComponent("present-narrow-dark.png")) }
        // A tab shows its item, which is asked for as it comes.
        _ = await js(page.view, "document.querySelectorAll('.card.present')[2].querySelectorAll('.pa-tabs button')[2].click()")
        let shown = await until("the third tab shows C", {
            await js(page.view, "(() => { const c = document.querySelectorAll('.card.present')[2]; return c.querySelector('.pa-label')?.textContent === 'C' && c.querySelector('.pa-frame').classList.contains('ready') })()") as? Bool == true
        })
        check("a tab shows its item", shown)
    }

    if let pictures {
        let light = PresentingPage(folder: folder, layout: .phone, width: phoneWidth, appearance: .aqua, zoom: 1)
        if await light.load() { await picture(of: light.view, width: phoneWidth, to: pictures.appendingPathComponent("present-narrow-light.png")) }
        light.close()
        // The page has no text size of its own; WebKit's page zoom at 1.35, the ratio of iOS's largest text size
        // before the accessibility sizes to its default (23 to 17 points), stands in for it.
        let large = PresentingPage(folder: folder, layout: .phone, width: phoneWidth, appearance: .darkAqua, zoom: 1.35)
        if await large.load() {
            if let fit = await pageJSON(large.view, overflowScript) {
                check("at the larger text size too, nothing reaches past the page's edge", (fit["out"] as? [String] ?? []).isEmpty && (fit["scrollWidth"] as? Int ?? 0) <= (fit["width"] as? Int ?? 0), "\(fit)")
            }
            await picture(of: large.view, width: phoneWidth, to: pictures.appendingPathComponent("present-narrow-largest.png"))
        }
        large.close()
        let wideLarge = PresentingPage(folder: folder, layout: .wide, width: wideWidth, appearance: .darkAqua, zoom: 1.35)
        if await wideLarge.load() { await picture(of: wideLarge.view, width: wideWidth, to: pictures.appendingPathComponent("present-wide-largest.png")) }
        wideLarge.close()
    }
}
