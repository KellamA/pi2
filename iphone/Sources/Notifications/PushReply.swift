import Foundation
import PiModels

/// The answer a notification's button makes (docs/iphone.md section 7): the same one the card's own button sends
/// (`NeedReply`), so that it is the engine, never the phone, that decides what it does (4.2). The response names the
/// button; the card's need, once the app is open on it, names what is answered and what its kind offers (an approval
/// the Inbox holds decides, one a project's switch asked for answers the switch; a held question is answered as the
/// Inbox's, one put with `needs_you` as the Now tab's). A response that names no card, a need of another kind, or a
/// button its kind does not offer answers nothing: the card opens and the person reads it.
///
/// **Allow once is built here, but it acts only through `PushActions`**, which sends nothing before the card has shown
/// the whole call (4.5): a notification offers it only in its whole category, and the runner checks the card again.
enum PushReply {
    /// The reply for `response.action` on `need`, with what the Inbox holds of it; nil for a button that only opens,
    /// a need of another kind, or a button this kind does not offer.
    static func reply(for response: PushResponse, of need: NeedItem, inbox: InboxItem?) -> NeedReply? {
        guard let action = response.action, action != .open else { return nil }
        // A notification acts on the card it came from: its kind must be the need's.
        guard response.kind?.rawValue == need.kind else { return nil }
        switch (action, need.kind) {
        case (.allowOnce, "approval"):
            return need.projectSwitch != nil ? NeedReply.switchApproval(.once) : NeedReply.decide(.once)
        case (.deny, "approval"):
            return need.projectSwitch != nil ? NeedReply.switchApproval(.deny) : NeedReply.decide(.deny)
        case (.reply, "question"):
            guard let text = response.reply?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            // An agent held on its question is answered as the Inbox's card answers it; a question put with
            // `needs_you`, as the Now tab's card does (`NeedCard.question`).
            return need.blocking && inbox != nil ? NeedReply.answerInbox(text) : NeedReply.question(text)
        case (.allow, "reach"):
            return .reach(allow: true)
        case (.refuse, "reach"):
            return .reach(allow: false)
        case (.refuse, "rule"):
            return .refuseRule
        case (.accept, "rule"):
            return .acceptRule()
        case (.startAnyway, "limit"):
            return .limit(start: true)
        case (.wait, "limit"):
            return .limit(start: false)
        default:
            return nil
        }
    }

    /// Whether the card shows an approval's whole call, so that Allow once may act on it: nothing of it was hidden
    /// from the phone (the Mac's mark, and the masks'), as `NeedCard.hidden` reads it. The notification's own
    /// `whole` was checked before it offered the button; this is the card's word, which 4.5 acts on.
    static func showsWholeCall(_ need: NeedItem, inbox: InboxItem?) -> Bool {
        guard need.kind == "approval" else { return false }
        return !NeedHiddenCall.isPartlyHidden(
            mark: (inbox?.isPartlyHidden ?? false) || need.isPartlyHidden, arguments: inbox?.arguments ?? need.arguments)
    }
}
