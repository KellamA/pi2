import AppKit
import Observation
import WebKit

/// The view in the Browser window that a page is put into. The page fills it, whatever size it is given.
public final class BrowserPaneView: NSView {
    override public func resizeSubviews(withOldSize oldSize: NSSize) {
        for view in subviews { view.frame = bounds }
    }
}

/// pi²'s own browser: one page per conversation, all sharing one profile that belongs to pi² alone.
///
/// The engine decides what is allowed and asks for approval; this loads the pages, reads them and acts on them. The
/// rules that must hold whatever the engine sends (public http and https only, no passwords typed, no downloads) are
/// checked again here. A page lives in the Browser window while the person is looking at it and in a window that is
/// never shown the rest of the time, so an agent can work it either way.
@MainActor
@Observable
public final class BrowserController {
    /// The page the person opens for themselves, for signing in to a site before an agent needs it.
    public static let ownPageID = 0

    public private(set) var pages: [BrowserPage] = []
    /// The page the Browser window shows.
    public var selected: Int?

    @ObservationIgnored public let policy: BrowserPolicy
    @ObservationIgnored let dataStore: WKWebsiteDataStore
    @ObservationIgnored let world = WKContentWorld.world(name: "pi2")
    @ObservationIgnored private let rules: Task<WKContentRuleList?, Never>
    @ObservationIgnored private var lookups: [String: (private: Bool, at: Date)] = [:]
    /// Where pages wait while nobody is looking at them. A web view outside any window has nothing to lay out in.
    @ObservationIgnored private lazy var shelf: NSWindow = {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.shelfSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.contentView = NSView(frame: NSRect(origin: .zero, size: Self.shelfSize))
        return window
    }()

    static let shelfSize = NSSize(width: 1280, height: 900)
    /// Each page is a process of its own; the ones not used for longest go when there are more than this.
    static let mostPages = 8

    /// `rulesFolder` is where WebKit keeps the compiled rules about what pages may load; nil means its usual place.
    public init(profile: BrowserProfile, policy: BrowserPolicy = BrowserPolicy(), rulesFolder: URL? = nil) {
        self.policy = policy
        switch profile {
        case .persistent(let identifier): dataStore = WKWebsiteDataStore(forIdentifier: identifier)
        case .ephemeral: dataStore = .nonPersistent()
        }
        let source = policy.contentRules()
        rules = Task { @MainActor in
            let store = rulesFolder.flatMap { WKContentRuleListStore(url: $0) } ?? WKContentRuleListStore.default()
            return try? await store?.compileContentRuleList(forIdentifier: "pi2-private-addresses", encodedContentRuleList: source)
        }
    }

    // MARK: - Pages

    public func page(_ id: Int) -> BrowserPage? {
        pages.first { $0.id == id }
    }

    /// The page of a conversation, made the first time it is wanted.
    public func openPage(_ id: Int) async -> BrowserPage {
        if let page = page(id) { return page }
        let ruleList = await rules.value
        // Another caller may have made it while the rules were being compiled.
        if let page = page(id) { return page }
        let page = BrowserPage(id: id, owner: self, rules: ruleList)
        park(page.webView)
        pages.append(page)
        if selected == nil { selected = id }
        trim(keeping: id)
        return page
    }

    public func close(_ id: Int) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        let page = pages.remove(at: index)
        page.shutDown()
        if selected == id { selected = pages.last?.id }
    }

    /// Close the pages of conversations that no longer exist.
    public func keepOnly(_ ids: Set<Int>) {
        for page in pages where page.id != Self.ownPageID && !ids.contains(page.id) { close(page.id) }
    }

    private func trim(keeping id: Int) {
        while pages.count > Self.mostPages {
            let idle = pages.filter { $0.id != id && $0.id != selected && !$0.busy }
            guard let oldest = idle.min(by: { $0.lastUsed < $1.lastUsed }) else { return }
            close(oldest.id)
        }
    }

    // MARK: - Showing a page

    private func park(_ webView: WKWebView) {
        webView.removeFromSuperview()
        webView.autoresizingMask = []
        webView.frame = NSRect(origin: .zero, size: Self.shelfSize)
        shelf.contentView?.addSubview(webView)
    }

    /// Put a page into a view of the Browser window, and whatever that view showed before back on the shelf.
    public func show(_ id: Int?, in container: NSView) {
        let wanted = id.flatMap(page)?.webView
        for case let shown as WKWebView in container.subviews where shown !== wanted { park(shown) }
        guard let wanted, wanted.superview !== container else { return }
        wanted.removeFromSuperview()
        wanted.frame = container.bounds
        wanted.autoresizingMask = [.width, .height]
        container.addSubview(wanted)
    }

    // MARK: - Looking names up

    /// Whether a name stands for an address on this Mac or the local network. Asked once a minute at most per name.
    func resolvesToPrivate(_ host: String) async -> Bool {
        let name = host.lowercased()
        if let known = lookups[name], Date().timeIntervalSince(known.at) < 60 { return known.private }
        let found = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: BrowserPolicy.resolvesToPrivate(name)) }
        }
        lookups[name] = (found, Date())
        if lookups.count > 500 { lookups = lookups.filter { Date().timeIntervalSince($0.value.at) < 60 } }
        return found
    }

    // MARK: - What agents ask

    static let noPage = "No page is open yet. Use open or search first."

    public func perform(_ request: BrowserRequest) async -> BrowserReply {
        let id = request.conversationId
        switch request.action {
        case "open", "search":
            let page = await openPage(id)
            return await page.inTurn { await page.act(request) }
        case "describe":
            guard let page = page(id), page.hasDocument else { return .failure(Self.noPage) }
            switch await page.describe(request, of: request.of ?? "") {
            case .success(let said): return BrowserReply(ok: true, text: said.text, host: page.site, navigates: said.navigates)
            case .failure(let reply): return reply
            }
        case "read", "screenshot", "click", "type", "select", "scroll", "back", "upload":
            guard let page = page(id), page.hasDocument else { return .failure(Self.noPage) }
            return await page.inTurn { await page.act(request) }
        default:
            return .failure("Unknown action “\(request.action)”.")
        }
    }

    // MARK: - What the person asks

    /// Sign out everywhere: remove every cookie and everything else sites have stored in this browser.
    public func forgetEverything() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        for page in pages where page.hasDocument { page.webView.reload() }
    }

    /// Go where the person typed in the address field: an address, or words to search for. Answers why not, if not.
    @discardableResult
    public func go(_ typed: String, in id: Int) async -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let page = await openPage(id)
        let looksLikeAddress = !text.contains(" ") && (text.contains(".") || text.contains(":") || text.hasPrefix("localhost"))
        var url: URL?
        if looksLikeAddress { url = URL(string: text.contains("://") ? text : "https://" + text) }
        if url == nil {
            var search = URLComponents(string: "https://duckduckgo.com/")
            search?.queryItems = [URLQueryItem(name: "q", value: text)]
            url = search?.url
        }
        guard let url else { return "“\(text.clipped(80))” is not a web address." }
        if case .refused(let why) = policy.check(url) {
            page.notice = why
            return why
        }
        page.notice = nil
        page.webView.load(URLRequest(url: url))
        return nil
    }
}
