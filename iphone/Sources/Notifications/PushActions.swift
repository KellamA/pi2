import Foundation
import PiModels
import UIKit
import UserNotifications

/// What a notification's button does (docs/iphone.md section 7, 4.5): iOS has opened pi² on the card
/// (`PhoneSurfaces.pushTapped` routed there), Face ID is asked if no session is open, and once the card's need is in
/// front of the phone — the engine's list, live or the store's last state — the button sends what the card's own
/// button sends (`PushReply`). Nothing is answered from the notification itself: a card whose need is gone, whose kind
/// no longer matches, or whose call the card does not show whole opens and answers nothing.
///
/// **Delivering in the background** (section 7, steps 2 to 5): the send is wrapped in a background task, so the person
/// can leave pi² at once. On the channel the engine's answer ends it. While the Mac is out of reach the Outbox keeps
/// the answer, and `mailbox` — the phone's relay path, where there is one — seals it into the Mac's mailbox, where it
/// waits up to its lifetime; what neither could take tells the person once, and stays in the Outbox to go when a
/// session next reaches the Mac. Nothing here keeps state: the Outbox and the store are #692's.
@MainActor
enum PushActions {
    /// How long the runner waits for Face ID to open the session: the person tapped the button, and Face ID's own
    /// prompt has no time limit, but a phone nobody answers must not leave a task waiting for ever.
    static let faceIDLimit: Duration = .seconds(30)
    /// How long it waits for the card's need once a session is open: the greeting on an attached channel, or the
    /// store's last state, is there within seconds; a Mac that cannot be reached takes the connection's own backoff
    /// first, which this does not wait past — the card is on screen either way.
    static let cardLimit: Duration = .seconds(10)
    /// How long the mailbox put waits for the relay to be ready (section 7: the connection is given four seconds).
    static let relayLimit: Duration = .seconds(4)

    /// Answers `response` when it carries a button that acts; a tap and **Open** answer nothing.
    static func run(
        _ response: PushResponse, session: AppSession, isOpen: @MainActor () -> Bool,
        outbox: Outbox?, mailbox: (any OutboxCourier)?,
        takeAway: @MainActor (Set<String>) async -> Void,
        tell: (@MainActor (String) async -> Void)? = nil,
        faceIDWithin: Duration? = nil, cardWithin: Duration? = nil
    ) async {
        guard let action = response.action, action != .open, let needID = response.need, !needID.isEmpty else { return }
        let time = BackgroundTime()
        time.begin()
        defer { time.end() }
        // Face ID opens the session (the presence gate asks as pi² comes to the foreground); nothing is answered
        // before it has.
        let open = await wait(faceIDWithin ?? faceIDLimit, isOpen)
        guard open else { return }
        // The card, whole: the need is in the engine's list, live or from the store's last state. The route is
        // already on it; this is the card's own data to answer from.
        let card = await wait(cardWithin ?? cardLimit) { session.engine.needs.contains { $0.id == needID } }
        guard card, let need = session.engine.needs.first(where: { $0.id == needID }) else { return }
        let inbox = session.engine.inbox.first { $0.id == need.id && $0.kind == need.kind }
        guard let reply = PushReply.reply(for: response, of: need, inbox: inbox) else { return }
        // Allow once acts only after the card has shown the whole call (4.5): the notification offered it only when
        // the Mac said the call is shown whole, and the card agrees here.
        if action == .allowOnce, !PushReply.showsWholeCall(need, inbox: inbox) { return }
        let agent = need.agentName
        let outcome = await NeedAnswering.deliver(reply, to: need.id, through: session.engine)
        switch outcome {
        case .taken, .held:
            await takeAway([need.id])
        case .kept:
            // The Mac is out of reach: the Outbox keeps the answer, and what may wait in the mailbox goes to it
            // now, sealed, rather than wait for a session that may not come (section 7, step 4).
            guard let outbox, let mailbox else { return }
            let mine = outbox.items.last(where: { item in
                item.kind == .answer && item.isPending && item.parameters["id"] as? String == need.id
            })
            guard let item = mine else { return }
            let report = await outbox.send(through: mailbox)
            let line = "Your answer to \(agent ?? "your Mac") is not sent yet. pi² will send it when it can reach your Mac."
            if report.inMailbox.contains(item.id) {
                await takeAway([need.id])
            } else if let tell {
                // Not even the mailbox: said once (section 7, step 5), and the Outbox entry stays, to go when a
                // session next reaches the Mac.
                await tell(line)
            } else {
                await tellOnce(line)
            }
        case .refused:
            // The engine refused the answer in its own words; the person answers by hand on the card and sees why.
            break
        }
    }

    /// Polls `condition` every fiftieth of a second until it holds or `limit` is past.
    private static func wait(_ limit: Duration, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// The one line the person is told when nothing took the answer (section 7, step 5): a local notification, shown
    /// once, whatever iOS's settings for pi² allow.
    private static func tellOnce(_ words: String) async {
        let content = UNMutableNotificationContent()
        content.title = "pi²"
        content.body = words
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "pi2.not-sent." + UUID().uuidString, content: content, trigger: nil))
    }
}

/// iOS's time to finish in the background (section 7, step 2): begun while the answer is delivered, ended after, so
/// that the person can leave pi² at once and the answer still goes. iOS's own limit holds; nothing here asks for more.
@MainActor
private final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "pi2 notification action")
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
