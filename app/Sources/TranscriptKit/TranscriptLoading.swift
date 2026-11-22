import Foundation
import WebKit

/// How the page lays itself out: as the Mac draws it, at any width a pane can have; or for a phone (#671), whose view
/// marks the page so that the rules for a narrow screen and touch apply (`html.narrow.touch` in transcript.css). The
/// Mac's view never marks it, so nothing of those rules reaches the Mac, however narrow its pane.
public enum TranscriptLayout: Sendable {
    case wide
    case phone

    /// The classes the page's root element is given before anything is drawn.
    var classes: [String] {
        switch self {
        case .wide: []
        case .phone: ["narrow", "touch"]
        }
    }
}

/// What a page receives from the person's side of the app, and loads: shared by the Mac's view
/// (`TranscriptWebKitView`) and the phone's (`TranscriptUIKitView`), so that both load the page once and nothing after,
/// keep nothing on disk, open no windows, and listen only to the page itself, in its own view's main frame.
@MainActor
final class TranscriptLoading {
    let folder: URL
    let messages = TranscriptMessageHandler()
    /// Whether the page has loaded and said it is ready, since it was last loaded.
    private(set) var isReady = false
    private var page: URL { folder.appendingPathComponent("index.html") }
    /// Set only between asking for the page and WebKit asking whether it may load it.
    private var expecting: URL?

    init(folder: URL) {
        self.folder = folder
    }

    /// The web view's configuration: no website data on disk, no windows, no full screen, no warnings that would load
    /// anything, the `pi2` message handler, and the layout's mark on the page.
    func configuration(layout: TranscriptLayout) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.userContentController.add(messages, contentWorld: .page, name: "pi2")
        if !layout.classes.isEmpty {
            // Before the page's own scripts and its first drawing. A script the app adds is not the page's, so the
            // page's Content-Security-Policy, which allows no inline script, does not apply to it.
            let names = layout.classes.map { "\"\($0)\"" }.joined(separator: ", ")
            let source = "document.documentElement.classList.add(\(names));"
            configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        return configuration
    }

    /// Loads the page, from the start.
    func load(into view: WKWebView) {
        isReady = false
        expecting = page
        view.loadFileURL(page, allowingReadAccessTo: folder)
    }

    /// The one navigation allowed is the page itself, once each time it is asked for; every other is cancelled.
    func policy(for navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        if let expecting, navigationAction.targetFrame?.isMainFrame == true, navigationAction.request.url?.isFileURL == true,
           navigationAction.request.url?.path == expecting.path {
            self.expecting = nil
            return .allow
        }
        return .cancel
    }

    /// The message's body, if it came from the transcript page itself in `view`'s main frame; nil for anything else.
    func body(of message: WKScriptMessage, in view: WKWebView) -> Any? {
        guard message.webView === view, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.isFileURL == true, message.frameInfo.request.url?.path == page.path else { return nil }
        if (message.body as? [String: Any])?["type"] as? String == "ready" { isReady = true }
        return message.body
    }

    /// Stops listening to the page, for a view that is going away.
    func close(_ view: WKWebView) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        messages.receiver = nil
    }
}

/// A view the page's messages are handed to.
@MainActor
protocol TranscriptMessageReceiver: AnyObject {
    func received(_ message: WKScriptMessage)
}

/// Hands the page's messages to the view without the view's own configuration keeping it alive.
final class TranscriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var receiver: (any TranscriptMessageReceiver)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        receiver?.received(message)
    }
}
