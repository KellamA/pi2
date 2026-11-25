// The page drawn at a phone's width (#671, docs/iphone.md section 8): marked as the phone's view marks it
// (`TranscriptLayout.phone`), 390 points wide, as an iPhone of iOS 18 is in portrait, with a conversation that has
// text, a table, code, tool rows, an approval card and a picture. Checks that nothing reaches past the page's edge but
// inside what scrolls sideways of itself (a table, code, a command), that the controls a pointer would show by hovering
// are shown, and that the buttons are large enough for a finger. With `--pictures <folder>`, writes the page as drawn
// to `narrow-390.png` there, and the same conversation as the Mac draws it in its narrowest pane to `mac-319.png`.

import AppKit
import TranscriptKit
import WebKit

/// The width of an iPhone 16 or 15 in portrait, in points; the narrowest iPhone iOS 18 runs on is 375.
let phoneWidth: CGFloat = 390
/// The narrowest a pane of the Mac's draws the page (`HubLayout.minimumWidth`, PaneKit).
let macNarrowest: CGFloat = 319

/// A picture as the engine gives one: a PNG, drawn here.
func pictureData() -> String {
    let width = 800, height = 500
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.33, green: 0.36, blue: 0.91, alpha: 1), CGColor(red: 0.95, green: 0.55, blue: 0.35, alpha: 1)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
    for (index, plan) in [0.45, 0.7, 0.9].enumerated() {
        context.fill(CGRect(x: 120 + index * 210, y: 80, width: 140, height: Int(320 * plan)))
    }
    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.base64EncodedString()
}

/// The conversation: a message with a picture; an answer with a table and code, which ran a command and read a file;
/// and an answer whose command waits for the person's approval.
func narrowConversation() -> String {
    let command = "npm test -- --test-name-pattern 'limits are kept per project and per window' engine/test/limits.ts"
    let answer = """
        The three plans differ mostly in how they count a window. Here is each, with what it costs a busy week:

        | Plan | Window | Counted by | A busy week |
        |---|---|---|---|
        | Pro | 5 hours | messages, weighted by model | about 40% of the weekly limit |
        | Max 5× | 5 hours | the same, five times over | about 9% |
        | Max 20× | 5 hours and a week | tokens, with a weekly ceiling of its own | under 3%, unless the week runs long |

        The check that keeps them apart is short:

        ```ts
        export function remaining(plan: Plan, used: Usage, now = Date.now()): { window: number; week: number } {
        \treturn { window: plan.window.limit - used.since(now - plan.window.length), week: plan.week ? plan.week.limit - used.since(now - WEEK) : Infinity };
        }
        ```

        I ran the tests for it and read the file once more, to be sure nothing else reads `used.since`.
        """
    let message: [String: Any] = [
        "reset": true,
        "names": ["conversationId": 7, "agentName": "Atlas", "mcp": [:], "agents": [], "apps": [:], "folder": true],
        "items": [
            ["id": 1, "kind": "user", "text": "Compare the three plans in this picture, and show me the check that keeps their limits apart.", "images": 1,
             "attachments": [["kind": "image", "name": "plans.png"]], "timestamp": 0],
            ["id": 2, "kind": "assistant", "text": answer, "timestamp": 0, "toolCalls": [
                ["callId": "c1", "name": "bash", "arguments": ["command": command]],
                ["callId": "c2", "name": "read", "arguments": ["path": "engine/src/limits.ts"]],
            ]],
            ["id": 3, "kind": "tool", "callId": "c1", "name": "bash", "isError": false, "timestamp": 0,
             "text": "▶ limits\n  ✔ limits are kept per project and per window (41.2ms)\n▶ limits (43.9ms)\nℹ tests 1\nℹ pass 1\nℹ fail 0\n", "details": ["exitCode": 0]],
            ["id": 4, "kind": "tool", "callId": "c2", "name": "read", "isError": false, "timestamp": 0, "text": "export function remaining(plan: Plan, used: Usage) {\n…\n}\n"],
            ["id": 5, "kind": "assistant", "text": "Both pass. I will commit the change on this branch.", "timestamp": 0, "toolCalls": [
                ["callId": "c3", "name": "bash", "arguments": ["command": "git commit -am 'Keep each plan's window apart in remaining()' && git push origin pi2/671-iphone"]],
            ]],
        ],
        "live": ["busy": true, "tools": []],
        "inbox": [
            ["id": "approval-1", "callId": "c3", "kind": "approval", "tool": "bash", "agentName": "Atlas", "conversationId": 7,
             "arguments": ["command": "git commit -am 'Keep each plan's window apart in remaining()' && git push origin pi2/671-iphone"],
             "rule": ["words": ["git", "commit"]]],
        ],
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
}

/// What reaches past the page's edges, outside anything that scrolls sideways or clips of itself; and the page's own
/// width (the viewport's, `viewport`, and what is left beside a scroll bar that takes room, `width`: a Mac set to show
/// scroll bars always, as CI's is, takes 17 points of 390; a phone's never does) and scrolling width.
let overflowScript = """
    const width = document.documentElement.clientWidth;
    const viewport = window.innerWidth;
    const clipped = (e) => {
        for (let p = e.parentElement; p && p !== document.body; p = p.parentElement) {
            const x = getComputedStyle(p).overflowX;
            if (x === "auto" || x === "scroll" || x === "hidden" || x === "clip") return true;
        }
        return false;
    };
    const out = [];
    for (const e of document.querySelectorAll("#transcript *")) {
        const r = e.getBoundingClientRect();
        if (r.width === 0 || r.height === 0 || getComputedStyle(e).visibility === "hidden") continue;
        if ((r.right > width + 0.5 || r.left < -0.5) && !clipped(e)) out.push(`${e.tagName.toLowerCase()}.${[...e.classList].join(".")} ${Math.round(r.left)}…${Math.round(r.right)}`);
    }
    return JSON.stringify({ width, viewport, scrollWidth: document.documentElement.scrollWidth, out: out.slice(0, 12) });
    """

/// Buttons in the transcript a finger would struggle to hit: shown, and less than 32 points either way. A button in a
/// tool's row (its chevron) is hit by the whole row, which opens it too.
let smallButtonsScript = """
    const small = [];
    for (const b of document.querySelectorAll("#transcript button")) {
        const r = (b.closest(".row-head") ?? b).getBoundingClientRect();
        if (r.width === 0 || r.height === 0 || Number(getComputedStyle(b).opacity) === 0) continue;
        if (r.width < 32 || r.height < 32) small.push(`${[...b.classList].join(".")} “${b.getAttribute("aria-label") || b.textContent.trim()}” ${Math.round(r.width)}×${Math.round(r.height)}`);
    }
    return JSON.stringify(small.slice(0, 12));
    """

/// The hover actions under each message, and whether they show without a pointer over them.
let actionsScript = """
    const bars = [...document.querySelectorAll("#transcript .actions")];
    return JSON.stringify({ bars: bars.length, hidden: bars.filter((bar) => Number(getComputedStyle(bar).opacity) === 0).length });
    """

@MainActor
func pageJSON(_ view: WKWebView, _ body: String) async -> [String: Any]? {
    guard let text = (try? await view.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)) as? String,
          let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// A page in a window of its own that never comes on screen, `width` points wide, showing the conversation with its
/// picture loaded, in the appearance given.
@MainActor
func drawn(_ folder: URL, layout: TranscriptLayout, width: CGFloat, picture: String, appearance: NSAppearance.Name = .darkAqua) async -> (NSWindow, TranscriptWebKitView)? {
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 844), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    let view = TranscriptWebKitView(folder: folder, layout: layout)
    view.frame = NSRect(x: 0, y: 0, width: width, height: 844)
    window.contentView = view
    guard await until("the page at \(Int(width)) points says it is ready", { view.isReady }) else { return nil }
    await send(view, narrowConversation())
    guard await until("it shows the conversation", { await shown(view).contains("Both pass") }) else { return nil }
    // The page asks for a picture as it scrolls into view, which a window never on screen may not tell it; the picture
    // is sent as the app sends it once asked.
    let reply: [String: Any] = ["image": ["entry": 1, "index": 0, "mimeType": "image/png", "data": picture]]
    await send(view, String(data: try! JSONSerialization.data(withJSONObject: reply), encoding: .utf8)!)
    guard await until("and its picture", { await js(view, "[...document.querySelectorAll('.thumb img')].some((i) => i.complete && i.naturalWidth > 0)") as? Bool == true })
    else { return nil }
    return (window, view)
}

/// The whole page as drawn, its full height, to a PNG.
@MainActor
func picture(of view: TranscriptWebKitView, width: CGFloat, to file: URL) async {
    // In CSS pixels, which a page zoomed in (Presenting.swift's larger text) draws larger.
    let height = (await js(view, "document.documentElement.scrollHeight") as? Double).map { ceil(CGFloat($0) * view.pageZoom) } ?? 844
    view.frame = NSRect(x: 0, y: 0, width: width, height: height)
    view.window?.setContentSize(NSSize(width: width, height: height))
    // Laid out again at the new height, and drawn.
    _ = try? await view.callAsyncJavaScript(TranscriptMessages.nextFrame, arguments: [:], in: nil, contentWorld: .page)
    let configuration = WKSnapshotConfiguration()
    configuration.rect = NSRect(x: 0, y: 0, width: width, height: height)
    guard let image = try? await view.takeSnapshot(configuration: configuration),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
        check("the page is pictured", false, file.path)
        return
    }
    do {
        try png.write(to: file)
        print("info  pictured \(file.lastPathComponent): \(cgImage.width)×\(cgImage.height) pixels")
    } catch {
        check("the picture is written", false, "\(file.path): \(error.localizedDescription)")
    }
}

@MainActor
func narrow(folder: URL, pictures: URL?) async {
    let data = pictureData()
    await group("at a phone's width, 390 points, nothing reaches past the page's edge, hover's controls show, and a finger can hit the buttons") {
        guard let (window, view) = await drawn(folder, layout: .phone, width: phoneWidth, picture: data) else { return }
        defer { view.close(); window.close() }
        check("the page is marked for a phone", await marks(view) == "narrow touch")
        if let fit = await pageJSON(view, overflowScript) {
            let width = fit["width"] as? Int ?? 0, viewport = fit["viewport"] as? Int ?? 0, scrollWidth = fit["scrollWidth"] as? Int ?? 0
            check("the page is \(Int(phoneWidth)) points wide", viewport == Int(phoneWidth), "\(viewport)")
            check("and does not scroll sideways", scrollWidth <= width, "scrolls to \(scrollWidth)")
            let out = fit["out"] as? [String] ?? []
            check("nothing reaches past its edge but inside what scrolls of itself", out.isEmpty, out.joined(separator: "\n      "))
        } else {
            check("the page answers what reaches past its edge", false)
        }
        let small = await pageJSON(view, "return JSON.stringify({ small: JSON.parse((() => { \(smallButtonsScript) })()) })")?["small"] as? [String] ?? ["(no answer)"]
        check("every button shown is at least 32 points either way", small.isEmpty, small.joined(separator: "\n      "))
        let actions = await pageJSON(view, actionsScript)
        check("the controls under each message show without a pointer", (actions?["bars"] as? Int ?? 0) > 0 && actions?["hidden"] as? Int == 0, "\(actions ?? [:])")
        check("the approval card is there, with its buttons", await js(view, "document.querySelectorAll('.card.approval .card-buttons button').length") as? Int ?? 0 >= 3)
        check("so is the table", await js(view, "document.querySelectorAll('#transcript table').length") as? Int == 1)
        if let pictures { await picture(of: view, width: phoneWidth, to: pictures.appendingPathComponent("narrow-390-dark.png")) }
    }

    if let pictures, let (window, view) = await drawn(folder, layout: .phone, width: phoneWidth, picture: data, appearance: .aqua) {
        await picture(of: view, width: phoneWidth, to: pictures.appendingPathComponent("narrow-390-light.png"))
        view.close()
        window.close()
    }

    await group("the Mac's narrowest pane, 319 points, is not drawn with the phone's rules") {
        guard let (window, view) = await drawn(folder, layout: .wide, width: macNarrowest, picture: data) else { return }
        defer { view.close(); window.close() }
        check("the page has no mark", await marks(view) == "")
        // The viewport the phone's page asks for (index.html) is not the Mac's: the page is as wide as its pane.
        let width = await js(view, "window.innerWidth") as? Int
        check("the page is as wide as the pane, whatever the page asks of a phone's viewport", width == Int(macNarrowest), "\(width ?? 0)")
        let actions = await pageJSON(view, actionsScript)
        check("the controls under each message wait for the pointer, as before", (actions?["bars"] as? Int ?? 0) > 0 && actions?["hidden"] as? Int == actions?["bars"] as? Int, "\(actions ?? [:])")
        if let pictures { await picture(of: view, width: macNarrowest, to: pictures.appendingPathComponent("mac-319.png")) }
    }
}
