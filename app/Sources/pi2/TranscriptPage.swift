import AppKit
import SwiftUI
import WebKit

/// The transcript page in the app bundle, put there by app/build.sh. A bare `swift build` has no bundle to carry it,
/// and the app shows the SwiftUI transcript instead.
enum TranscriptPage {
    static let folder: URL? = {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let folder = resources.appendingPathComponent("transcript", isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.html").path) ? folder : nil
    }()
}

/// pi²'s palette from `Theme`, resolved for one appearance as CSS colours for the page.
enum TranscriptPalette {
    @MainActor
    static func colors(for appearance: NSAppearance) -> [String: String] {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let named: [(String, Color)] = [
            ("window", Theme.window), ("panel", Theme.panel), ("card", Theme.card), ("card2", Theme.card2),
            ("line", Theme.line), ("line2", Theme.line2), ("tx", Theme.tx), ("tx2", Theme.tx2), ("tx3", Theme.tx3),
            ("acc", Theme.acc), ("ok", Theme.ok), ("warn", Theme.warn), ("bad", Theme.bad), ("on-acc", Theme.onAcc),
        ]
        var result = ["appearance": isDark ? "dark" : "light"]
        appearance.performAsCurrentDrawingAppearance {
            for (name, color) in named {
                if let css = css(color) { result[name] = css }
            }
        }
        return result
    }

    /// A colour as CSS `rgb()` or `rgba()`, resolved in the current drawing appearance.
    static func css(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded()), g = Int((rgb.greenComponent * 255).rounded()), b = Int((rgb.blueComponent * 255).rounded())
        let alpha = rgb.alphaComponent
        return alpha >= 0.999 ? "rgb(\(r), \(g), \(b))" : String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, alpha)
    }
}

/// Something the person did in the transcript page, as the page reports it through the `pi2` message handler.
///
/// The page shows untrusted text, so every message is checked here before it is believed: a known type, fields of the
/// right kinds, sizes within reason, and links only to http, https and mailto. Whether an approval, an entry or a
/// sub-chat it names really belongs to the conversation is checked by whoever acts on it.
enum TranscriptAction: Equatable {
    /// The page has loaded and wants the whole conversation.
    case ready
    case copy(String)
    case openLink(URL)
    case decide(inbox: String, decision: String)
    case answer(inbox: String, text: String)
    case openChat(Int)
    case fork(entry: Int)
    case picture(entry: Int, index: Int)

    static let copyLimit = 20_000_000
    static let answerLimit = 100_000

    init?(message body: Any) {
        guard let body = body as? [String: Any], let type = body["type"] as? String else { return nil }
        switch type {
        case "ready":
            self = .ready
        case "copy":
            guard let text = body["text"] as? String, !text.isEmpty, text.utf16.count <= Self.copyLimit else { return nil }
            self = .copy(text)
        case "openLink":
            guard let url = Self.link(body["url"]) else { return nil }
            self = .openLink(url)
        case "decide":
            guard let id = Self.identifier(body["inbox"]), let decision = body["decision"] as? String,
                  ["once", "always", "deny"].contains(decision) else { return nil }
            self = .decide(inbox: id, decision: decision)
        case "answer":
            guard let id = Self.identifier(body["inbox"]), let text = body["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= Self.answerLimit else { return nil }
            self = .answer(inbox: id, text: text)
        case "openChat":
            guard let id = Self.integer(body["id"]) else { return nil }
            self = .openChat(id)
        case "fork":
            guard let entry = Self.integer(body["entry"]) else { return nil }
            self = .fork(entry: entry)
        case "image":
            guard let entry = Self.integer(body["entry"]), let index = Self.integer(body["index"]), index >= 0, index < 1000 else { return nil }
            self = .picture(entry: entry, index: index)
        default:
            return nil
        }
    }

    /// A web or mail address the person may be sent to, and nothing else.
    static func link(_ value: Any?) -> URL? {
        guard let text = value as? String, text.utf16.count <= 8192, let url = URL(string: text),
              let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return nil }
            return url
        case "mailto":
            return text.count > "mailto:".count ? url : nil
        default:
            return nil
        }
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf16.count <= 200 else { return nil }
        return text
    }

    private static func integer(_ value: Any?) -> Int? {
        // JavaScript numbers arrive as NSNumber; a fraction, a Boolean or anything out of range is not an ID.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 9_007_199_254_740_992 else { return nil }
        return number.intValue
    }
}

/// The web view the transcript lives in. It loads the page once and nothing after: every later navigation (a link, a
/// reload, a script, a dropped file) is cancelled, it opens no windows, keeps nothing on disk, takes no drops, and its
/// menu offers no way to navigate, open or download. Messages from the page arrive as checked `TranscriptAction`s.
final class TranscriptWebKitView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    /// What the person did in the page.
    var onAction: (TranscriptAction) -> Void = { _ in }
    /// The page was loaded again (its process ended); it has forgotten everything it was sent.
    var onReload: () -> Void = {}
    /// The view's appearance changed, so the page needs the palette again.
    var onAppearanceChange: () -> Void = {}

    private let folder: URL
    private var page: URL { folder.appendingPathComponent("index.html") }
    /// Set only between asking for the page and WebKit asking whether it may load it.
    private var expecting: URL?
    private let messages = MessageHandler()

    init(folder: URL) {
        self.folder = folder
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.userContentController.add(messages, contentWorld: .page, name: "pi2")
        super.init(frame: .zero, configuration: configuration)
        messages.view = self
        navigationDelegate = self
        uiDelegate = self
        allowsLinkPreview = false
        allowsBackForwardNavigationGestures = false
        allowsMagnification = false
        #if DEBUG
        isInspectable = true
        if ProcessInfo.processInfo.environment["PI2_DRAW_WHEN_HIDDEN"] != nil { drawWhenHidden() }
        #endif
        load()
    }

    #if DEBUG
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
        expecting = page
        loadFileURL(page, allowingReadAccessTo: folder)
    }

    /// Stops listening to the page, for a view that is going away.
    func close() {
        configuration.userContentController.removeAllScriptMessageHandlers()
        messages.view = nil
    }

    fileprivate func received(_ message: WKScriptMessage) {
        // Only the transcript page itself, in this view's main frame, is listened to.
        guard message.webView === self, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.isFileURL == true, message.frameInfo.request.url?.path == page.path,
              let action = TranscriptAction(message: message.body) else { return }
        onAction(action)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if let expecting, navigationAction.targetFrame?.isMainFrame == true, navigationAction.request.url?.isFileURL == true,
           navigationAction.request.url?.path == expecting.path {
            self.expecting = nil
            return .allow
        }
        return .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        load()
        onReload()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    // MARK: Appearance, drops, menu

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange()
    }

    /// Files and pictures dropped anywhere on the conversation are attached to the message being written, so the page
    /// registers for no drags and a drop over it reaches the conversation.
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

    private static let unwantedMenuItems: Set<String> = [
        "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierOpenMediaInNewWindow", "WKMenuItemIdentifierDownloadMedia", "WKMenuItemIdentifierShowHideMediaControls",
        "WKMenuItemIdentifierToggleFullScreen", "WKMenuItemIdentifierToggleEnhancedFullScreen", "WKMenuItemIdentifierInspectElement",
        "WKMenuItemIdentifierPaste",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        #if DEBUG
        let unwanted = Self.unwantedMenuItems.subtracting(["WKMenuItemIdentifierInspectElement"])
        #else
        let unwanted = Self.unwantedMenuItems
        #endif
        for item in menu.items where unwanted.contains(item.identifier?.rawValue ?? "") { menu.removeItem(item) }
        // No separator at either end or twice in a row once items have gone.
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}

/// Hands the page's messages to the view without the view's own configuration keeping it alive.
private final class MessageHandler: NSObject, WKScriptMessageHandler {
    weak var view: TranscriptWebKitView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        view?.received(message)
    }
}
