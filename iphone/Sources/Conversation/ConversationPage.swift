import PiModels
import SwiftUI
import TranscriptKit
import UIKit

/// What the page is to show of the conversation: what the client has of it, and the names only the app knows.
struct ConversationPageContent {
    var conversationID: Int
    var items: [Item]
    /// How many entries older than `items` the engine is still to send.
    var earlier: Int
    /// Whether the conversation has entries older than all the client has, and whether they are being asked for.
    var older: TranscriptFeed.Older = .none
    var state: ConversationState?
    var names: TranscriptFeed.Names
}

/// A conversation's transcript on the phone: TranscriptKit's page in its UIKit view (docs/transcript.md, "On a phone"),
/// loaded from this build's bundle under the page's content security policy, and the bridge between it and the screen.
struct ConversationPage: UIViewRepresentable {
    let folder: URL
    let content: ConversationPageContent
    /// The page has drawn the conversation and is shown.
    var onShown: () -> Void = {}
    /// The person tapped a link: to be confirmed before it is opened.
    var onLink: (URL) -> Void = { _ in }
    /// A hand-off's sub-chat to show on its own screen.
    var onOpenConversation: (Int) -> Void = { _ in }
    /// A file link's target, to show the file on its own screen.
    var onFile: (String) -> Void = { _ in }
    /// The two reads the page may ask for (`ConversationPagePolicy`): the entries before those the client has, and one
    /// of an entry's pictures, as the engine answers it (nil when it could not be had).
    var loadOlder: () -> Void = {}
    var fetchPicture: (_ entry: Int, _ index: Int) async -> (data: String, mimeType: String)? = { _, _ in nil }

    func makeCoordinator() -> ConversationPageBridge {
        ConversationPageBridge()
    }

    func makeUIView(context: Context) -> TranscriptUIKitView {
        context.coordinator.makeView(folder: folder)
    }

    func updateUIView(_ view: TranscriptUIKitView, context: Context) {
        let bridge = context.coordinator
        bridge.onShown = onShown
        bridge.onLink = onLink
        bridge.onOpenConversation = onOpenConversation
        bridge.onFile = onFile
        bridge.loadOlder = loadOlder
        bridge.fetchPicture = fetchPicture
        bridge.show(content)
    }

    static func dismantleUIView(_ view: TranscriptUIKitView, coordinator: ConversationPageBridge) {
        view.close()
    }
}

/// Between the page and the screen: sends the page what changed, as the Mac's `TranscriptBridge` does, and does what the
/// page asks only as `ConversationPagePolicy` allows: nothing that acts through the engine (docs/iphone.md section 8),
/// and two reads of this conversation.
@MainActor
final class ConversationPageBridge {
    private weak var view: TranscriptUIKitView?
    private var ready = false
    /// Hidden until the page has drawn the conversation, so it never shows empty over the screen's loading line.
    private var hidden = true
    private var feed = TranscriptFeed()
    private var content: ConversationPageContent?
    /// Whether a part of the older entries the app has is on its way to the page: the next goes once it is drawn.
    private var olderOnTheWay = false
    var onShown: () -> Void = {}
    var onLink: (URL) -> Void = { _ in }
    var onOpenConversation: (Int) -> Void = { _ in }
    var onFile: (String) -> Void = { _ in }
    var loadOlder: () -> Void = {}
    var fetchPicture: (_ entry: Int, _ index: Int) async -> (data: String, mimeType: String)? = { _, _ in nil }

    #if DEBUG
    /// The page last made, for `PI2_CONVERSATION_ACT`'s scrolling and tapping in it (`ConversationDebugAct`).
    static weak var shown: TranscriptUIKitView?
    #endif

    func makeView(folder: URL) -> TranscriptUIKitView {
        let view = TranscriptUIKitView(folder: folder)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.alpha = 0
        view.onMessage = { [weak self] body in
            guard let action = TranscriptAction(message: body) else { return }
            self?.perform(action)
        }
        view.onReload = { [weak self] in
            self?.ready = false
            self?.hidden = true
            self?.view?.alpha = 0
        }
        view.onAppearanceChange = { [weak self] in self?.push() }
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: TranscriptUIKitView, _: UITraitCollection) in
            self?.applyTextSize()
        }
        self.view = view
        #if DEBUG
        Self.shown = view
        #endif
        return view
    }

    /// How much larger than at the standard size the page is drawn: as much as body text grows, up to twice, past
    /// which a phone's width would hold too few words to a line.
    nonisolated static func zoom(for traits: UITraitCollection) -> CGFloat {
        let body = UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits)
        return min(max(body / 17, 0.85), 2)
    }

    func show(_ content: ConversationPageContent) {
        if let shown = self.content, shown.conversationID != content.conversationID {
            feed.restart()
            olderOnTheWay = false
        }
        self.content = content
        if hidden {
            push { [weak self] in self?.reveal() }
        } else {
            push()
        }
    }

    /// The page's text follows the person's text size, as the rest of the screen does: the page is zoomed as CSS zooms
    /// it, which lays it out again at the narrower width, rather than scaled past the screen's edge as `pageZoom` does.
    /// Set through the CSS object model, as the page sets its own palette, which its content security policy allows.
    private func applyTextSize() {
        guard ready, let view else { return }
        let zoom = Self.zoom(for: view.traitCollection)
        view.callAsyncJavaScript("document.documentElement.style.setProperty('zoom', zoom)", arguments: ["zoom": String(format: "%.3f", zoom)], in: nil, in: .page, completionHandler: nil)
    }

    private func reveal() {
        guard hidden, ready, content?.state != nil else { return }
        hidden = false
        view?.alpha = 1
        // Never from inside `show`, which SwiftUI calls while it updates the view and where a change to the screen's
        // state can be dropped: the screen then kept its loading line under the page and never marked the conversation
        // shown (#687). That happened when the page was ready before the conversation's state came, and the state
        // changed nothing the page draws, as for a conversation at rest.
        Task { @MainActor [weak self] in self?.onShown() }
    }

    /// Sends the page what changed since it was last sent anything; `drawn` once it has drawn it, or at once.
    private func push(drawn: (@MainActor () -> Void)? = nil) {
        guard ready, let view, let content else {
            drawn?()
            return
        }
        let palette = ConversationPalette.colors(for: view.traitCollection)
        // No cards to answer: what waits for the person is shown and answered outside the page (section 8), and
        // changes are drawn without Undo.
        guard let message = feed.update(
            items: content.items, earlier: content.earlier, older: content.older, state: content.state, inbox: [],
            changes: ConversationPagePolicy.changesWithoutUndo(content.state?.projectChanges ?? []), needs: [],
            names: content.names, palette: palette, chat: .none, withOlder: !olderOnTheWay
        ), let json = TranscriptFeed.json(message) else {
            drawn?()
            return
        }
        var then = drawn
        // A long conversation goes newest first, then the older entries the app has a part at a time, each once the
        // page has drawn the one before (#380), as on the Mac.
        if feed.pending > 0, !olderOnTheWay {
            olderOnTheWay = true
            then = { [weak self] in
                drawn?()
                self?.olderOnTheWay = false
                self?.push()
            }
        }
        TranscriptMessages.send(json, to: view, then: then)
    }

    private func perform(_ action: TranscriptAction) {
        let subChats = ConversationPagePolicy.subChats(items: content?.items ?? [], state: content?.state)
        switch ConversationPagePolicy.response(to: action, subChats: subChats, items: content?.items ?? []) {
        case .sendEverything:
            ready = true
            feed.restart()
            olderOnTheWay = false
            applyTextSize()
            push { [weak self] in self?.reveal() }
        case .copy(let text):
            UIPasteboard.general.string = text
        case .confirmLink(let url):
            onLink(url)
        case .openConversation(let id):
            onOpenConversation(id)
        case .previewFile(let target):
            onFile(target)
        case .loadOlder:
            // Not while the page still has older entries of the client's to come; the client asks the engine only when
            // it said there is more, one part at a time (`EngineSession.loadOlder`).
            guard feed.pending == 0 else { return }
            loadOlder()
        case .fetchPicture(let entry, let index):
            let conversation = content?.conversationID
            Task { [weak self] in
                guard let self else { return }
                var picture: [String: Any] = ["entry": entry, "index": index]
                // Without data, the page shows that the picture could not be had.
                if let fetched = await fetchPicture(entry, index), Self.pictureTypes.contains(fetched.mimeType) {
                    picture["data"] = fetched.data
                    picture["mimeType"] = fetched.mimeType
                }
                guard content?.conversationID == conversation else { return }
                send(["image": picture])
            }
        case .notice(let text):
            send(["notice": text])
        case .ignore:
            break
        }
    }

    private static let pictureTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8) else { return }
        TranscriptMessages.send(json, to: view)
    }
}
