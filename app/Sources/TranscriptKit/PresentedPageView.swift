
import Foundation
import Network
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The view a presented page is drawn in, live in its window and offscreen for its snapshot (docs/design/presenting.md,
/// "A page an agent wrote is untrusted"). A page an agent wrote is drawn as a hostile page would have to be:
///
/// - its own web view, so its own web content process, and a data store of its own that keeps nothing on disk;
/// - loaded from `pi2-presented://<origin>/<path>`, a new origin each time, served from the manifest of its copy alone
///   (`PresentedSchemeHandler`), never from a `file:` address or with read access to a folder;
/// - no message handler on the live view; the offscreen one has `pi2log`, which takes strings for the console lines of
///   its answer and nothing else;
/// - the network off: a content rule list that blocks every load but the scheme's own, a Content-Security-Policy on
///   every response, a proxy where nothing listens for whatever WebKit connects to by itself, links to http followed
///   by a script so that WebKit connects to nothing ahead of them, and WebRTC and the APIs that ask for a permission or
///   put up the system's own panels taken away in every frame before the page's scripts run;
/// - no navigation away from its origin, no new windows, no downloads, no full screen, no panels: an alert, a
///   confirmation, a prompt, a file picker, a camera, a microphone are each answered at once without anything shown.
///
/// Scripts run: what makes them safe here is everything above.
///
/// "Allow network for this page" is a live view made with `network: true`, the person's choice in the window alone,
/// for one view: its rule list lets https and secure WebSockets through (never plain http or ws) but to this Mac and the
/// local network as written, its policy lets them load, and it has no dead-end proxy. All of it hangs on one constant,
/// `PresentedPagePolicy.networkCanBeAllowed`. Everything else holds as above: no message handler, no
/// navigation away, no new windows, downloads or panels, WebRTC and what asks for a permission taken away. A view made
/// without it, and every offscreen one, has the network off as above, and nothing can turn it on afterwards: allowing
/// it is making a new view.
public final class PresentedPageView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    public enum Mode: Sendable {
        /// In the window: no message handler at all.
        case live
        /// Offscreen, for the snapshot and the findings: the `pi2log` handler, for its console lines.
        case drawing
    }

    public let page: PresentedPage
    public let mode: Mode
    /// Whether this view's page may reach the network (not this Mac or the local network): false unless the live view
    /// was made with `network: true`.
    public let network: Bool
    /// This page's origin, made as it was made: `pi2-presented://<origin>/`.
    public let origin: String
    /// A link or a script tried to take the page away from its origin, and was stopped: for the window's bar.
    public var onBlockedNavigation: (URL) -> Void = { _ in }
    /// The page's process ended a second time; it is not drawn again.
    public var onProcessEnded: () -> Void = {}
    /// What the page did that the findings report: its console, what was refused, what it asked for.
    public private(set) var record = PresentedPageRecord()
    /// The page's process ended and it was loaded again; once only.
    public private(set) var reloads = 0

    private let schemeHandler: PresentedSchemeHandler
    private let log: PresentedLog?
    /// Set only between asking for the entry and WebKit asking whether it may load it.
    private var expecting: URL?
    /// A page of this origin asked for in the main frame that is not among the files.
    private var missingPage: URL?
    /// The first load of the entry ended: nil if it loaded, else why not. For drawing offscreen.
    var loadEnded: ((String?) -> Void)?

    /// The world of the app's own, which the page's scripts cannot reach.
    static let world = WKContentWorld.world(name: "pi2-presented")

    /// A view for a page, its files from `source`, loading it. Throws if the network rules cannot be made: a page is
    /// never drawn without them.
    public static func make(page: PresentedPage, source: any PresentedFiles, mode: Mode) async throws -> PresentedPageView {
        try await make(page: page, source: source, mode: mode, network: false, loadEnded: nil)
    }

    /// A live view whose page may reach the network if `network` is true: the person's "Allow network for this page".
    public static func makeLive(page: PresentedPage, source: any PresentedFiles, network: Bool) async throws -> PresentedPageView {
        try await make(page: page, source: source, mode: .live, network: network, loadEnded: nil)
    }

    /// The same, told when the first load of the entry ends, from before it starts.
    static func make(page: PresentedPage, source: any PresentedFiles, mode: Mode, loadEnded: ((String?) -> Void)?) async throws -> PresentedPageView {
        try await make(page: page, source: source, mode: mode, network: false, loadEnded: loadEnded)
    }

    private static func make(page: PresentedPage, source: any PresentedFiles, mode: Mode, network: Bool, loadEnded: ((String?) -> Void)?) async throws -> PresentedPageView {
        // Only a live view, in the window, is ever drawn with the network: never one drawn offscreen for the engine.
        let network = network && mode == .live && PresentedPagePolicy.networkCanBeAllowed
        let rules = try await PresentedRules.shared(network: network)
        let deadEnd = PresentedDeadEnd.port
        guard network || deadEnd != nil else { throw PresentedRulesError.noDeadEnd }
        return PresentedPageView(page: page, source: source, mode: mode, network: network, rules: rules, deadEnd: network ? nil : deadEnd, loadEnded: loadEnded)
    }

    private init(page: PresentedPage, source: any PresentedFiles, mode: Mode, network: Bool, rules: WKContentRuleList, deadEnd: UInt16?, loadEnded: ((String?) -> Void)?) {
        self.page = page
        self.mode = mode
        self.network = network
        let origin = PresentedPagePolicy.newOrigin()
        self.origin = origin
        let handler = PresentedSchemeHandler(page: page, source: source, origin: origin,
                                             policy: network ? PresentedPagePolicy.contentSecurityPolicyWithNetwork : PresentedPagePolicy.contentSecurityPolicy)
        schemeHandler = handler
        log = mode == .drawing ? PresentedLog() : nil

        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        // Whatever WebKit itself connects to without asking the rule list (a link clicked or a page navigated to is
        // connected to ahead, while the navigation delegate is still to decide) goes to a proxy on this Mac where
        // nothing listens: refused at once, and no name looked up, since a proxy is given the name to look up.
        // With the network allowed there is none: the rule list alone keeps this Mac and the local network out.
        if let deadEnd {
            store.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: deadEnd)!))]
        }
        configuration.websiteDataStore = store
        configuration.setURLSchemeHandler(handler, forURLScheme: PresentedPagePolicy.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        // Safe Browsing's lookups go to the network; a page here loads nothing from it to look up.
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        #if os(iOS)
        configuration.dataDetectorTypes = []
        configuration.allowsPictureInPictureMediaPlayback = false
        #endif
        let content = configuration.userContentController
        content.add(rules)
        content.addUserScript(WKUserScript(source: PresentedPagePolicy.takenAway, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        if let log {
            content.add(log, contentWorld: .page, name: "pi2log")
            content.addUserScript(WKUserScript(source: PresentedPagePolicy.consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            content.addUserScript(WKUserScript(source: PresentedPagePolicy.quietScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        }
        super.init(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        handler.onNotFound = { [weak self] path in self?.record.notFound(path) }
        log?.view = self
        navigationDelegate = self
        uiDelegate = self
        allowsLinkPreview = false
        allowsBackForwardNavigationGestures = false
        #if os(macOS)
        allowsMagnification = false
        #endif
        #if PI2_DEVELOPMENT
        isInspectable = true
        #endif
        self.loadEnded = loadEnded
        loadEntry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The address of the page's entry at its origin.
    public var entryAddress: URL? { PresentedPagePolicy.address(of: page.entry, origin: origin) }

    private func loadEntry() {
        guard let url = entryAddress else {
            loadEnded?("its entry, \(page.entry), has no address")
            return
        }
        expecting = url
        load(URLRequest(url: url))
    }

    /// Stops listening to the page, for a view that is going away. Its web content process may outlive it: `end` ends it.
    public func close() {
        configuration.userContentController.removeAllScriptMessageHandlers()
        log?.view = nil
        stopLoading()
    }

    /// Whether `end` has been asked: the page is never loaded again after that.
    public private(set) var isEnding = false
    /// Told when the page's process has ended, while `end` waits for it.
    private var processGone: (() -> Void)?

    /// Closes the view and ends its web content process, and says whether it is known to have gone. Call it whenever a
    /// page is done with: after drawing, when its window closes, before its window shows another item.
    ///
    /// WebKit keeps a page's process after its view is let go, closed, stopped, sent to a blank page or to another
    /// origin, and after `_killWebContentProcess`; a page whose script never yields keeps it at full speed (#1000's
    /// security read; each was measured). No public call ends it. So this uses WebKit's own
    /// `_killWebContentProcessAndResetState`, which is not public, looked up when it runs; on a WebKit without it, the
    /// process's id (`_webProcessIdentifier`, also not public) and SIGKILL, to the process WebKit started for this view.
    /// Gone is seen by the process's id where WebKit gives it, else by `webViewWebContentProcessDidTerminate`, within
    /// `wait`. False if it could not be ended or seen to end: the caller then counts it as alive (`PresentedProcesses`).
    public func end(wait: Duration = .seconds(5)) async -> Bool {
        isEnding = true
        close()
        let pid = Self.processIdentifier(of: self)
        // No process (none was started, or it has ended already): nothing to end.
        if pid == 0 { return true }
        var told = false
        processGone = { told = true }
        defer { processGone = nil }
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        if responds(to: kill) {
            perform(kill)
        } else if let pid {
            Darwin.kill(pid, SIGKILL)
        } else {
            return false
        }
        let until = ContinuousClock.now + wait
        while ContinuousClock.now < until {
            if let pid {
                if Darwin.kill(pid, 0) != 0 && errno == ESRCH { return true }
            } else if told {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// The id of the view's web content process: 0 for none, nil if WebKit does not say (a call that is not public).
    static func processIdentifier(of view: WKWebView) -> pid_t? {
        guard view.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let number = view.value(forKey: "_webProcessIdentifier") as? NSNumber else { return nil }
        return number.int32Value
    }

    /// Whether an address is this page's own: its scheme and its origin.
    func isOwn(_ url: URL) -> Bool {
        url.scheme?.lowercased() == PresentedPagePolicy.scheme && url.host(percentEncoded: true)?.lowercased() == origin
            && url.user == nil && url.password == nil && url.port == nil
    }

    func logged(_ message: WKScriptMessage) {
        guard message.webView === self, message.frameInfo.isMainFrame, let url = message.frameInfo.request.url, isOwn(url),
              let line = message.body as? String else { return }
        if line.hasPrefix("blocked ") {
            // The page's own report of a refusal (its security-policy events, which it can make itself): kept apart from
            // what the app saw refused itself.
            record.blocked(String(line.dropFirst("blocked ".count)), byPage: true)
        } else if line.hasPrefix("console ") {
            record.console(String(line.dropFirst("console ".count)))
        }
    }

    // MARK: Navigation

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let main = navigationAction.targetFrame?.isMainFrame
        if navigationAction.shouldPerformDownload {
            record.answered("a download, not made")
            return .cancel
        }
        if let expecting, main == true, url == expecting {
            self.expecting = nil
            return .allow
        }
        // A link within the page's own origin (a mockup of several pages), or a frame of it; an empty frame of its own.
        if main != nil, isOwn(url) { return .allow }
        if main == false, url.scheme == "about", ["blank", "srcdoc"].contains(url.absoluteString.dropFirst("about:".count).prefix { $0 != "?" && $0 != "#" }) {
            return .allow
        }
        if !isOwn(url) { record.blocked(url.absoluteString) }
        if main == nil {
            record.answered("a new window, not opened")
            return .cancel
        }
        if main == true { onBlockedNavigation(url) }
        return .cancel
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // A page of the origin that is not among the files is not drawn as one (WebKit gives a scheme's response
        // without its status here).
        if navigationResponse.isForMainFrame, let url = navigationResponse.response.url, isOwn(url),
           !(PresentedPagePolicy.manifestPath(of: url, origin: origin).map(schemeHandler.has) ?? false) {
            missingPage = url
            return .cancel
        }
        // What WebKit would not show itself, it would download: nothing is downloaded.
        guard navigationResponse.canShowMIMEType else {
            record.answered("a download, not made")
            return .cancel
        }
        return .allow
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadEnded?(nil)
        loadEnded = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loadEnded?("it did not load: \(error.localizedDescription)")
        loadEnded = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if let missingPage {
            self.missingPage = nil
            loadEnded?("\(missingPage.path.dropFirst()) is not among the page's files")
        } else {
            loadEnded?("it did not load: \(error.localizedDescription)")
        }
        loadEnded = nil
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Ended on purpose: never loaded again.
        if isEnding {
            processGone?()
            return
        }
        if let loadEnded {
            self.loadEnded = nil
            loadEnded("its web content process ended")
            return
        }
        guard reloads == 0 else {
            onProcessEnded()
            return
        }
        reloads += 1
        loadEntry()
    }

    // MARK: Nothing that asks the person

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        record.answered("a new window, not opened")
        if let url = navigationAction.request.url, url.absoluteString != "about:blank" { record.blocked(url.absoluteString) }
        return nil
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        record.answered("an alert, not shown")
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        record.answered("a confirmation, answered no")
        return false
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        record.answered("a prompt, answered with nothing")
        return nil
    }

    public func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        record.answered("the camera or the microphone, denied")
        return .deny
    }

    #if os(macOS)
    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        record.answered("a file, not chosen")
        return nil
    }

    // MARK: Its menu

    private static let unwantedMenuItems: Set<String> = [
        "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierOpenMediaInNewWindow", "WKMenuItemIdentifierDownloadMedia", "WKMenuItemIdentifierShowHideMediaControls",
        "WKMenuItemIdentifierToggleFullScreen", "WKMenuItemIdentifierToggleEnhancedFullScreen", "WKMenuItemIdentifierInspectElement",
        "WKMenuItemIdentifierPaste", "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierShareMenu",
    ]

    /// WebKit's menu for text (Copy, Look Up) and little else: nothing that reloads, opens, downloads or shares; Inspect
    /// Element in a development build only.
    override public func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        #if PI2_DEVELOPMENT
        let unwanted = Self.unwantedMenuItems.subtracting(["WKMenuItemIdentifierInspectElement"])
        #else
        let unwanted = Self.unwantedMenuItems
        #endif
        for item in menu.items where unwanted.contains(item.identifier?.rawValue ?? "") { menu.removeItem(item) }
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    /// Nothing dropped on the page reaches it.
    override public func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
    #else
    public func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo) async -> WKPermissionDecision {
        record.answered("the device's motion, denied")
        return .deny
    }

    public func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        nil
    }
    #endif
}

/// What a page did that its findings report, each list capped as the design says.
public struct PresentedPageRecord: Sendable {
    public private(set) var consoleLines: [String] = []
    /// Every address refused: those the app saw refused itself, and those the page reported.
    public private(set) var blockedAddresses: [String] = []
    /// Of those, the ones the app saw refused itself (the navigation delegate's), which the page cannot make up.
    public private(set) var blockedSeen: [String] = []
    public private(set) var notFoundPaths: [String] = []
    public private(set) var answeredRequests: [String] = []

    mutating func console(_ line: String) {
        guard consoleLines.count < PresentedPageFindings.consoleLines else { return }
        consoleLines.append(String(line.prefix(PresentedPageFindings.lineLength)))
    }

    mutating func blocked(_ address: String, byPage: Bool = false) {
        let address = String(address.prefix(PresentedPageFindings.lineLength))
        Self.add(address, to: &blockedAddresses)
        if !byPage, blockedAddresses.contains(address) { Self.add(address, to: &blockedSeen) }
    }

    mutating func notFound(_ path: String) {
        Self.add(String(path.prefix(PresentedPageFindings.lineLength)), to: &notFoundPaths)
    }

    mutating func answered(_ what: String) {
        Self.add(what, to: &answeredRequests)
    }

    private static func add(_ item: String, to list: inout [String]) {
        guard !item.isEmpty, !list.contains(item), list.count < PresentedPageFindings.addresses else { return }
        list.append(item)
    }
}

/// The offscreen view's `pi2log` handler, without the view's configuration keeping the view alive.
final class PresentedLog: NSObject, WKScriptMessageHandler {
    weak var view: PresentedPageView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { view?.logged(message) }
    }
}

/// The content rule list, compiled once a process, into a store in the temporary folder: nothing of it is kept with
/// the app's own data, and a store that cannot be written is an error, never a page drawn without it.
@MainActor
enum PresentedRules {
    private static var compiled: WKContentRuleList?
    private static var compiledWithNetwork: WKContentRuleList?

    /// The network-off list, or with `network` the list of a page the person allowed the network.
    static func shared(network: Bool = false) async throws -> WKContentRuleList {
        if let list = network ? compiledWithNetwork : compiled { return list }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pi2-presented-rules", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: folder) else { throw PresentedRulesError.noStore }
        let list = try await store.compileContentRuleList(
            forIdentifier: network ? "presented-network-on" : "presented-network-off",
            encodedContentRuleList: network ? PresentedPagePolicy.contentRulesWithNetwork : PresentedPagePolicy.contentRules)
        guard let list else { throw PresentedRulesError.noStore }
        if network { compiledWithNetwork = list } else { compiled = list }
        return list
    }
}

enum PresentedRulesError: Error {
    case noStore
    case noDeadEnd
}

/// A port on 127.0.0.1 where nothing listens, kept so for as long as the app runs: a socket bound to it that never
/// listens, so a connection to it is refused at once, and nothing else can take it.
enum PresentedDeadEnd {
    static let port: UInt16? = {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0 }
        }
        guard bound, address.sin_port != 0 else {
            close(socket)
            return nil
        }
        return UInt16(bigEndian: address.sin_port)
    }()
}
