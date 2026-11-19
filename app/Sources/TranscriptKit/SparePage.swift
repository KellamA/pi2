import Foundation

/// One transcript page loaded ahead and idle, for the next pane that opens (#441).
///
/// Loading the page (a web content process, `index.html` and its scripts) took about 100 ms of every opening, whatever
/// the conversation. `take()` hands over the page loaded ahead, ready or still loading, and loads another a moment
/// later, so that loading it does not compete with the pane that just opened. Only a page that has never been handed
/// over is ever handed over: a pane's page goes with its pane, so none holds anything of a conversation.
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
        page.onReload = { [weak self, weak page] in
            guard let self, let page else { return }
            self.died(page)
        }
        self.page = page
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
        dead.close()
        replaced += 1
        loadSoon()
    }
}
