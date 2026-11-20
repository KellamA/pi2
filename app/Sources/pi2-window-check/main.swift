// Checks how a window's size follows its SwiftUI content (#400, #542).
//
// The app crashed in the background when the main window's hosting view, working out its content's smallest size
// from inside an Update Constraints pass, found its size changed and asked for another pass, again and again until
// AppKit gave up. WindowKit's `windowMinimum` gives that view a fixed base to measure instead of the content, and
// `columnGivesWay` keeps a split view's column from asking for more height than the window has. This makes windows as
// the app's are (a hosting view with the `.minSize` option SwiftUI gives a scene's window, a toolbar, the sidebar and
// detail of a split view), in windows of its own that never come on screen, and checks:
//
// - that the window's smallest size is the one SwiftUI worked out before, so the window sizes as it did;
// - that it is worked out without measuring the content, which the plain frame the app had did, every time;
// - that very long unbroken text (a tool's error of 5,000 characters on one line) in each way the app shows text from
//   outside, rows and request cards that come and go, and a sidebar shown and hidden, change neither the smallest
//   size nor the size of the window, which sits at its smallest the whole time;
// - that a stack of requests cannot make the split view taller than the window, as it did before, and four or twelve
//   requests leave the transcript, the message field and Stop visible at the smallest size (#489);
// - that the watch which names a view whose size does not settle reports one that changes size again and again in one
//   turn of the run loop, once, and stays quiet for a window resized a step a turn as a person does;
// - that the watch on the app's scene body (#436) reports a body that reads something that then changes, once, and
//   stays quiet for one that only passes it on to a view of its own; and that SwiftUI still sees what a watched body
//   reads, and draws it again, as it would without the watch.
//
//   cd app && swift build --product pi2-window-check && .build/debug/pi2-window-check
//
// It also orders both real indicator panels off screen and exercises short and long names with and without Show,
// across turns and in a single burst. The hosting view stays put, supplies no window size constraints, and the
// pill resizes only when asked, stays on one line, and fits the screen. The small-panel watch names each pill.
// The original exception did not reproduce here (#542).
// Exits 1 if anything failed.

import AppKit
import SwiftUI
import WindowKit

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

/// Lets the run loop turn a few times, so that what SwiftUI put off to the next turn is done.
@MainActor
func settle() async {
    for _ in 0..<4 {
        try? await Task.sleep(for: .milliseconds(30))
    }
}

/// A tool's error as #372 had them: git's progress on one line, about 5,000 characters with no line break.
let longLine = (1...180).map { "Updating files: \($0)% (\($0)/275)" }.joined()
/// The same without a space to break at.
let unbroken = String(repeating: "x", count: 5000)

/// What the content shows, changed by the checks as the engine's events change the app's.
@MainActor @Observable
final class Feed {
    var errors: [String] = []
    var cards: [String] = []
    var rows: [String] = ["Inbox", "Activity", "Usage", "Archive"]
    var sidebar = NavigationSplitViewVisibility.all
    var showLastRequest = false
    /// The fold of a project's hub, when the detail shows one (#471), and whether it said it was too narrow for both panels.
    var hubFold = HubFold.both
    var hubNarrow = false
    @ObservationIgnored var frames: [String: CGRect] = [:]
}

/// How many times each body was worked out, by name.
@MainActor
final class Runs {
    var counts: [String: Int] = [:]
    func ran(_ name: String) { counts[name, default: 0] += 1 }
    subscript(_ name: String) -> Int { counts[name] ?? 0 }
}

/// What a watch reported.
@MainActor
final class Lines {
    var lines: [String] = []
}

/// What the app's scene body once read: the inbox, here a count.
@MainActor @Observable
final class Waiting {
    var count = 0
}

/// A body under a `BodyWatch`, as the app's scene body is: it reads the count itself, or only passes it on.
struct Watched: View {
    let waiting: Waiting
    let watch: BodyWatch
    let reads: Bool
    let runs: Runs
    let report: @MainActor @Sendable (String) -> Void

    var body: some View {
        watch.watch(report: report) {
            runs.ran("outer")
            return VStack {
                if reads { Text("\(waiting.count) waiting") }
                Shown(waiting: waiting, runs: runs)
            }
        }
    }
}

/// A view of its own that reads the count, as the menu bar item's label does.
struct Shown: View {
    let waiting: Waiting
    let runs: Runs

    var body: some View {
        let _ = runs.ran("inner")
        Text("\(waiting.count)")
    }
}

/// Every size the content was asked for, by whatever holds it.
@MainActor
final class Asked {
    var sizes: [ProposedViewSize] = []
}

/// Passes its one child through unchanged, noting each size it is asked for.
struct Measured: Layout {
    let asked: Asked

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        MainActor.assumeIsolated { asked.sizes.append(proposal) }
        return subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Each way the app shows text from outside it: a banner of three lines, a line that wraps in full, a label, a line
/// kept whole, and a card of a request, stacked above a message field, as the conversation shows them.
struct Detail: View {
    let feed: Feed

    var body: some View {
        VStack(spacing: 0) {
            Color.gray.opacity(0.2).frame(minHeight: 0, maxHeight: .infinity)
            ForEach(Array(feed.errors.enumerated()), id: \.offset) { index, error in
                switch index % 5 {
                case 0: Label(error, systemImage: "exclamationmark.triangle").lineLimit(3)
                case 1: Text(error).fixedSize(horizontal: false, vertical: true)
                case 2: Text(error)
                case 3: Text(error).lineLimit(1)
                default: HStack { Text(error).lineLimit(3); Spacer(); Button("Continue") {} }
                }
            }
            ForEach(Array(feed.cards.enumerated()), id: \.offset) { _, card in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Forge wants to run a command").font(.headline)
                    Text(card).font(.system(size: 12, design: .monospaced)).lineLimit(4)
                    HStack { Button("Allow Once") {}; Button("Deny") {} }
                }
                .padding(12)
            }
            Text("Message Atlas…").frame(maxWidth: .infinity, minHeight: 80)
        }
        .navigationTitle(feed.errors.last ?? "Long lines")
        .navigationSubtitle(feed.errors.isEmpty ? "Atlas" : "Atlas · sub-chat of “\(feed.errors.last!)”")
        .toolbar { ToolbarItem { Button("Model") {} } }
    }
}

/// Uses the conversation's bounded stack with stand-ins for its transcript, cards and composer.
struct RequestDetail: View {
    struct Request: Identifiable { let id: Int }

    let feed: Feed
    @State private var availableHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                probe("transcript") { Color.gray.frame(minHeight: 0, maxHeight: .infinity) }
                ScrollViewReader { proxy in
                    probe("requests") {
                        ConversationRequests(feed.cards.indices.map(Request.init), availableHeight: availableHeight) { request in
                            probe("card-\(request.id)") {
                                Text(feed.cards[request.id]).frame(maxWidth: .infinity).frame(height: 146)
                            }
                            .padding(.top, 8)
                        }
                    }
                    .onChange(of: feed.showLastRequest) {
                        if feed.showLastRequest { proxy.scrollTo(feed.cards.count - 1, anchor: .bottom) }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
            VStack(spacing: 0) {
                probe("field") { TextField("Message Atlas…", text: .constant("")).padding(12) }
                probe("stop") { Button("Stop") {}.padding(12) }
            }
            .layoutPriority(1)
        }
        .navigationTitle("Waiting on requests")
        .toolbar { ToolbarItem { Button("Model") {} } }
    }

    private func probe<V: View>(_ name: String, @ViewBuilder view: () -> V) -> some View {
        view().onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { feed.frames[name] = $0 }
    }
}

/// A project's hub as the app shows it (#471): a bar, then `HubPanels` with stand-ins for the conversation with the
/// orchestrator, the board and the strip, each holding long lines from outside and a field to type in.
struct HubDetail: View {
    let feed: Feed

    var body: some View {
        VStack(spacing: 0) {
            probe("bar") { Text("Demo project · \(longLine)").lineLimit(1).frame(maxWidth: .infinity, minHeight: 50) }
            HubPanels(fold: feed.hubFold, narrow: Binding(get: { feed.hubNarrow }, set: { feed.hubNarrow = $0 })) {
                probe("conversation") {
                    VStack(spacing: 0) {
                        Color.gray.opacity(0.2).frame(minHeight: 0, maxHeight: .infinity)
                        Text(unbroken).lineLimit(3)
                        TextField("Message the orchestrator…", text: .constant("")).padding(12)
                    }
                }
            } board: {
                probe("board") {
                    VStack(spacing: 8) {
                        ScrollView(.horizontal) { HStack { ForEach(["Now", "Work", "Agents", "Rules", "Notes", "Branches", "Settings"], id: \.self) { Text($0) } } }
                        ScrollView { Text(longLine).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            } strip: {
                probe("strip") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("“\(unbroken)”").lineLimit(2)
                            TextField("Message the orchestrator…", text: .constant(""))
                        }
                        Button("Send") {}
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle("Demo project")
        .toolbar { ToolbarItem { Button("Model") {} } }
    }

    /// Notes where a part is while it is shown, and forgets it once it is folded away.
    private func probe<V: View>(_ name: String, @ViewBuilder view: () -> V) -> some View {
        view()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { feed.frames[name] = $0 }
            .onDisappear { feed.frames[name] = nil }
    }
}

struct Content: View {
    let feed: Feed
    let givesWay: Bool
    let boundedRequests: Bool
    var hub = false

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { feed.sidebar }, set: { feed.sidebar = $0 })) {
            List {
                ForEach(feed.rows, id: \.self) { Text($0).lineLimit(1) }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            if hub { HubDetail(feed: feed).columnGivesWay() }
            else if boundedRequests { RequestDetail(feed: feed).columnGivesWay() }
            else if givesWay { Detail(feed: feed).columnGivesWay() }
            else { Detail(feed: feed) }
        }
    }
}

/// The smallest size the app gives its main window's content.
let content = CGSize(width: 820, height: 480)

/// A window made as SwiftUI makes a scene's: titled, resizable, its content under a unified toolbar, hosted by a view
/// with the option to set the window's smallest size. `fixed` puts WindowKit's modifiers on the content, as the app
/// does; without them, the content has the plain frame the app had before.
@MainActor
final class Made {
    /// What the window's watch reported, kept apart so the content can be given it before the window is made.
    final class Reports {
        var lines: [String] = []
    }

    let feed = Feed()
    let asked = Asked()
    let window: NSWindow
    let host: NSView & HostingSizing
    private let reported = Reports()
    var reports: [String] { reported.lines }
    var resizes = 0
    private var observer: NSObjectProtocol?

    init(fixed: Bool, boundedRequests: Bool = false, hub: Bool = false) {
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1120, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "check")
        window.toolbarStyle = .unified
        window.title = "pi²"
        let reported = reported
        let feed = feed
        let measured = Measured(asked: asked) { Content(feed: feed, givesWay: fixed, boundedRequests: boundedRequests, hub: hub) }
        let host = fixed
            ? NSHostingView(rootView: AnyView(measured.windowMinimum(width: content.width, height: content.height) { reported.lines.append($0) }))
            : NSHostingView(rootView: AnyView(measured.frame(minWidth: content.width, minHeight: content.height)))
        self.host = host
        host.sizingOptions = [.minSize]
        window.contentView = host
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.resizes += 1 }
        }
    }

    /// Lays the window out as a turn of the display cycle would, then lets the run loop turn.
    func layOut() async {
        window.updateConstraintsIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        await settle()
        window.updateConstraintsIfNeeded()
        window.layoutIfNeeded()
    }

    /// The sizes the content was asked for that are no bigger than its smallest size, in either direction: measuring
    /// it for the window's smallest size. The window is always bigger than that when it is asked. Sizes it was shown
    /// at before the toolbar settled are bigger, and are left out.
    var measuredFor: [ProposedViewSize] {
        asked.sizes.filter { proposal in
            (proposal.width ?? 0) <= content.width + 0.5 || (proposal.height ?? 0) <= content.height + 0.5
        }
    }

    /// The tallest hosting view inside the window's own: the columns of the split view.
    var tallestColumn: CGFloat {
        func walk(_ view: NSView) -> CGFloat {
            view.subviews.reduce(view !== host && view is HostingSizing ? view.frame.height : 0) { max($0, walk($1)) }
        }
        return walk(host)
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        window.close()
    }
}

let app = NSApplication.shared
// No Dock icon, no menu bar, and never made active: the person's focus stays where it is.
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    await group("indicator panels keep one hosting view and size outside layout (#542)") { await indicatorCheck() }
    // The content as the app had it before: what to keep, and what to stop.
    let before = Made(fixed: false)
    await before.layOut()
    let swiftUIMinimum = before.window.contentMinSize
    await group("before WindowKit, the window's smallest size was worked out by measuring the content") {
        check("the hosting view sets the window's smallest size", before.host.sizingOptions.contains(.minSize), "options \(before.host.sizingOptions.rawValue)")
        check("it is the content's frame and the toolbar", swiftUIMinimum.width == content.width && swiftUIMinimum.height > content.height, "smallest \(swiftUIMinimum)")
        check("the content was measured for it", !before.measuredFor.isEmpty, "the content was only asked for \(before.asked.sizes)")
    }
    // A stack of requests at the window's smallest size made the split view taller than the window.
    before.window.setContentSize(swiftUIMinimum)
    before.feed.cards = Array(repeating: longLine, count: 6)
    await before.layOut()
    let overflowed = before.tallestColumn > before.host.frame.height + 0.5
    print(overflowed
        ? "ok    before WindowKit, six requests made a column \(Int(before.tallestColumn)) points tall in a window \(Int(before.host.frame.height)) tall"
        : "note  six requests no longer make a column taller than the window without WindowKit, so that check shows nothing here")
    before.close()

    let made = Made(fixed: true)
    await made.layOut()
    let window = made.window
    let fixed = window.contentMinSize

    await group("the window's smallest size is the same, and the content is not measured for it") {
        check("it is the same as SwiftUI worked out before", fixed == swiftUIMinimum, "now \(fixed), before \(swiftUIMinimum)")
        check("the content is never asked for a size as small as that", made.measuredFor.isEmpty, "asked for \(made.measuredFor)")
    }

    // The window at its smallest, where a content that asks for more has nowhere to go.
    window.setContentSize(fixed)
    await made.layOut()
    let smallest = window.frame
    made.resizes = 0

    await group("long lines from outside change neither the smallest size nor the window") {
        for (name, text) in [("a 5,000-character line", longLine), ("5,000 characters with no space", unbroken)] {
            for count in 1...5 {
                made.feed.errors.append(text)
                await made.layOut()
                check("\(name), \(count) shown: smallest size", window.contentMinSize == fixed, "smallest \(window.contentMinSize), fixed \(fixed)")
                check("\(name), \(count) shown: window", window.frame == smallest, "frame \(window.frame), was \(smallest)")
            }
            made.feed.errors.removeAll()
            await made.layOut()
        }
        check("the window was never resized", made.resizes == 0, "\(made.resizes) resizes")
    }

    await group("rows, requests and the sidebar coming and going in quick succession") {
        made.resizes = 0
        for round in 0..<6 {
            // Three sub-chats made and removed within a second or two, as the three failed `delegate` calls did.
            made.feed.rows += ["Tree \(round) a", "Tree \(round) b", "Tree \(round) c"]
            made.feed.cards = Array(repeating: longLine, count: 6)
            await made.layOut()
            check("round \(round + 1): the split view is no taller than the window", made.tallestColumn <= made.host.frame.height + 0.5, "a column is \(made.tallestColumn) tall in a window \(made.host.frame.height) tall")
            made.feed.rows.removeLast(3)
            made.feed.cards.removeAll()
            made.feed.errors = [longLine, unbroken, longLine]
            made.feed.sidebar = round.isMultiple(of: 2) ? .detailOnly : .all
            await made.layOut()
            check("round \(round + 1): smallest size", window.contentMinSize == fixed, "smallest \(window.contentMinSize), fixed \(fixed)")
            check("round \(round + 1): window", window.frame == smallest, "frame \(window.frame), was \(smallest)")
        }
        check("the window was never resized", made.resizes == 0, "\(made.resizes) resizes")
        check("nothing was reported as not settling", made.reports.isEmpty, made.reports.joined(separator: "\n      "))
    }
    made.close()

    await group("the composer stays in view with four or twelve requests at the smallest size") {
        let requests = Made(fixed: true, boundedRequests: true)
        requests.feed.cards = ["Request 1"]
        await requests.layOut()
        requests.window.setContentSize(fixed)
        await requests.layOut()
        let smallest = requests.window.frame
        check("smallest window is 820×532", smallest.size == CGSize(width: 820, height: 532), "frame \(smallest)")
        check("one card takes just its natural height and padding", requests.feed.frames["requests"]?.height == 154, "frames \(requests.feed.frames)")
        let field = requests.feed.frames["field"]
        let stop = requests.feed.frames["stop"]
        check("field and Stop are in the window", field != nil && stop != nil && (stop?.maxY ?? .infinity) <= smallest.height, "frames \(requests.feed.frames)")
        for count in [4, 12] {
            requests.feed.cards = (1...count).map { "Request \($0)" }
            await requests.layOut()
            let frames = requests.feed.frames
            check("\(count) requests: the window does not resize", requests.window.frame == smallest, "frame \(requests.window.frame), was \(smallest)")
            check("\(count) requests: the field and Stop stay put", frames["field"] == field && frames["stop"] == stop, "frames \(frames)")
            check("\(count) requests: the transcript keeps room for several lines", (frames["transcript"]?.height ?? 0) >= 100, "frames \(frames)")
            check("\(count) requests: the last card is below the stack's viewport", (frames["card-\(count - 1)"]?.minY ?? 0) > (frames["requests"]?.maxY ?? .infinity), "frames \(frames)")
            requests.feed.showLastRequest = true
            await requests.layOut()
            let last = requests.feed.frames["card-\(count - 1)"] ?? .null
            let stack = requests.feed.frames["requests"] ?? .null
            check("\(count) requests: the last card can scroll into the viewport", !last.isNull && stack.contains(last), "last card \(last), stack \(stack)")
            requests.feed.cards = ["Request 1"]
            requests.feed.showLastRequest = false
            await requests.layOut()
        }
        requests.close()
    }

    await group("a project's hub at the smallest size, in each fold, with the sidebar and without (#471)") {
        let hub = Made(fixed: true, hub: true)
        await hub.layOut()
        check("the smallest size is the same as without the hub", hub.window.contentMinSize == fixed, "smallest \(hub.window.contentMinSize), fixed \(fixed)")
        check("the content is never asked for a size as small as that", hub.measuredFor.isEmpty, "asked for \(hub.measuredFor)")
        hub.window.setContentSize(fixed)
        await hub.layOut()
        let smallest = hub.window.frame
        let bounds = hub.host.frame
        hub.resizes = 0
        var widths: [CGFloat] = []
        for sidebar in [NavigationSplitViewVisibility.all, .detailOnly] {
            hub.feed.sidebar = sidebar
            for fold in HubFold.allCases {
                hub.feed.hubFold = fold
                await hub.layOut()
                let frames = hub.feed.frames
                let name = "\(sidebar == .all ? "with the sidebar" : "without it"), \(fold.rawValue)"
                let width = frames["bar"]?.width ?? 0
                let narrow = width < HubFold.narrowWidth
                if fold == .both { widths.append(width) }
                let shown = fold.shown(narrow: narrow)
                check("\(name): the window does not resize", hub.window.frame == smallest, "frame \(hub.window.frame), was \(smallest)")
                check("\(name): smallest size", hub.window.contentMinSize == fixed, "smallest \(hub.window.contentMinSize), fixed \(fixed)")
                check("\(name): the split view is no taller than the window", hub.tallestColumn <= hub.host.frame.height + 0.5, "a column is \(hub.tallestColumn) tall")
                check("\(name): the hub says whether it is narrow, \(Int(width)) points wide", hub.feed.hubNarrow == narrow, "said \(hub.feed.hubNarrow)")
                for (part, present) in [("conversation", shown != .conversationFolded), ("board", shown != .boardFolded), ("strip", shown == .conversationFolded)] {
                    let frame = frames[part]
                    check("\(name): the \(part) is \(present ? "shown" : "folded away")", (frame != nil) == present, "frames \(frames)")
                    if let frame, present {
                        check("\(name): the \(part) is inside the window", frame.minX >= -0.5 && frame.maxX <= bounds.width + 0.5 && frame.maxY <= bounds.height + 0.5 && frame.width >= 200, "\(part) \(frame) in \(bounds.size)")
                    }
                }
                if shown == .both, let conversation = frames["conversation"], let board = frames["board"] {
                    check("\(name): the panels share the width", abs(conversation.width - board.width) <= 2, "conversation \(conversation), board \(board)")
                }
            }
        }
        check("with the sidebar the hub is too narrow for both panels, and without it is not", widths.count == 2 && widths[0] < HubFold.narrowWidth && widths[1] >= HubFold.narrowWidth, "widths \(widths)")
        check("the window was never resized", hub.resizes == 0, "\(hub.resizes) resizes")
        check("nothing was reported as not settling", hub.reports.isEmpty, hub.reports.joined(separator: "\n      "))
        hub.close()
    }

    await group("the watch names a view whose size does not settle, once") {
        let watched = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        watched.isReleasedWhenClosed = false
        watched.title = "Watched"
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        watched.contentView = root
        let column = NSHostingView(rootView: Text("Detail"))
        root.addSubview(column)
        var reports: [String] = []
        let watch = SizeWatch { reports.append($0) }
        watch.start(watched)
        // A person resizing the window: a change or two a turn.
        for step in 0..<30 {
            column.frame = NSRect(x: 0, y: 0, width: 300 + step, height: 300)
            await settle()
        }
        check("a view resized a step a turn is not reported", reports.isEmpty, reports.joined(separator: "\n      "))
        // A size that does not settle: changing again and again before the run loop turns.
        for pass in 0..<(SizeWatch.threshold * 3) {
            column.frame = NSRect(x: 0, y: 0, width: 300, height: pass.isMultiple(of: 2) ? 300 : 420)
        }
        await settle()
        check("it is reported once", reports.count == 1, "\(reports.count) reports")
        check("the report names the view", reports.first?.contains("NSHostingView<Text>") == true, reports.first ?? "")
        check("and the window", reports.first?.contains("Watched") == true, reports.first ?? "")
        for _ in 0..<(SizeWatch.threshold * 2) { column.frame.size.width += 1 }
        await settle()
        check("it is not reported again in the same launch", reports.count == 1, "\(reports.count) reports")
        watch.stop()
        watched.close()
    }

    await group("the watch on a scene body reports a read of something that changes, once") {
        for reads in [true, false] {
            let waiting = Waiting()
            let runs = Runs()
            let watch = BodyWatch("The body")
            let reported = Lines()
            var reports: [String] { reported.lines }
            let report: @MainActor @Sendable (String) -> Void = { reported.lines.append($0) }
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Watched(waiting: waiting, watch: watch, reads: reads, runs: runs, report: report))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            await settle()
            let outer = runs["outer"], inner = runs["inner"]
            for _ in 0..<3 {
                waiting.count += 1
                await settle()
                window.layoutIfNeeded()
                window.displayIfNeeded()
                await settle()
            }
            let kind = reads ? "a body that reads the count" : "a body that passes it on"
            check("\(kind): the view of its own is drawn again for each change", runs["inner"] - inner == 3, "drawn \(runs["inner"] - inner) times for 3 changes")
            if reads {
                check("\(kind): SwiftUI still sees the read and works the body out again", runs["outer"] - outer == 3, "worked out \(runs["outer"] - outer) times for 3 changes")
                check("\(kind): it is reported once", reports.count == 1, "\(reports.count) reports")
                check("\(kind): the report names the body", reports.first?.hasPrefix("The body read something") == true, reports.first ?? "")
            } else {
                check("\(kind): the body is not worked out again", runs["outer"] == outer, "worked out \(runs["outer"] - outer) times for 3 changes")
                check("\(kind): nothing is reported", reports.isEmpty, reports.joined(separator: "\n      "))
            }
            window.close()
        }
    }

    print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
    exit(failures == 0 ? 0 : 1)
}
app.run()
