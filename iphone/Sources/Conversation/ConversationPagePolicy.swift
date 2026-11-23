import Foundation
import PiModels
import TranscriptKit

/// What the phone does with a message from the transcript page (docs/iphone.md section 8; docs/transcript.md, "On a
/// phone"). The page shows what agents wrote, so whatever it posts is believed only as far as this goes: **no message
/// from the page acts through the engine.** Answers, messages and stops are made only by the screen's own controls,
/// outside the page. Two reads of this same conversation are the only requests a page message leads to, as the owner
/// decided for #687: its older entries (`conversation.older`) and one of its entries' pictures (`conversation.image`),
/// each checked against what the conversation holds before it is asked. Any other would have to be a new case here,
/// read in review.
enum ConversationPageResponse: Equatable {
    /// The page has loaded: send it the whole conversation.
    case sendEverything
    /// Put this text on the pasteboard.
    case copy(String)
    /// Open this web or mail address, once the person has confirmed it (section 8).
    case confirmLink(URL)
    /// Show this sub-chat, which one of the conversation's hand-offs opened, on its own screen, by its route: that
    /// screen opens it, as from Now or Agents (docs/design/iphone.md, "An agent's conversation").
    case openConversation(Int)
    /// Ask the engine for the entries before those the page has (`conversation.older`): a read of this conversation.
    case loadOlder
    /// Ask the engine for one of an entry's pictures (`conversation.image`) and hand it to the page: a read of this
    /// conversation, for an entry that holds that many pictures.
    case fetchPicture(entry: Int, index: Int)
    /// A short line at the foot of the page, saying where to do what was asked.
    case notice(String)
    /// Nothing to do.
    case ignore
}

enum ConversationPagePolicy {
    /// What a checked message from the page leads to. `subChats` are the conversations this conversation's hand-offs
    /// opened, as the engine named them; the page may ask to show only those. `items` are the entries the client has,
    /// which a picture asked for must be among.
    static func response(to action: TranscriptAction, subChats: Set<Int>, items: [Item] = []) -> ConversationPageResponse {
        switch action {
        case .ready:
            return .sendEverything
        case .copy(let text):
            return .copy(text)
        case .openLink(let url):
            return .confirmLink(url)
        case .openChat(let id, _):
            // Beside has no meaning on a phone: one screen at a time.
            return subChats.contains(id) ? .openConversation(id) : .ignore
        case .picture(let entry, let index):
            guard let item = items.first(where: { $0.id == entry }), index < (item.images ?? 0) else { return .ignore }
            return .fetchPicture(entry: entry, index: index)
        case .older:
            // Whether there is more, and whether a part is on its way, is the client's to say (`loadOlder`).
            return .loadOlder
        case .decide, .answer, .answerNeed:
            // The page is sent no cards to answer on the phone; what waits is answered under Needs you.
            return .notice("Answer it under Needs you, above the message field.")
        case .undo:
            return .notice("Undo a change on the Mac for now.")
        case .fork:
            return .notice("Fork from here is on the Mac for now.")
        case .retry, .edit, .version:
            return .notice("Trying again and editing a message are on the Mac for now.")
        case .save, .savePicture, .openDocument, .saveDocument:
            return .notice("Saving to a file is on the Mac for now.")
        case .showFile:
            return .notice("That file is on your Mac.")
        case .output:
            return .notice("A background command’s output opens on the Mac for now.")
        case .fileMenu:
            // A right-click on the Mac; a phone has none.
            return .ignore
        }
    }

    /// The conversations this one's hand-offs opened, as their calls' results (or the live state) name them: the only
    /// ones the page may ask to show. Never an id an agent wrote in its text.
    static func subChats(items: [Item], state: ConversationState?) -> Set<Int> {
        var ids = Set<Int>()
        for item in items where item.kind == "tool" && item.name == "delegate" {
            if let id = item.details?["conversationId"]?.intValue { ids.insert(id) }
        }
        for tool in state?.tools ?? [] where tool.name == "delegate" {
            if let id = tool.details?["conversationId"]?.intValue { ids.insert(id) }
        }
        return ids
    }

    /// The changes made in this conversation, as the page draws their lines, without Undo: an Undo pressed in the page
    /// would be a request made from the page. Each says to undo it on the Mac.
    static func changesWithoutUndo(_ changes: [ProjectChangeLine]) -> [ProjectChangeLine] {
        guard !changes.isEmpty, let data = try? JSONEncoder().encode(changes),
              var lines = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        for index in lines.indices where lines[index]["canUndo"] as? Bool == true {
            lines[index]["canUndo"] = false
            lines[index]["noUndo"] = "undo it on the Mac"
        }
        guard let changed = try? JSONSerialization.data(withJSONObject: lines),
              let result = try? JSONDecoder().decode([ProjectChangeLine].self, from: changed) else { return [] }
        return result
    }
}
