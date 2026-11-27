#if os(macOS)
import AppKit
import WebKit

/// The web view a conversation's transcript lives in on the Mac (docs/transcript.md). It loads the page once and nothing
/// after: every later navigation (a link, a reload, a script, a dropped file) is cancelled, it opens no windows, keeps
/// nothing on disk, takes no drops, and its menu offers no way to navigate, open or download. Messages from the page
/// itself arrive as they were posted, for the app to check (`TranscriptAction`). The loading is shared with the phone's
/// view (`TranscriptLoading`); the menu, drops, focus and the page loaded ahead are the Mac's.
///
/// Its own module so that pi2-transcript-check can load real pages in it, and hand them over as the app does (#441).
public final class TranscriptWebKitView: WKWebView, WKNavigationDelegate, WKUIDelegate, TranscriptMessageReceiver {
    /// A message the page posted to the `pi2` handler, from this view's main frame and the transcript page itself.
    public var onMessage: (Any) -> Void = { _ in }
    /// The page was loaded again (its process ended); it has forgotten everything it was sent.
    public var onReload: () -> Void = {}
    /// The view's appearance changed, so the page needs the palette again.
    public var onAppearanceChange: () -> Void = {}
    /// Items for the menu WebKit is about to show, for the file the person right-clicked (#451). The page says what
    /// each right-click was on before WebKit asks for its menu, so these are for this menu, and are used once.
    public var fileMenuItems: (items: [(title: String, choose: () -> Void)], at: Date)?
    /// Whether the page has loaded and said it is ready, since it was last loaded. A page loaded ahead (`SparePage`)
    /// says so before anyone listens, so whoever takes it reads this instead of waiting for the message.
    public var isReady: Bool { pageLoad.isReady }
    /// Whether the page is waiting to be handed over (`SparePage`): it then takes no focus.
    var isWaiting = false
    /// How many times the view has been taken out of a window. A page loaded ahead goes from where it waited to its pane
    /// without leaving the window (`TranscriptPane`); pi2-transcript-check counts on this to see that it does.
    public private(set) var timesOutOfWindow = 0

    private let pageLoad: TranscriptLoading

    /// Makes the view and starts loading the page from `folder`, which holds `index.html` and its scripts. The app's
    /// panes are always `.wide`; pi2-transcript-check draws `.phone` here too, as the phone's view marks the page.
    public init(folder: URL, layout: TranscriptLayout = .wide) {
        let pageLoad = TranscriptLoading(folder: folder)
        self.pageLoad = pageLoad
        super.init(frame: .zero, configuration: pageLoad.configuration(layout: layout))
        pageLoad.messages.receiver = self
        navigationDelegate = self
        uiDelegate = self
        allowsLinkPreview = false
        allowsBackForwardNavigationGestures = false
        allowsMagnification = false
        #if PI2_DEVELOPMENT
        isInspectable = true
        if ProcessInfo.processInfo.environment["PI2_DRAW_WHEN_HIDDEN"] != nil { drawWhenHidden() }
        #endif
        load()
    }

    #if PI2_DEVELOPMENT
    /// WebKit stops drawing a page nobody can see: one in a covered window, or behind a locked screen. For taking
    /// pictures of the app in those conditions (docs/development.md), a development build can be told to keep drawing.
    /// It uses a WebKit switch that is not public, so it is never compiled into a release build.
    private func drawWhenHidden() {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard responds(to: selector), let method = method(for: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method, to: Setter.self)(self, selector, false)
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func load() {
        pageLoad.load(into: self)
    }

    /// Stops listening to the page, for a view that is going away.
    public func close() {
        pageLoad.close(self)
    }

    func received(_ message: WKScriptMessage) {
        // Only the transcript page itself, in this view's main frame, is listened to.
        guard let body = pageLoad.body(of: message, in: self) else { return }
        #if PI2_DEVELOPMENT
        // While a test copy's press is in flight, only what a press may set off goes on (TranscriptPress.mayFollow).
        if pressesInFlight > 0 {
            let kind = (body as? [String: Any])?["type"] as? String ?? "(no type)"
            guard TranscriptPress.mayFollow.contains(kind) else {
                droppedInPress.append(kind)
                return
            }
        }
        #endif
        onMessage(body)
    }

    #if PI2_DEVELOPMENT
    /// The conversation the app's bridge last sent this page, for a test copy's press to find the page by (#1023).
    public var shownConversation: Int?
    private var pressesInFlight = 0
    private var droppedInPress: [String] = []

    func beginPress() {
        if pressesInFlight == 0 { droppedInPress = [] }
        pressesInFlight += 1
    }

    /// Ends a press `settle` from now, and says which kinds of message the page posted meanwhile were dropped.
    func endPress(after settle: Duration) async -> [String] {
        try? await Task.sleep(for: settle)
        pressesInFlight -= 1
        return droppedInPress
    }
    #endif

    // MARK: Navigation

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        pageLoad.policy(for: navigationAction)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        load()
        onReload()
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    // MARK: Appearance, drops, menu

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { timesOutOfWindow += 1 }
    }

    override public var acceptsFirstResponder: Bool { !isWaiting && super.acceptsFirstResponder }
    override public var canBecomeKeyView: Bool { !isWaiting && super.canBecomeKeyView }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange()
    }

    /// Files and pictures dropped anywhere on the conversation are attached to the message being written, so the page
    /// registers for no drags and a drop over it reaches the conversation.
    override public func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

    private static let unwantedMenuItems: Set<String> = [
        "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierOpenMediaInNewWindow", "WKMenuItemIdentifierDownloadMedia", "WKMenuItemIdentifierShowHideMediaControls",
        "WKMenuItemIdentifierToggleFullScreen", "WKMenuItemIdentifierToggleEnhancedFullScreen", "WKMenuItemIdentifierInspectElement",
        "WKMenuItemIdentifierPaste",
    ]

    override public func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        #if PI2_DEVELOPMENT
        let unwanted = Self.unwantedMenuItems.subtracting(["WKMenuItemIdentifierInspectElement"])
        #else
        let unwanted = Self.unwantedMenuItems
        #endif
        for item in menu.items where unwanted.contains(item.identifier?.rawValue ?? "") { menu.removeItem(item) }
        if let file = fileMenuItems, Date().timeIntervalSince(file.at) < 5, !file.items.isEmpty {
            for (index, entry) in file.items.enumerated() {
                menu.insertItem(ActionMenuItem(title: entry.title, choose: entry.choose), at: index)
            }
            menu.insertItem(.separator(), at: file.items.count)
        }
        fileMenuItems = nil
        // No separator at either end or twice in a row once items have gone.
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}

/// A menu item that does what it was given when chosen.
private final class ActionMenuItem: NSMenuItem {
    private let choose: () -> Void

    init(title: String, choose: @escaping () -> Void) {
        self.choose = choose
        super.init(title: title, action: #selector(chosen), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func chosen() { choose() }
}
#endif
