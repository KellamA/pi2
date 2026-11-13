import AppKit
import Observation
import WebKit

/// One conversation's page: a web view, what the Browser window shows about it, and the actions an agent takes in it.
///
/// Every action answers with the page as it is afterwards, as text: its title and address, a numbered list of what can
/// be acted on in the part shown, and that part's text with the numbers marking where each thing sits.
@MainActor
@Observable
public final class BrowserPage {
    public let id: Int
    @ObservationIgnored public let webView: WKWebView

    public private(set) var title = ""
    public private(set) var address: URL?
    public private(set) var isLoading = false
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var progress = 0.0
    /// Why the last navigation did not happen, for the person. The next page that loads clears it.
    public var notice: String?
    /// Whether an agent is acting in this page right now.
    public private(set) var busy = false
    @ObservationIgnored public private(set) var lastUsed = Date()

    @ObservationIgnored private let policy: BrowserPolicy
    @ObservationIgnored private weak var owner: BrowserController?
    @ObservationIgnored private let world: WKContentWorld
    @ObservationIgnored private var watching: [NSKeyValueObservation] = []
    @ObservationIgnored private var delegate: PageDelegate?
    @ObservationIgnored private var turn: Task<Void, Never>?
    /// What happened along the way during the action in progress, told to the agent with its result.
    @ObservationIgnored private var notes: [String] = []
    @ObservationIgnored private var refusedNavigation: String?
    @ObservationIgnored private var loadError: String?
    @ObservationIgnored private var stillLoading = false
    /// How many documents this web view has shown, to tell whether an action led to a new one.
    @ObservationIgnored private var documents = 0
    @ObservationIgnored private var documentsBefore = 0
    /// The file an agent's upload is about to hand to the page's file chooser.
    @ObservationIgnored fileprivate var pendingUpload: [URL]?
    @ObservationIgnored fileprivate var uploadTaken = false
    @ObservationIgnored private var lastView: (address: String, start: Int, text: String)?

    /// How much of a page's text one view holds.
    static let textLimit = 8000

    static let noPasswords = "That is a password field. pi² does not type passwords. Ask the person to sign in themselves in the pi² browser window (Window › Browser), then read the page again."
    static let noCards = "That looks like a payment card field. pi² does not enter payment details. Ask the person to fill it in themselves in the pi² browser window (Window › Browser), then read the page again."
    static let noDownloads = "pi² does not download files in this version."

    /// Safari's own version, so that sites see the browser they expect and do not serve a cut-down page.
    private static let safariVersion: String = {
        if let version = Bundle(path: "/Applications/Safari.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return version }
        let system = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return system >= 26 ? "\(system).0" : "18.6"
    }()

    init(id: Int, owner: BrowserController, rules: WKContentRuleList?) {
        self.id = id
        self.owner = owner
        policy = owner.policy
        world = owner.world
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = owner.dataStore
        // WebKit puts this after its own "Mozilla/5.0 (Macintosh; …) AppleWebKit/… (KHTML, like Gecko)".
        configuration.applicationNameForUserAgent = "Version/\(Self.safariVersion) Safari/605.1.15"
        // A page nobody is looking at still has to run at full speed: an agent may be working in it.
        configuration.preferences.inactiveSchedulingPolicy = .none
        if let rules { configuration.userContentController.add(rules) }
        webView = WKWebView(frame: NSRect(origin: .zero, size: BrowserController.shelfSize), configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        let delegate = PageDelegate(page: self)
        self.delegate = delegate
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        watching = [
            webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.title = self?.webView.title ?? "" } },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.address = self?.webView.url } },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.isLoading = self?.webView.isLoading ?? false } },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.canGoBack = self?.webView.canGoBack ?? false } },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.canGoForward = self?.webView.canGoForward ?? false } },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.progress = self?.webView.estimatedProgress ?? 0 } },
        ]
    }

    func shutDown() {
        watching = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        delegate = nil
    }

    /// Whether a web page is loaded, as opposed to the blank the web view starts with.
    public var hasDocument: Bool {
        let scheme = webView.url?.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// The site the page is on: what approvals and "always allow" are about.
    public var site: String { webView.url?.host ?? "" }
    private var siteName: String { site.isEmpty ? "the page" : site }

    /// Whether the person is looking at this page and no agent is in the middle of something in it, so that a dialog
    /// the page puts up is theirs to answer.
    fileprivate var personIsThere: Bool { !busy && webView.window?.isVisible == true }

    // MARK: - One action at a time

    /// Run `work` after whatever this page is already doing. The engine sends one action at a time per conversation;
    /// this holds even if an earlier one outlived the engine's patience.
    func inTurn(_ work: @escaping @MainActor () async -> BrowserReply) async -> BrowserReply {
        let before = turn
        let mine = Task { @MainActor in
            await before?.value
            return await work()
        }
        turn = Task { @MainActor in _ = await mine.value }
        return await mine.value
    }

    // MARK: - Talking to the page

    private struct Done: Decodable {
        var ok: Bool
        var error: String?
        var did: String?
        var navigate: String?
        var moved: Bool?
        var names: [String]?
    }

    private func call<T: Decodable>(_ function: String, _ arguments: [String: Any] = [:]) async -> T? {
        let body = PageScript.source + "\nreturn JSON.stringify(await pi2.\(function)(args));"
        guard let value = try? await webView.callAsyncJavaScript(body, arguments: ["args": arguments], in: nil, contentWorld: world),
              let json = value as? String else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// A cheap fingerprint of the page, to tell when it has stopped changing.
    private func signature() async -> String {
        let body = "const b = document.body; return document.readyState + '|' + location.href + '|' + (b ? b.getElementsByTagName('*').length + '/' + (b.innerText || '').length : 0);"
        return (try? await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: world)) as? String ?? ""
    }

    /// How long a page is given to come to rest after an action.
    private enum Patience {
        /// Typing and choosing: the page reacts at once or not at all.
        case brief
        /// A click that may or may not lead somewhere.
        case usual
        /// A new page: what it shows often arrives a moment after it has loaded.
        case newPage

        /// How many looks in a row must find the page unchanged.
        var steadyLooks: Int {
            switch self {
            case .brief: 1
            case .usual: 2
            case .newPage: 4
            }
        }
    }

    /// Wait for the page to finish loading and then to stop changing, within limits: pages that never rest exist.
    private func settle(_ patience: Patience = .usual) async {
        let quick = patience == .brief
        stillLoading = false
        try? await Task.sleep(for: .milliseconds(quick ? 60 : 200))
        let clock = ContinuousClock()
        let began = clock.now
        var quietSince: ContinuousClock.Instant?
        var last = ""
        var steady = 0
        var looks = patience.steadyLooks
        while true {
            let now = clock.now
            // Whatever the action was, if it led to another page, that page is given a new page's time.
            if webView.isLoading || documents != documentsBefore { looks = max(looks, Patience.newPage.steadyLooks) }
            if webView.isLoading {
                quietSince = nil
                steady = 0
                last = ""
                if now - began > .seconds(25) {
                    stillLoading = true
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            let since = quietSince ?? now
            quietSince = since
            let seen = await signature()
            if seen == last, !seen.isEmpty { steady += 1 } else { steady = 0 }
            last = seen
            if steady >= looks || now - since > .seconds(quick ? 2 : 6) { return }
            try? await Task.sleep(for: .milliseconds(quick ? 80 : 160))
        }
    }

    // MARK: - Reading

    private struct PageView: Decodable {
        struct Scrolled: Decodable {
            var top: Int
            var most: Int
        }
        var title: String
        var url: String
        var total: Int
        var start: Int
        var end: Int
        var text: String
        var lines: [String]
        var unlisted: Int
        var elsewhere: Int
        var truncated: Bool
        var password: Bool
        var human: Bool
        var scrolled: Scrolled
    }

    /// Which stretch of the page's text a view shows.
    private enum Stretch {
        case start
        case offset(Int)
        /// Where the window is scrolled to.
        case viewport
        /// The stretch shown last, unless this element is outside it.
        case element(Int)
        case keep
    }

    /// Read the page and answer with it. `did` is what just happened, said first. After an action, text that is the
    /// same as in the last view is not repeated; `whole` is for when the agent asked to read.
    private func look(did: String?, summary: String, _ stretch: Stretch, whole: Bool = false) async -> BrowserReply {
        var arguments: [String: Any] = ["limit": Self.textLimit, "last": lastView?.start ?? 0]
        switch stretch {
        case .start: arguments["mode"] = "start"
        case .offset(let offset):
            arguments["mode"] = "offset"
            arguments["offset"] = offset
        case .viewport: arguments["mode"] = "viewport"
        case .element(let number):
            arguments["mode"] = "element"
            arguments["element"] = number
        case .keep: arguments["mode"] = "keep"
        }
        var lines: [String] = []
        if let did { lines.append(did) }
        lines.append(contentsOf: notes)
        guard let view: PageView = await call("view", arguments) else {
            lines.append("The page could not be read just now; it may still be loading. Read it again in a moment.")
            return BrowserReply(ok: did != nil, text: lines.joined(separator: "\n"), summary: summary)
        }
        if !lines.isEmpty { lines.append("") }
        lines.append("Page: \(view.title.isEmpty ? "(no title)" : view.title)")
        lines.append("Address: \(view.url.clipped(500))")
        if stillLoading { lines.append("The page is still loading; read it again in a moment for the rest.") }
        if view.password {
            lines.append("This page has a password field. If it is a sign-in, ask the person to sign in themselves in the pi² browser window (Window › Browser), then read the page again.")
        }
        if view.human {
            lines.append("This page may be checking that a person is there (a CAPTCHA). If so, ask the person to complete it in the pi² browser window (Window › Browser), then read the page again.")
        }
        lines.append("")
        if view.lines.isEmpty {
            lines.append(view.elsewhere > 0 ? "Nothing to act on in this part of the page." : "Nothing on this page can be acted on.")
        } else {
            lines.append("What can be acted on here (the numbers are for this view only):")
            lines.append(contentsOf: view.lines)
            if view.unlisted > 0 { lines.append("(\(view.unlisted) more in this part are marked in the text below.)") }
        }
        if view.elsewhere > 0 { lines.append("(\(view.elsewhere) more in other parts of the page.)") }
        lines.append("")
        let partial = view.start > 0 || view.end < view.total
        var heading = "Text"
        if partial {
            heading += ", characters \(view.start + 1) to \(view.end) of \(view.total)"
            if view.end < view.total { heading += " (read with offset \(view.end) for the next part)" }
        }
        let same = !whole && did != nil && lastView.map { $0.address == view.url && $0.start == view.start && $0.text == view.text } == true
        if view.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("This page has no text to read.")
        } else if same {
            lines.append("\(heading): the same as in your last view of this part of the page.")
        } else {
            lines.append("\(heading):")
            lines.append(view.text)
        }
        if view.truncated { lines.append("(The page is very long; only its first part can be read.)") }
        lastView = (view.url, view.start, view.text)
        return BrowserReply(ok: true, text: lines.joined(separator: "\n"), summary: summary)
    }

    // MARK: - Describing, for approval

    struct Described {
        var text: String
        /// Whether the action only goes to another address, as opening that address would.
        var navigates = false
        var target: URL?
        /// The element as a result names it: “Submit”, or "the unnamed button".
        var named = ""
        /// For an action that only navigates: what to say once it has.
        var went = ""
    }

    private struct ElementInfo: Decodable {
        var ok: Bool
        var error: String?
        var kind: String?
        var name: String?
        var label: String?
        var group: String?
        var disabled: Bool?
        var plain: String?
        var frame: String?
        var checked: Bool?
        var password: Bool?
        var payment: Bool?
        var readonly: Bool?
        var option: String?
        var optionError: String?
    }

    /// What an action would do, in words a person can approve ("Click “Submit application” on example.com"), or why
    /// it cannot be done. Every action on an element passes through here first, approved or not, so this is also
    /// where the rules about passwords and payment details are kept.
    func describe(_ request: BrowserRequest, of action: String) async -> Result<Described, BrowserReply> {
        guard hasDocument else { return .failure(.failure(BrowserController.noPage)) }
        guard let number = request.element else { return .failure(.failure("\(action) needs `element`, a number from the newest view of the page.")) }
        var arguments: [String: Any] = ["n": number]
        if let option = request.option { arguments["option"] = option }
        guard let info: ElementInfo = await call("describe", arguments) else {
            return .failure(.failure("The page could not be read just now; it may still be loading. Read it again in a moment."))
        }
        guard info.ok else { return .failure(.failure(info.error ?? "There is no element \(number) on the page.")) }
        let kind = info.kind ?? ""
        let name = info.name ?? "element"
        let label = info.label ?? ""
        let named = label.isEmpty ? "the unnamed \(name)" : "“\(label)”"
        let group = (info.group ?? "").isEmpty ? "" : " in “\(info.group ?? "")”"
        let place = " on \(siteName)"
        let disabled = info.disabled == true
        switch action {
        case "click":
            if disabled { return .failure(.failure("Element \(number), \(named), is disabled, so clicking it would do nothing.")) }
            if kind == "select" { return .failure(.failure("Element \(number) is a drop-down list. Use select with one of its choices instead of clicking it.")) }
            if kind == "file" { return .failure(.failure("Element \(number) is a file input. Use upload with the file's path instead of clicking it.")) }
            if let link = info.plain ?? info.frame {
                guard let target = URL(string: link) else { return .failure(.failure("Element \(number) leads to an address that cannot be opened.")) }
                if case .refused(let why) = policy.check(target) { return .failure(.failure("\(named) leads to \(link.clipped(200)), which was not opened. \(why)")) }
                let text = info.plain != nil ? "Follow the link \(named) to \(link.clipped(300))" : "Open the page inside the frame \(named), \(link.clipped(300))"
                let went = info.plain != nil ? "Followed the link \(named)." : "Opened the page inside the frame \(named)."
                return .success(Described(text: text, navigates: true, target: target, named: named, went: went))
            }
            if kind == "frame" { return .failure(.failure("Element \(number) is a page inside this one that has no address to open.")) }
            if kind == "checkbox" { return .success(Described(text: "\(info.checked == true ? "Uncheck" : "Check") \(named)\(group)\(place)", named: named)) }
            if kind == "radio" { return .success(Described(text: "Choose \(named)\(group)\(place)", named: named)) }
            return .success(Described(text: "Click \(named)\(place)", named: named))
        case "type":
            guard kind == "field" else { return .failure(.failure("Element \(number), \(named), is a \(name), not a field to type into.")) }
            if info.password == true { return .failure(.failure(Self.noPasswords)) }
            if info.payment == true { return .failure(.failure(Self.noCards)) }
            if disabled || info.readonly == true { return .failure(.failure("Element \(number), \(named), cannot be changed.")) }
            let field = label.isEmpty ? "the unnamed \(name)" : "the “\(label)” field"
            let text = request.text ?? ""
            var said: String
            if text.isEmpty {
                said = "Clear \(field)\(place)"
            } else if text.count <= 80 {
                said = "Type “\(text)” into \(field)\(place)"
            } else {
                // The card shows the whole text under this line.
                said = "Type \(text.count) characters into \(field)\(place), beginning “\(text.clipped(60))”"
            }
            if request.submit { said += ", then press Return" }
            return .success(Described(text: said, named: named))
        case "select":
            guard kind == "select" else {
                return .failure(.failure("Element \(number), \(named), is a \(name), not a drop-down list. Click it to open it, then click the choice you want."))
            }
            if disabled { return .failure(.failure("Element \(number), \(named), is disabled.")) }
            if let problem = info.optionError { return .failure(.failure(problem)) }
            return .success(Described(text: "Choose “\(info.option ?? request.option ?? "")” in \(named)\(place)", named: named))
        case "upload":
            guard kind == "file" else { return .failure(.failure("Element \(number), \(named), is a \(name), not a file input.")) }
            if disabled { return .failure(.failure("Element \(number), \(named), is disabled.")) }
            let path = ((request.path ?? "") as NSString).abbreviatingWithTildeInPath
            return .success(Described(text: "Upload \(path) to \(named)\(place)", named: named))
        default:
            return .failure(.failure("Unknown action “\(action)”."))
        }
    }

    // MARK: - Acting

    func act(_ request: BrowserRequest) async -> BrowserReply {
        busy = true
        notes = []
        refusedNavigation = nil
        loadError = nil
        documentsBefore = documents
        defer {
            busy = false
            lastUsed = Date()
        }
        var said = Described(text: "")
        if ["click", "type", "select", "upload"].contains(request.action) {
            switch await describe(request, of: request.action) {
            case .failure(let reply): return reply
            case .success(let now):
                // What the person approved, or what was judged to need no approval, is what gets done, or nothing is.
                if let expect = request.expect, expect != now.text {
                    return .failure("The page changed after this action was described, so it was not done. It was described as: \(expect). It would now be: \(now.text). Read the page again and decide afresh.")
                }
                said = now
            }
        }
        // Describing has already made sure that an action on an element names one.
        let number = request.element ?? 0
        switch request.action {
        case "open", "search": return await open(request)
        case "read": return await look(did: nil, summary: "Read \(siteName)", request.offset.map { .offset($0) } ?? .start, whole: true)
        case "screenshot": return await picture()
        case "click": return await click(number, said)
        case "type": return await type(number, request, said)
        case "select": return await select(number, request, said)
        case "scroll": return await scroll(request.dy ?? 0)
        case "back": return await back()
        case "upload": return await upload(number, request, said)
        default: return .failure("Unknown action “\(request.action)”.")
        }
    }

    private func open(_ request: BrowserRequest) async -> BrowserReply {
        guard let text = request.url, let url = URL(string: text) else { return .failure("open needs `url`, the address of the page.") }
        if case .refused(let why) = policy.check(url) { return .failure(why) }
        webView.load(URLRequest(url: url))
        await settle(.newPage)
        if let refusedNavigation { return .failure(refusedNavigation) }
        if let loadError { return .failure("The page could not be loaded: \(loadError)") }
        let summary = request.action == "search" ? "Searched for “\((request.query ?? "").clipped(60))”" : "Opened \(siteName)"
        return await look(did: nil, summary: summary, .start, whole: true)
    }

    /// Whether the page is at another address than `before`, not counting the part after "#".
    private func moved(from before: URL?) -> Bool {
        let bare: (URL?) -> String = { url in
            guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
            parts.fragment = nil
            return parts.string ?? url.absoluteString
        }
        return bare(webView.url) != bare(before)
    }

    private func click(_ number: Int, _ said: Described) async -> BrowserReply {
        let before = webView.url
        let site = siteName
        var did = ""
        var target = said.target
        if target == nil {
            guard let done: Done = await call("click", ["n": number]) else { return .failure("The click could not be made; the page may have changed. Read it again.") }
            guard done.ok else { return .failure(done.error ?? "The click could not be made.") }
            did = done.did ?? "Clicked \(said.named)."
            // It became a plain link between being described and being clicked: follow it as one.
            if let link = done.navigate, let url = URL(string: link), policy.check(url) == .allowed { target = url }
        }
        if let target {
            // A plain link is followed by loading its address, so following one never does more than opening it would.
            did = said.went.isEmpty ? "Followed the link \(said.named)." : said.went
            webView.load(URLRequest(url: target))
        }
        await settle()
        if target != nil {
            if let refusedNavigation { return .failure(refusedNavigation) }
            if let loadError { return .failure("\(did) The page could not be loaded: \(loadError)") }
        }
        let verb = target != nil ? "Followed" : "Clicked"
        return await look(did: did, summary: "\(verb) \(said.named) on \(site)", moved(from: before) ? .start : .element(number))
    }

    private func type(_ number: Int, _ request: BrowserRequest, _ said: Described) async -> BrowserReply {
        let before = webView.url
        let site = siteName
        guard let done: Done = await call("type", ["n": number, "text": request.text ?? "", "submit": request.submit]) else {
            return .failure("The text could not be typed; the page may have changed. Read it again.")
        }
        guard done.ok else { return .failure(done.error ?? "The text could not be typed.") }
        await settle(request.submit ? .usual : .brief)
        return await look(did: done.did, summary: "Typed into \(said.named) on \(site)", moved(from: before) ? .start : .element(number))
    }

    private func select(_ number: Int, _ request: BrowserRequest, _ said: Described) async -> BrowserReply {
        let before = webView.url
        let site = siteName
        guard let done: Done = await call("select", ["n": number, "option": request.option ?? ""]) else {
            return .failure("The choice could not be made; the page may have changed. Read it again.")
        }
        guard done.ok else { return .failure(done.error ?? "The choice could not be made.") }
        await settle(.brief)
        return await look(did: done.did, summary: "Chose in \(said.named) on \(site)", moved(from: before) ? .start : .element(number))
    }

    private func scroll(_ pages: Int) async -> BrowserReply {
        guard pages != 0 else { return .failure("scroll needs `dy`: pages to scroll, positive for down.") }
        let steps = max(-10, min(pages, 10))
        let direction = steps > 0 ? "down" : "up"
        guard let done: Done = await call("scroll", ["dy": steps]) else { return .failure("The page could not be scrolled just now. Read it again.") }
        var did = "Scrolled \(direction) \(abs(steps)) page\(abs(steps) == 1 ? "" : "s")."
        if done.moved != true { did = "The page did not scroll: this is its \(steps > 0 ? "end" : "top")." }
        // Pages that load more as they are scrolled do it now.
        await settle()
        return await look(did: did, summary: "Scrolled \(direction) on \(siteName)", .viewport)
    }

    private func back() async -> BrowserReply {
        guard webView.canGoBack else { return .failure("There is no earlier page to go back to.") }
        webView.goBack()
        await settle(.newPage)
        return await look(did: "Went back.", summary: "Went back to \(siteName)", .start, whole: true)
    }

    private func upload(_ number: Int, _ request: BrowserRequest, _ said: Described) async -> BrowserReply {
        guard let path = request.path, !path.isEmpty else { return .failure("upload needs `path`, the file to choose.") }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue, FileManager.default.isReadableFile(atPath: path) else {
            return .failure("\(path) is not a file pi² can read.")
        }
        let file = URL(fileURLWithPath: path)
        let site = siteName
        // The page's file input opens its chooser, and the chooser is answered with the file: the same road a person's
        // choice takes, so the page hears about it the same way.
        pendingUpload = [file]
        uploadTaken = false
        defer { pendingUpload = nil }
        guard let opened: Done = await call("chooseFile", ["n": number]), opened.ok else {
            return .failure("The file input could not be used; the page may have changed. Read it again.")
        }
        for _ in 0..<40 where !uploadTaken { try? await Task.sleep(for: .milliseconds(75)) }
        guard uploadTaken else { return .failure("The page did not open its file chooser, so no file was chosen.") }
        await settle(.brief)
        let now: Done? = await call("files", ["n": number])
        guard now?.names?.contains(file.lastPathComponent) != false else {
            return .failure("The page did not take \(file.lastPathComponent); it may not accept that kind of file.")
        }
        return await look(did: "Chose \(file.lastPathComponent) in \(said.named).", summary: "Uploaded \(file.lastPathComponent) on \(site)", .element(number))
    }

    /// A picture of what the web view shows, small enough to be cheap to send.
    private func picture() async -> BrowserReply {
        let configuration = WKSnapshotConfiguration()
        let width = min(max(webView.bounds.width, 320), 1280)
        configuration.snapshotWidth = NSNumber(value: Double(width))
        let image: NSImage? = await withCheckedContinuation { continuation in
            var answered = false
            let answer: (NSImage?) -> Void = { image in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: image)
            }
            webView.takeSnapshot(with: configuration) { image, _ in MainActor.assumeIsolated { answer(image) } }
            // A page that is not being drawn may never deliver one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated { answer(nil) } }
        }
        guard let image, let jpeg = Self.jpeg(of: image, width: Int(width)) else {
            notes.append("A picture could not be taken, so here is the page as text.")
            return await look(did: nil, summary: "Read \(siteName)", .keep, whole: true)
        }
        let text = [
            "Page: \(title.isEmpty ? "(no title)" : title)",
            "Address: \((webView.url?.absoluteString ?? "").clipped(500))",
            "The picture shows the page as the browser window shows it now. Use read for its text and the element numbers.",
        ]
        return BrowserReply(ok: true, text: text.joined(separator: "\n"), summary: "Took a picture of \(siteName)", jpeg: jpeg)
    }

    private static func jpeg(of image: NSImage, width: Int) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let height = max(1, Int((CGFloat(width) * image.size.height / image.size.width).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }

    // MARK: - What the web view reports

    /// A navigation that was not allowed. `main` is for the page itself, as opposed to a frame inside it: a frame
    /// that stays empty is not news to anyone.
    fileprivate func turnedAway(_ message: String, main: Bool) {
        guard main else { return }
        if busy { notes.append(message) }
        refusedNavigation = message
        notice = message
    }

    fileprivate func failedToLoad(_ error: Error) {
        let problem = error as NSError
        // Cancelled, or interrupted by a refusal of our own: neither is news.
        if problem.code == NSURLErrorCancelled || (problem.domain == "WebKitErrorDomain" && problem.code == 102) { return }
        loadError = problem.localizedDescription
        notice = "The page could not be loaded: \(problem.localizedDescription)"
    }

    fileprivate func loaded() {
        notice = nil
        documents += 1
    }

    fileprivate func remark(_ note: String) {
        if busy { notes.append(note) }
    }

    fileprivate func judge(_ url: URL, main: Bool) async -> Bool {
        if case .refused(let why) = policy.check(url) {
            turnedAway("\(url.absoluteString.clipped(200)) was not opened. \(why)", main: main)
            return false
        }
        if policy.needsLookup(url), let host = url.host, await owner?.resolvesToPrivate(host) == true {
            turnedAway("\(url.absoluteString.clipped(200)) was not opened: that name points at this Mac or the local network. \(BrowserPolicy.notLocal)", main: main)
            return false
        }
        return true
    }
}

// MARK: - Delegate

/// What WebKit asks while a page loads and runs. Every navigation, whoever started it, is judged here.
@MainActor
private final class PageDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var page: BrowserPage?

    init(page: BrowserPage) {
        self.page = page
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let page, let url = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        let main = action.targetFrame?.isMainFrame ?? true
        if action.shouldPerformDownload {
            page.turnedAway("That link is a file to download, not a page. \(BrowserPage.noDownloads)", main: main)
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        // The blank a web view starts with, and content a page builds for its own frames, lead nowhere new.
        if scheme == "about" || (!main && (scheme == "data" || scheme == "blob")) {
            decisionHandler(.allow)
            return
        }
        Task { @MainActor in
            decisionHandler(await page.judge(url, main: main) ? .allow : .cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        guard response.canShowMIMEType, !disposition.hasPrefix("attachment") else {
            let name = response.response.suggestedFilename ?? response.response.url?.lastPathComponent ?? "That"
            page?.turnedAway("“\(name.clipped(120))” is a file to download, not a page. \(BrowserPage.noDownloads)", main: response.isForMainFrame)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        page?.loaded()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        page?.failedToLoad(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        page?.failedToLoad(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        page?.remark("The page stopped working and has to be opened again.")
    }

    // A page that asks for a new window gets its own instead: there is one page per conversation.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.request.url != nil { webView.load(action.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        guard let page, page.personIsThere, let window = webView.window else {
            page?.remark("The page showed a message: “\(message.clipped(300))”")
            completionHandler()
            return
        }
        let alert = NSAlert()
        alert.messageText = page.site.isEmpty ? "This page says" : "\(page.site) says"
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let page, page.personIsThere, let window = webView.window else {
            // The click that led here was approved, or needed no approval; saying no would only undo it.
            page?.remark("The page asked “\(message.clipped(300))” and was answered OK.")
            completionHandler(true)
            return
        }
        let alert = NSAlert()
        alert.messageText = page.site.isEmpty ? "This page asks" : "\(page.site) asks"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in completionHandler(response == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        guard let page, page.personIsThere, let window = webView.window else {
            page?.remark("The page asked for text in a dialog (“\(prompt.clipped(300))”), which was left unanswered.")
            completionHandler(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = page.site.isEmpty ? "This page asks" : "\(page.site) asks"
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        guard let page else {
            completionHandler(nil)
            return
        }
        // An agent's upload: the file the engine checked, and nothing else.
        if let chosen = page.pendingUpload {
            page.pendingUpload = nil
            page.uploadTaken = true
            completionHandler(chosen)
            return
        }
        guard page.personIsThere, let window = webView.window else {
            page.remark("The page asked for a file. To give it one, use upload on its file input.")
            completionHandler(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { response in completionHandler(response == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        // No page in pi²'s browser gets the camera or the microphone.
        decisionHandler(.deny)
    }
}
