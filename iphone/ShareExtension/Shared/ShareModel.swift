import Foundation
import Observation
import UIKit

/// What the share page holds: what was shared, as it is read and prepared; where it can go and where it goes; the
/// person's line of instructions; and, once Send is pressed, the draft written for the app (`ShareDrop`).
@MainActor
@Observable
final class ShareModel {
    enum Loading: Equatable {
        case reading
        case ready(ShareContent)
    }

    private(set) var loading: Loading = .reading
    /// Where a share can go, as the app last wrote it; nil when that is not known (no list yet, too old, or no shared
    /// folder at all, as in an unsigned build).
    private(set) var destinations: ShareDestinations?
    var choice: ShareDestination?
    var instructions = ""
    /// Why Send did not work, in the person's words.
    private(set) var sendProblem: String?
    /// Whether what is shown is a debug build's sample, which the page says plainly.
    let isSample: Bool

    @ObservationIgnored private let drop: ShareDrop?
    @ObservationIgnored private let now: () -> Date

    init(drop: ShareDrop?, isSample: Bool = false, now: @escaping () -> Date = { Date() }) {
        self.drop = drop
        self.isSample = isSample
        self.now = now
        destinations = drop?.destinations(at: now())
        if let list = destinations?.destinations {
            let last = drop?.lastConversation
            choice = list.first { $0.conversation == last } ?? list.first
        }
    }

    /// A debug build's sample list in place of the app's, for a picture; never in a release build.
    #if DEBUG
    func showSample(_ list: ShareDestinations?) {
        destinations = list
        choice = list?.destinations.first
    }
    #endif

    var content: ShareContent? {
        if case .ready(let content) = loading { content } else { nil }
    }

    /// Reads the extension context's items, then prepares them off the main thread.
    func load(_ items: [NSExtensionItem]) async {
        await prepare(await ShareItemLoader.load(items))
    }

    func load(_ providers: [NSItemProvider]) async {
        await prepare(await ShareItemLoader.load(providers))
    }

    func prepare(_ raw: [ShareRaw]) async {
        loading = .reading
        let content = await Task.detached(priority: .userInitiated) { ShareContent.prepare(raw) }.value
        loading = .ready(content)
    }

    /// Why Send is not there yet, if it is not, in a line on the page.
    var holdBack: String? {
        guard let content else { return nil }
        if !content.hasContent { return "Nothing here can be sent." }
        if destinations?.destinations.isEmpty != false { return nil }
        if choice == nil { return "Choose where it goes." }
        return nil
    }

    var canSend: Bool {
        content?.hasContent == true && choice != nil && holdBack == nil
    }

    /// Writes the draft for the app; true when it is kept and the page may close.
    func send() -> Bool {
        sendProblem = nil
        guard let content, let choice, let drop else { return false }
        guard let message = ShareMessage.compose(instructions: instructions, content: content) else {
            sendProblem = "Nothing here can be sent."
            return false
        }
        // The message's words are held to the engine's 1 MB from a phone (#924), in its words; the page stays open.
        if let tooLong = TypedTextLimit.refusal(message.text) {
            sendProblem = tooLong
            return false
        }
        let draft = ShareDraft(writtenAt: now(), destination: choice, text: message.text, attachments: message.attachments)
        guard draft.encodedSize <= ShareLimits.messageBytes else {
            sendProblem = "This is too large to send in one message. Share less of it at a time."
            return false
        }
        do {
            try drop.add(draft)
        } catch {
            sendProblem = error.localizedDescription
            return false
        }
        drop.rememberLast(choice.conversation)
        return true
    }
}
