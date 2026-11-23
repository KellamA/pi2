import Foundation

/// What a share may carry: the engine's limits on a message's attachments (`engine/src/attachments.ts`, the Mac's
/// `AttachmentLimits`), the phone's line, and the mailbox's longest message.
enum ShareLimits {
    /// The most attachments a message carries.
    static let attachments = 10
    /// The engine takes pictures of at most 5 MB each.
    static let pictureBytes = 5 * 1024 * 1024
    /// Pictures are scaled down until their longer side is at most this many pixels, as on the Mac.
    static let pictureSide = 2000
    /// An attached text, counted as the engine counts it, in UTF-16 units.
    static let textCharacters = 400_000
    /// Shared text longer than either of these goes as an attachment, as a long paste does in the Mac's message field.
    static let inlineCharacters = 4_000
    static let inlineLines = 60
    /// The phone's line to its Mac holds 16 MiB; a shared message's parameters are kept under 15 MiB, leaving room for
    /// the request around them and the channel's framing.
    static let messageBytes = 15 * 1024 * 1024
    /// The longest message the relay's mailbox carries (docs/iphone.md 4.2): a share of words alone, no longer, may wait
    /// in the Outbox while the Mac is out of reach.
    static let mailboxCharacters = 4_000
    /// How long a draft waits for the app to hand it to the Mac before it is marked too late, as an Outbox message.
    static let draftLifetime: TimeInterval = 86_400
    /// The most drafts the shared folder holds at once.
    static let drafts = 10
}

/// Something that goes with a shared message, in the form `submit` takes (`attachments`).
enum ShareAttachment: Codable, Equatable, Sendable {
    /// A picture, already scaled and encoded (`SharePictureReader`).
    case picture(name: String, mimeType: String, data: Data)
    /// A text: a long shared text, or a file's text.
    case text(name: String, text: String)

    var name: String {
        switch self {
        case .picture(let name, _, _), .text(let name, _): name
        }
    }

    var isPicture: Bool {
        if case .picture = self { true } else { false }
    }

    /// As `submit` takes it, as the Mac sends it (`PreparedAttachment`).
    var payload: [String: Any] {
        switch self {
        case .picture(let name, let mimeType, let data):
            ["kind": "image", "name": name, "mimeType": mimeType, "data": data.base64EncodedString()]
        case .text(let name, let text):
            ["kind": "text", "name": name, "text": text]
        }
    }
}

/// A message the share extension made, for the app to send (docs/iphone-app.md, "The extensions"). The extension has
/// no connection to the Mac of its own, so it writes the draft into the shared folder (`ShareDrop`), and the app picks
/// it up as it starts and each time it comes back to the front (`SharePickup`): it sends it to the Mac when it can reach
/// it, and puts one of words alone into the Outbox when it cannot.
///
/// Its `id` is made once, when it is written, and is the message's `requestId`: the engine knows a message by it, so a
/// draft handed over twice (the app stopped mid-send, an answer lost) is still one message.
struct ShareDraft: Codable, Identifiable, Equatable, Sendable {
    enum State: Codable, Equatable, Sendable {
        /// Not handed to the Mac yet.
        case waiting
        /// Not sent, with why: the Mac refused it, or it waited too long. It stays for the app to show until dismissed.
        case notSent(String)
    }

    let id: String
    let writtenAt: Date
    /// Where it goes, as the person chose it.
    let destination: ShareDestination
    /// The message: the person's instructions, then the links and short texts shared.
    let text: String
    let attachments: [ShareAttachment]
    var state: State

    init(id: String = UUID().uuidString, writtenAt: Date, destination: ShareDestination, text: String, attachments: [ShareAttachment], state: State = .waiting) {
        self.id = id
        self.writtenAt = writtenAt
        self.destination = destination
        self.text = text
        self.attachments = attachments
        self.state = state
    }

    /// The parameters of the `submit` that sends it: queued behind what the agent is doing (`followUp`, the engine's
    /// default), never steering it.
    var submitParameters: [String: Any] {
        var params: [String: Any] = ["id": destination.conversation, "text": text, "requestId": id]
        if !attachments.isEmpty { params["attachments"] = attachments.map(\.payload) }
        return params
    }

    /// Whether it may wait in the Outbox, and so in the relay's mailbox, while the Mac is out of reach: words alone, at
    /// most 4,000 characters (docs/iphone.md 4.2). One with a picture or a file waits in the shared folder instead.
    var mayWaitInMailbox: Bool {
        attachments.isEmpty && text.count <= ShareLimits.mailboxCharacters
    }

    func isExpired(at date: Date) -> Bool {
        date.timeIntervalSince(writtenAt) > ShareLimits.draftLifetime
    }

    /// What a list shows of it: its words, or what it carries.
    var summary: String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { return String(words.prefix(200)) }
        return attachments.map(\.name).joined(separator: ", ")
    }

    /// The size of its `submit` parameters as JSON, as the line carries them.
    var encodedSize: Int {
        (try? JSONSerialization.data(withJSONObject: submitParameters))?.count ?? Int.max
    }

    static let tooLate = "Not sent: more than a day passed before pi² could take it to your Mac. Share it again if it still matters."
}

/// What the person shared, put together with their instructions into one message (`ShareDraft`'s text and attachments),
/// as the Mac's message field puts a long paste and attached files around what was typed.
enum ShareMessage {
    /// The message's words and attachments; nil when there is nothing to send.
    static func compose(instructions: String, content: ShareContent) -> (text: String, attachments: [ShareAttachment])? {
        var parts: [String] = []
        let typed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append(typed) }
        var attachments: [ShareAttachment] = []
        var texts = 0
        for piece in content.pieces {
            switch piece {
            case .link(let url, let title):
                if let title, !title.isEmpty, title != url.absoluteString {
                    parts.append("\(title)\n\(url.absoluteString)")
                } else {
                    parts.append(url.absoluteString)
                }
            case .text(let text):
                if inline(text) {
                    parts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    texts += 1
                    attachments.append(.text(name: texts == 1 ? "Shared text" : "Shared text \(texts)", text: text))
                }
            case .file(let name, let text):
                attachments.append(.text(name: name, text: text))
            case .picture(let picture):
                attachments.append(.picture(name: picture.name, mimeType: picture.mimeType, data: picture.data))
            case .problem:
                break
            }
        }
        let text = parts.joined(separator: "\n\n")
        guard !text.isEmpty || !attachments.isEmpty else { return nil }
        return (text, attachments)
    }

    /// Whether shared text goes in the message itself rather than as an attachment.
    static func inline(_ text: String) -> Bool {
        text.count <= ShareLimits.inlineCharacters && text.split(separator: "\n", omittingEmptySubsequences: false).count <= ShareLimits.inlineLines
    }
}
