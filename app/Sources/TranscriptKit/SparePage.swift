#if os(macOS)
import AppKit

/// One transcript page loaded ahead and idle, for the next pane that opens (#441).
///
/// A new pane's page took 100 to 160 ms to load (a web content process, `index.html` and its scripts), whatever the
/// conversation, and was the largest step of opening one. `take()` hands over the page loaded ahead, ready or still
/// loading, and loads another a moment later, so that loading it does not compete with the pane that just opened. Only a page that has never been handed over is ever handed over: a pane's page goes with
/// its pane, so none holds anything of a conversation.
///
/// While it waits, the page sits in the window, in a `SparePageHost` behind the conversations, unseen and out of reach
/// of clicks, keys and VoiceOver: a page kept in no window took WebKit 50 to 180 ms to draw once put in one, which was
/// most of the time saved. Without a host in a window it waits in no window, and still saves the loading.
///
/// One page, not a pool: each costs a web content process's memory while it waits. A page whose process ends while it
/// waits is let go, and another is loaded in its place. Nothing is loaded ahead until the first page is taken.
@MainActor
public final class SparePage {
    public let folder: URL
    /// How long after a page is taken the next is loaded. Taking another meanwhile starts the wait again.
    public let delay: Duration
    /// The page loaded ahead, if there is one.
    public private(set) var page: TranscriptWebKitView?
    /// How many pages loaded ahead have been let go because their process ended while they waited.
    public private(set) var replaced = 0
    /// Where the page waits: a view in the window behind the conversations.
    private weak var host: SparePageHost?
    private var waiting: Task<Void, Never>?

    public init(folder: URL, delay: Duration = .seconds(1)) {
        self.folder = folder
        self.delay = delay
    }

    /// A page for a pane: the one loaded ahead, or a new one if there is none yet. Either may still be loading; its
    /// `isReady` says whether it has said it is ready, and its `onMessage` gets `ready` later if not.
    public func take() -> TranscriptWebKitView {
        let taken: TranscriptWebKitView
        if let page {
            self.page = nil
            page.onReload = {}
            page.isWaiting = false
            // Left in the host until its pane is in the window (`TranscriptPane`): moved from one view to another in
            // the same window, it never leaves the window, and WebKit has it ready to draw. Meanwhile it is still behind
            // what the window shows, and the host still keeps clicks and VoiceOver from it.
            page.alphaValue = 1
            taken = page
        } else {
            taken = TranscriptWebKitView(folder: folder)
        }
        loadSoon()
        return taken
    }

    /// Loads a page ahead now, if none is.
    public func load() {
        waiting?.cancel()
        waiting = nil
        guard page == nil else { return }
        let page = TranscriptWebKitView(folder: folder)
        page.isWaiting = true
        page.alphaValue = 0
        page.onReload = { [weak self, weak page] in
            guard let self, let page else { return }
            self.died(page)
        }
        self.page = page
        place()
    }

    /// Where pages wait from now on, the newest host to come into a window.
    func hosted(in host: SparePageHost) {
        self.host = host
        place()
    }

    /// Puts the waiting page in the host, filling it, so it is laid out at about a pane's size.
    private func place() {
        guard let page, let host, host.window != nil, page.superview !== host else { return }
        page.removeFromSuperview()
        page.frame = host.bounds
        page.autoresizingMask = [.width, .height]
        host.addSubview(page)
    }

    private func loadSoon() {
        waiting?.cancel()
        waiting = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.load()
        }
    }

    /// The process of the page loaded ahead ended. The view would load the page again by itself; a new view starts
    /// from nothing instead, after the usual wait, so that a process that keeps ending does not keep the app busy.
    private func died(_ dead: TranscriptWebKitView) {
        guard page === dead else { return }
        page = nil
        dead.removeFromSuperview()
        dead.close()
        replaced += 1
        loadSoon()
    }
}

/// A pane's place for its page, which fills it. A page taken from `SparePage` stays where it waited, in the window,
/// until this view is in the window too, and then moves straight here: a page taken out of the window and put back was
/// some 50 ms longer before WebKit drew it, about what loading it ahead saves.
public final class TranscriptPane: NSView {
    public let page: TranscriptWebKitView

    public init(page: TranscriptWebKitView) {
        self.page = page
        super.init(frame: .zero)
        // A page in no window (a new one, or one waiting in no window) has nothing to keep: it comes in at once.
        if page.window == nil { adopt() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, page.superview !== self { adopt() }
    }

    private func adopt() {
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        addSubview(page)
    }
}

/// Where the page loaded ahead waits, in the window behind the conversations (`SparePage`). It and what it holds take
/// no clicks, are not in VoiceOver's view, and the page is never drawn: it is transparent until a pane takes it.
public final class SparePageHost: NSView {
    private weak var spare: SparePage?

    public init(spare: SparePage?) {
        self.spare = spare
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { spare?.hosted(in: self) }
    }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
    override public func accessibilityChildren() -> [Any]? { [] }
    override public func isAccessibilityElement() -> Bool { false }
}
#endif
