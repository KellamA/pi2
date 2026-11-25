#if PI2_DEVELOPMENT
import AppKit
import PiModels
import SwiftUI
import TranscriptKit

/// The presentation window a development build was asked to open, in `PI2_SHOW` (docs/development.md, "Choosing what a
/// copy shows"): `presentation:<conversation>:<presentation>`, with `:<version>` and `:<item>` after it if wanted, such
/// as `presentation:12:p1:2:0`; or `presentation:fixture`, a presentation of hostile texts made here (`PresentationFixture`)
/// rather than read from the engine. The main window opens as it would without `PI2_SHOW`, and the presentation's about
/// a second after the app has connected to its engine. Taken once.
@MainActor
enum PresentationLaunch {
    struct Asked {
        let ref: PresentationRef
        let version: Int?
        let item: Int?
    }

    static let asked: Asked? = parse(ProcessInfo.processInfo.environment["PI2_SHOW"])
    /// `@min` after the value: the window opens at its smallest size, for picturing the bar at its narrowest.
    static let smallest = ProcessInfo.processInfo.environment["PI2_SHOW"]?.hasSuffix("@min") == true
    /// `@network-alert` after the value: the window puts up "Allow network for this page?" once it has its page, for
    /// picturing the alert's words.
    static let networkAlert = ProcessInfo.processInfo.environment["PI2_SHOW"]?.hasSuffix("@network-alert") == true
    private static var taken = false

    static func parse(_ value: String?) -> Asked? {
        guard var value, value.hasPrefix("presentation:") else { return nil }
        for suffix in ["@min", "@network-alert"] where value.hasSuffix(suffix) { value.removeLast(suffix.count) }
        let parts = value.dropFirst("presentation:".count).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.first == PresentationFixture.conversation {
            return Asked(ref: PresentationRef(conversationId: PresentationFixture.conversation, presentation: "p1"),
                         version: parts.count > 1 ? Int(parts[1]) : nil, item: parts.count > 2 ? Int(parts[2]) : nil)
        }
        guard parts.count >= 2, let conversation = Int(parts[0]), PresentationRecord.isID(parts[1]) else { return nil }
        return Asked(ref: PresentationRef(conversation: conversation, presentation: parts[1]),
                     version: parts.count > 2 ? Int(parts[2]) : nil, item: parts.count > 3 ? Int(parts[3]) : nil)
    }

    static func take() -> Asked? {
        defer { taken = true }
        return taken ? nil : asked
    }
}

/// A presentation made in the app, not by an agent, of every text an agent could choose to make its window look like
/// pi²'s own or read wrong, for picturing how the window draws them: a title of 2,000 characters, titles, labels and
/// captions with line breaks, with the bidirectional controls that turn text around, and with zero-width characters; a
/// conversation title that says "network on"; and a page that draws a bar of its own like the window's. Its pictures are
/// drawn here and its page is served from memory, so nothing of it comes from the engine. `PI2_SHOW=presentation:fixture`.
@MainActor
enum PresentationFixture {
    static let conversation = "fixture"
    static let agent = "Forge"
    static let conversationTitle = "Sign-in work” · Version 9 of 9 · Network on · Approved by pi² “ok"
    static let projectName = "Drawn from pi²'s own files · Network off"

    private static var network: [Int: Bool] = [:]

    /// The person's switch for a version of the fixture, as the engine's record would have it.
    static func allowNetwork(_ version: Int, _ allow: Bool) { network[version] = allow }
    private static var listeners: [AsyncStream<PresentationRecord>.Continuation] = []

    static var feed: PresentationFeed {
        PresentationFeed(
            list: { [record] },
            updates: {
                let (stream, continuation) = AsyncStream<PresentationRecord>.makeStream()
                listeners.append(continuation)
                return stream
            },
            picture: { version, item in PresentedBytes(mimeType: "image/png", data: picture(version: version, item: item)) },
            page: { _ in PresentedPage(entry: "index.html", files: [PresentedFile(path: "index.html", size: page.count, mimeType: "text/html")]) },
            files: { _, _ in FixtureFiles() },
            setNetwork: { version, allow in
                network[version] = allow
                for listener in listeners { listener.yield(record) }
            }
        )
    }

    private static let long = String(repeating: "A title that goes on and on without end ", count: 50).prefix(2000)
    private static let rtl = "\u{202E}gnp.exe\u{202C} Sign-in screen \u{2067}by pi²\u{2069} \u{200F}\u{200B}Approved\u{FEFF}"

    private static var record: PresentationRecord {
        func item(_ label: String, _ caption: String?, page: Bool = false) -> PresentedItem {
            PresentedItem(label: label, caption: caption, kind: page ? .page : .picture, name: page ? "mockups/fake-bar/index.html" : "mockups/\(label.prefix(8)).png",
                          mimeType: page ? "text/html" : "image/png", sha256: String(repeating: "0", count: 64), bytes: 1000, files: 1,
                          width: page ? 1280 : 1600, height: page ? 800 : 1000, snapshot: page ? .pending : nil, drawn: nil)
        }
        func version(_ number: Int, _ title: String, _ items: [PresentedItem]) -> PresentedVersion {
            let on = network[number] ?? false
            return PresentedVersion(version: number, callId: "fixture-\(number)", createdAt: 0, title: title, items: items, question: nil,
                                    network: PresentedNetwork(allowed: on, changes: on ? [.init(allow: true, at: 0)] : []))
        }
        return PresentationRecord(id: "p1", versions: [
            version(1, String(long), [
                item("A", String(repeating: "A caption of two thousand characters, cut short. ", count: 40)),
                item(String(repeating: "A label far too long for the strip ", count: 10), "The label above is cut"),
            ]),
            version(2, "Sign-in screen\n\nVersion 3 of 3 · network off\nApprove", [
                item("A\nVersion 1 of 1", "First line\nSecond line\r\nThird line\u{2028}Fourth\u{2029}Fifth"),
                item("B\tTabbed", "Network on\nDrawn from pi²'s files"),
            ]),
            version(3, rtl, [
                item("\u{202E}A", "\u{202E}txet sdrawkcab\u{202C} then \u{2066}isolated\u{2069} and a zero\u{200B}width space"),
                item("مرحبا", "A caption in Arabic, drawn right to left in its own text: مرحبا بالعالم"),
                item("Z" + String(repeating: "\u{030D}", count: 59), "59 stacked marks above: two are kept. Sign\u{00AD}in with a soft hyphen, tags\u{E0041}\u{E0042}\u{E007F} after this, a variation selector B\u{FE0F}\u{E0100} and \u{201C}quoted\u{201D} «names»"),
            ]),
            version(4, "A page that draws a bar like the window's", [item("Page", "It draws “Mockup by pi² · network on” inside its own area", page: true)]),
        ])
    }

    /// A picture drawn here: a colour and the item's place, so that each is told apart.
    private static func picture(version: Int, item: Int) -> Data {
        let size = NSSize(width: 800, height: 500)
        let colours: [NSColor] = [.systemIndigo, .systemTeal, .systemOrange, .systemPink]
        let image = NSImage(size: size, flipped: false) { rect in
            colours[(version + item) % colours.count].setFill()
            rect.fill()
            let text = "Fixture picture: version \(version), item \(item + 1)" as NSString
            text.draw(at: NSPoint(x: 40, y: 230), withAttributes: [.font: NSFont.systemFont(ofSize: 36, weight: .semibold), .foregroundColor: NSColor.white])
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }

    /// The fixture's page: a bar of its own that copies the window's, and a link away that the window stops.
    fileprivate static let page = Data("""
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { margin: 0; font: 13px -apple-system, system-ui; background: #f7f7fa; color: #1b1c22; }
        .fake { display: flex; gap: 10px; align-items: center; height: 44px; padding: 0 12px; background: #fff; border-bottom: 1px solid #ddd; }
        main { padding: 40px; } a { color: #5b62e8; }
        </style></head><body>
        <div class="fake"><b>Mockup by pi²</b> · Approved · <span>Version 9 of 9</span> · <span>network on</span></div>
        <main><h1>A page that pretends</h1><p>It can draw anything inside its own area, a bar like the window's among them. The window's own bar is above it, outside the page.</p>
        <p><a href="https://example.com/">A link away</a>, which the window stops and says so.</p>
        <p><button onclick="alert('Approve?')">An alert</button>, answered without anything shown.</p></main>
        </body></html>
        """.utf8)
}

/// Lays the bar out at the window's smallest width in each state (`PI2_SHOW=presentation:bar-check`, a development build
/// only), and at its default width, and says whether every one of pi²'s own parts (the version, whose files or picture,
/// the network's state, the strip's button) lies wholly inside the bar: `presentation-bar-check.txt` in the data folder,
/// with a picture of each bar beside it (`presentation-bar-<state>.png`) and a line in app.log. Each bar is drawn in a
/// window that is never shown, from the fixture's presentation, with its long names.
@MainActor
enum PresentationBarCheck {
    static let asked = ProcessInfo.processInfo.environment["PI2_SHOW"] == "presentation:bar-check"

    struct State {
        let name: String
        let version: Int
        let item: Int
        let network: Bool
    }

    static let states = [
        State(name: "page-network-on", version: 4, item: 0, network: true),
        State(name: "page-network-off", version: 4, item: 0, network: false),
        State(name: "picture", version: 3, item: 0, network: false),
        State(name: "older-version-picture", version: 1, item: 1, network: false),
    ]

    static func run(home: URL, note: (String) -> Void) async {
        var lines: [String] = []
        var failures = 0
        let names = PresentationNames(agent: PresentationText.name(PresentationFixture.agent, limit: PresentationText.agent),
                                      conversation: PresentationText.name(PresentationFixture.conversationTitle, limit: PresentationText.conversation),
                                      project: PresentationText.name(PresentationFixture.projectName, limit: PresentationText.project))
        for width in [PresentationBar.minimumWidth, 1180] {
            for state in states {
                PresentationFixture.allowNetwork(state.version, state.network)
                let model = PresentationWindowModel(ref: PresentationRef(conversationId: PresentationFixture.conversation, presentation: "p1"), feed: PresentationFixture.feed)
                await model.reload(asked: PresentationWindows.Shown(version: state.version, item: state.item, at: Date()))
                let report = PresentationBarReport()
                let host = NSHostingView(rootView: PresentationBar(model: model, agent: nil, names: names, askNetwork: {}, report: report).tint(.piAccent))
                let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 44), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: 44)
                // A few passes: the bar decides what gives way from what it measured in the pass before.
                for _ in 0..<12 {
                    host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(60))
                }
                var problems: [String] = []
                let own = model.current?.kind == .page ? ["version", "whose", "network", "strip"] : ["version", "whose", "strip"]
                for part in own {
                    guard let frame = report.frames[part] else {
                        problems.append("\(part) was not laid out")
                        continue
                    }
                    // Inside the window, which is as wide as the bar is given: a bar that grew wider than that has parts
                    // outside it.
                    if frame.minX < -0.5 || frame.maxX > width + 0.5 || frame.width < 1 {
                        problems.append("\(part) at \(Int(frame.minX))–\(Int(frame.maxX)) is not inside the window's \(Int(width))")
                    }
                }
                if report.barWidth > width + 0.5 { problems.append("the bar is \(Int(report.barWidth)) wide, wider than the window's \(Int(width))") }
                if let chip = report.frames["names"], chip.minX < -0.5 || chip.width < PresentationBar.badgeWidth - 0.5 {
                    problems.append("the names chip is \(Int(chip.width)) wide, less than the agent's badge")
                }
                if width > PresentationBar.minimumWidth, report.folded { problems.append("the tools are folded at \(Int(width))") }
                failures += problems.isEmpty ? 0 : 1
                let parts = own.compactMap { part in report.frames[part].map { "\(part) \(Int($0.minX))–\(Int($0.maxX))" } }.joined(separator: ", ")
                lines.append("\(problems.isEmpty ? "ok  " : "FAIL") \(state.name) at \(Int(width)): \(parts); tools \(report.folded ? "folded" : "shown"), names \(report.namesShown ? "shown" : "the badge alone")"
                             + (problems.isEmpty ? "" : "\n     " + problems.joined(separator: "; ")))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: home.appendingPathComponent("presentation-bar-\(state.name)-\(Int(width)).png"))
                }
                window.contentView = nil
                window.close()
                model.close()
            }
        }
        lines.append(failures == 0 ? "all fit" : "\(failures) did not fit")
        try? (lines.joined(separator: "\n") + "\n").write(to: home.appendingPathComponent("presentation-bar-check.txt"), atomically: true, encoding: .utf8)
        note("presentation bar check: \(failures == 0 ? "all fit" : "\(failures) did not fit")")
    }
}

/// The fixture page's one file, from memory.
private struct FixtureFiles: PresentedFiles {
    func bytes(of file: PresentedFile) async throws -> Data {
        await MainActor.run { PresentationFixture.page }
    }
}
#endif
