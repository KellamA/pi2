#if canImport(UIKit)
import UIKit
import WebKit

/// The web view a conversation's transcript lives in on the phone (docs/iphone.md section 8, #671): the same page as
/// the Mac's, loaded the same way (`TranscriptLoading`), and marked for a narrow screen and touch (`.phone`). It loads
/// the page once and nothing after: every later navigation is cancelled, it opens no windows, keeps nothing on disk,
/// detects nothing in the text as a link, and shows no link previews. Messages from the page itself arrive as they
/// were posted, for the app to check (`TranscriptAction`) before it believes any of them; on the phone none of them
/// may become a request to the engine (docs/iphone.md section 8), which is the bridge's to keep (P18).
///
/// `folder` is the page as the phone app's bundle carries it, never one from the Mac or the network.
public final class TranscriptUIKitView: WKWebView, WKNavigationDelegate, WKUIDelegate, TranscriptMessageReceiver {
    /// A message the page posted to the `pi2` handler, from this view's main frame and the transcript page itself.
    public var onMessage: (Any) -> Void = { _ in }
    /// The page was loaded again (its process ended); it has forgotten everything it was sent.
    public var onReload: () -> Void = {}
    /// The view's appearance changed, so the page needs the palette again.
    public var onAppearanceChange: () -> Void = {}
    /// Whether the page has loaded and said it is ready, since it was last loaded.
    public var isReady: Bool { pageLoad.isReady }

    private let pageLoad: TranscriptLoading

    /// Makes the view and starts loading the page from `folder`, which holds `index.html` and its scripts.
    public init(folder: URL) {
        let pageLoad = TranscriptLoading(folder: folder)
        self.pageLoad = pageLoad
        let configuration = pageLoad.configuration(layout: .phone)
        configuration.dataDetectorTypes = []
        super.init(frame: .zero, configuration: configuration)
        pageLoad.messages.receiver = self
        navigationDelegate = self
        uiDelegate = self
        allowsLinkPreview = false
        allowsBackForwardNavigationGestures = false
        // The page is drawn behind the phone's own bars and keeps its own margins; no inset is added to it.
        scrollView.contentInsetAdjustmentBehavior = .never
        #if PI2_DEVELOPMENT
        isInspectable = true
        #endif
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TranscriptUIKitView, _: UITraitCollection) in
            view.onAppearanceChange()
        }
        pageLoad.load(into: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Stops listening to the page, for a view that is going away.
    public func close() {
        pageLoad.close(self)
    }

    func received(_ message: WKScriptMessage) {
        guard let body = pageLoad.body(of: message, in: self) else { return }
        onMessage(body)
    }

    // MARK: Navigation

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        pageLoad.policy(for: navigationAction)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageLoad.load(into: self)
        onReload()
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    /// A long press on a link or a picture shows no menu of WebKit's (open, share, add to reading list): what a link
    /// does is the app's to ask, as a click on the Mac is.
    public func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        nil
    }
}
#endif
