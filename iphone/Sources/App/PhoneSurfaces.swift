
import EngineKit
import Foundation
import Observation
import os
import PiModels
import RemoteKit

/// What pi² shows of the Mac outside its own screens, kept in step with the one session (docs/iphone-app.md, "The
/// widgets", "The extensions", "Pushes", "The Live Activity"; #901): the widgets' file, and where a tap on a widget
/// opens the app; the share sheet's list of where a share can go, and the drafts it left, sent.
///
/// The share sheet's drafts are picked up as the app comes to the foreground and as a session Face ID opened reaches its
/// Mac or the store's last state, and the conversation the newest went to is opened if it was shared moments ago.
///
/// A notification's tap opens its card's screen (`AppNotifications`); a need the Mac no longer lists takes its
/// notifications away, and so does the end of the pairing, with the service extension's own file (`PushInbox`).
///
/// The followed projects' Live Activities (`activities`) are brought in line as the app comes to the foreground and as
/// the Mac's numbers change while it is in front, and all ended when the pairing ends; a tap on one opens its hub.
///
/// It follows the session's state itself (`withObservationTracking`), not a view, so that it keeps the widgets in step
/// while iOS has pi² running in the background with no scene, as for a Shortcut. What is written for an extension goes
/// in the app group's container, which an unsigned build does not have (#682): there each write does nothing.
@MainActor
@Observable
final class PhoneSurfaces {
    let session: AppSession
    @ObservationIgnored let widgets: WidgetsPublisher
    /// The projects whose Live Activity the person turned on, which a project's settings switch.
    let activities: ProjectActivityFollowing
    /// Whether the app is in the foreground: only then may a Live Activity be started.
    @ObservationIgnored private(set) var inForeground = false
    /// The share extension's folder: nil without the app group (#682), as in an unsigned build.
    @ObservationIgnored let share: ShareDrop?
    /// How a draft from the share sheet can go now: on the channel, into the Outbox, or not at all.
    @ObservationIgnored private let shareWay: @MainActor () -> AppShareSender.Way
    @ObservationIgnored private let shareSender: AppShareSender
    /// The list last written for the share sheet, dated `.distantPast`, so that a change is told from the time moving on.
    @ObservationIgnored private var sharedList: ShareDestinations?
    @ObservationIgnored private var lastShareWay: AppShareSender.Way = .none
    /// Takes away the notifications of needs that are gone (`PushRemoval.takeAway`).
    @ObservationIgnored private let takeAway: @MainActor (Set<String>) async -> Void
    /// Makes the app's notification delegate and categories current again, when the demo (which sets its own) is left.
    @ObservationIgnored private let notificationsBack: @MainActor () -> Void
    /// Answers a notification's button, once its card is open (`PushActions`); a tap answers nothing.
    @ObservationIgnored private let answer: @MainActor (PushResponse) async -> Void
    /// The service extension's file, wiped when the pairing ends: nil without the app group (#682).
    @ObservationIgnored private let pushInbox: PushInbox?
    /// The needs the Mac listed when last connected, to tell which went.
    @ObservationIgnored private var lastNeeds: Set<String>?
    /// Whether a Mac is paired (`PhoneLink.paired`): nothing of the Mac is written for an extension before pairing.
    @ObservationIgnored private let paired: @MainActor () -> Bool
    /// When the phone last heard from its Mac (`PhoneStore.lastHeard`), for the widgets' "Updated" while out of reach.
    @ObservationIgnored private let lastHeard: @MainActor () -> Date?
    @ObservationIgnored private let log = Logger(subsystem: "dev.pi2.ios", category: "surfaces")

    /// A screen asked for from outside the app's own screens (a widget, a notification, a Live Activity), which the root
    /// opens once Face ID has opened the session, then sets back to nil.
    var pendingRoute: Route?

    /// The last connection seen, so that what happens on a change (the demo starting) happens once.
    @ObservationIgnored private var lastConnection: AppSession.Connection?

    init(
        session: AppSession,
        widgets: WidgetsPublisher = WidgetsPublisher(),
        share: ShareDrop? = ShareDrop.inAppGroup(),
        paired: @escaping @MainActor () -> Bool,
        lastHeard: @escaping @MainActor () -> Date?,
        shareWay: @escaping @MainActor () -> AppShareSender.Way = { .none },
        keep: @escaping @MainActor (_ method: String, _ params: [String: Any]) throws -> Void = { _, _ in throw StoreError("Open pi² with Face ID first.") },
        pushInbox: PushInbox? = nil,
        takeAway: @escaping @MainActor (Set<String>) async -> Void = { _ in },
        notificationsBack: @escaping @MainActor () -> Void = {},
        answer: @escaping @MainActor (PushResponse) async -> Void = { _ in },
        activityControl: any ProjectActivityControl = SystemProjectActivities(),
        activitiesFile: URL? = ProjectActivityFollowing.standardFile
    ) {
        self.pushInbox = pushInbox
        self.takeAway = takeAway
        self.notificationsBack = notificationsBack
        self.answer = answer
        self.session = session
        self.widgets = widgets
        self.share = share
        self.paired = paired
        self.lastHeard = lastHeard
        self.shareWay = shareWay
        shareSender = AppShareSender(way: shareWay, call: { [weak session] method, params in
            guard let session else { throw EngineError(message: "pi² is closing.", unanswered: true) }
            _ = try await session.engine.call(method, params)
        }, keep: keep)
        // The numbers' time: now while connected, the last time the Mac was heard from out of reach.
        let heardAt: @MainActor () -> Date? = { [weak session] in
            switch session?.connection {
            case .connected: Date()
            case .outOfReach: lastHeard()
            default: nil
            }
        }
        self.activities = ProjectActivityFollowing(session: session, control: activityControl, file: activitiesFile, heardAt: heardAt)
        follow()
    }

    /// The app's own: made with the link's pairing, store and Outbox.
    convenience init(link: PhoneLink) {
        self.init(
            session: link.session,
            paired: { [weak link] in link?.paired ?? false },
            lastHeard: { [weak link] in link?.store.lastHeard },
            shareWay: { [weak link] in link.map(AppShareSender.way(for:)) ?? .none },
            keep: { [weak link] method, params in
                guard let link else { throw StoreError("Open pi² with Face ID first.") }
                _ = try link.outbox.add(method, params)
            },
            pushInbox: PushInbox.shared,
            takeAway: { needs in await PushRemoval.takeAway(needs: needs) },
            notificationsBack: { AppNotifications.shared.install() },
            answer: { [weak link] response in
                guard let link else { return }
                await PushActions.run(
                    response, session: link.session,
                    isOpen: { [weak link] in
                        // A tap is answered only under the session Face ID opened (4.5); with no Mac paired there
                        // is nothing to answer, and the demo asks no Face ID.
                        guard let link else { return false }
                        return !link.paired || link.keyring.session.state == .open
                    },
                    outbox: link.outbox, mailbox: PushMailbox.forLink(link),
                    takeAway: { needs in await PushRemoval.takeAway(needs: needs) })
            }
        )
    }

    // MARK: - Following the session

    /// What the extensions are made from, read in one place so that a change to any of it is seen.
    private struct Seen {
        var connection: AppSession.Connection
        var paired: Bool
        var shareWay: AppShareSender.Way
    }

    private func follow() {
        let seen = withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        changed(seen)
    }

    private func read() -> Seen {
        let e = session.engine
        // Read for the tracking: each one's change is a reason to write the widgets' file again.
        _ = (e.needs, e.activity, e.projects, e.allAgents, e.usage, e.extras["limits"], e.conversations, session.macName)
        return Seen(connection: session.connection, paired: paired(), shareWay: shareWay())
    }

    private func changed(_ seen: Seen) {
        let before = lastConnection
        lastConnection = seen.connection
        if seen.connection == .demo, before != .demo {
            // The demo's values are not the Mac's.
            widgets.clear()
        }
        if before == .demo, seen.connection != .demo { notificationsBack() }
        followNeeds(seen)
        if inForeground, seen.paired, !activities.followed.isEmpty { Task { await activities.reconcile() } }
        if let snapshot = widgetsSnapshot(seen) { widgets.update(snapshot) }
        writeShareList(seen)
        if seen.shareWay != lastShareWay {
            lastShareWay = seen.shareWay
            // A session opened, or the Mac was reached: what the share sheet left can go now.
            if seen.shareWay != .none { Task { await pickUpShares() } }
        }
    }

    // MARK: - Widgets

    /// The widgets' snapshot of what the client holds, while a Mac is paired and the session is connected or out of reach;
    /// nil otherwise (the demo, before pairing, while reaching for the Mac, or out of reach with nothing ever heard).
    private func widgetsSnapshot(_ seen: Seen) -> WidgetsSnapshot? {
        guard seen.paired else { return nil }
        let heardAt: Date
        switch seen.connection {
        case .connected: heardAt = Date()
        case .outOfReach: guard let last = lastHeard() else { return nil }; heardAt = last
        case .notPaired, .demo, .connecting: return nil
        }
        // Nothing from the Mac yet (the client on its way): the file keeps what it had.
        guard session.engine.hasLoadedLibrary else { return nil }
        let e = session.engine
        return WidgetsSnapshot(
            needs: e.needs, activity: e.activity, projects: e.projects, agents: e.allAgents,
            usage: e.usage, limits: e.extras["limits"], heardAt: heardAt, macName: session.macName)
    }

    // MARK: - The share sheet (#702)

    /// Writes the list of where a share can go whenever the Mac's projects or conversations change, while a paired Mac is
    /// connected (never in the demo, nor from the store's last state, which would date an old list as new).
    private func writeShareList(_ seen: Seen) {
        guard let share, seen.paired, case .connected = seen.connection, session.engine.hasLoadedLibrary else { return }
        let e = session.engine
        let list = ShareDestinations.make(projects: e.projects, conversations: e.conversations, macName: session.macName, at: .distantPast)
        guard list != sharedList else { return }
        do {
            try share.writeDestinations(ShareDestinations.make(projects: e.projects, conversations: e.conversations, macName: session.macName, at: Date()))
            sharedList = list
        } catch {
            log.error("The share sheet's list could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// How recently a draft must have been shared for the app to open its conversation once it is sent: the person shared
    /// it and came to pi² to see it go.
    static let sharedJustNow: TimeInterval = 10 * 60

    /// Hands what the share sheet left to the Mac, or to the Outbox while the Mac is out of reach, oldest first, once a
    /// session Face ID opened is open; then opens the conversation the newest went to if it was shared moments ago.
    @discardableResult
    func pickUpShares(through sender: AppShareSender? = nil, now: Date = Date()) async -> SharePickup.Report? {
        guard let share, shareWay() != .none else { return nil }
        let drafts = share.all()
        guard !drafts.isEmpty else { return nil }
        let report = await SharePickup.run(share, through: sender ?? shareSender, now: now)
        let sent = Set(report.taken + report.kept)
        if let newest = drafts.filter({ sent.contains($0.id) }).max(by: { $0.writtenAt < $1.writtenAt }),
           now.timeIntervalSince(newest.writtenAt) <= Self.sharedJustNow {
            pendingRoute = .conversation(newest.destination.conversation)
        }
        if !report.notSent.isEmpty || report.stopped != nil {
            log.notice("Shares: \(report.taken.count) taken, \(report.kept.count) kept, \(report.notSent.count) not sent\(report.stopped.map { ", stopped: \($0)" } ?? "", privacy: .public)")
        }
        return report
    }

    // MARK: - Notifications (#690)

    /// A notification's tap or button: its card's screen, once Face ID has opened the session; a button then answers
    /// once the card is shown (P22, `PushActions`), with no further tap.
    func pushTapped(_ response: PushResponse) {
        pendingRoute = response.route
        Task { await answer(response) }
    }

    /// A need the Mac listed and lists no more (answered here, on the Mac, or withdrawn) takes its notifications away.
    /// Only while connected to the Mac: the store's last state and the demo say nothing of what is gone.
    private func followNeeds(_ seen: Seen) {
        guard seen.paired, case .connected = seen.connection, session.engine.hasLoadedLibrary else {
            lastNeeds = nil
            return
        }
        let now = Set(session.engine.needs.map(\.id))
        defer { lastNeeds = now }
        guard let last = lastNeeds else { return }
        let gone = last.subtracting(now)
        if !gone.isEmpty { Task { await takeAway(gone) } }
    }

    // MARK: - The app's moments

    /// The app came to the foreground: what the share sheet left goes, if a session is open, and the Live Activities are
    /// brought in line with the Mac's numbers (iOS may have ended one, or the person allowed them again).
    func movedToForeground() {
        inForeground = true
        activities.refreshAllowed()
        Task { await pickUpShares() }
        if paired() { Task { await activities.reconcile() } }
    }

    /// The app left the foreground: the widgets show the phone's last state.
    func movedToBackground() {
        inForeground = false
        widgets.flush()
    }

    /// The store was wiped, or the pairing ended (unpaired, revoked, the keys gone): nothing of the Mac stays for an
    /// extension to show, and nothing shared waits to go to it.
    func forgetTheMac() {
        widgets.clear()
        share?.wipe()
        sharedList = nil
    }

    /// The pairing ended (unpaired, revoked, the keys gone): beside what `forgetTheMac` takes away, the service
    /// extension's notices go (3.6).
    func pairingEnded() {
        forgetTheMac()
        lastNeeds = nil
        Task { await activities.endAll() }
        do {
            try pushInbox?.wipe()
        } catch {
            log.error("The notices the service extension kept could not be wiped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The store's sweep at launch and at each return to the foreground: when it wiped the Mac's last state, so does this.
    func swept(_ parts: Set<StorePart>) {
        if parts.contains(.cache) { forgetTheMac() }
    }

    // MARK: - Links from outside

    /// A URL handed to the app (`onOpenURL`): a widget's or a Live Activity's tap. The route waits in `pendingRoute` for
    /// the root to open once Face ID has opened the session. Returns whether the URL was one of pi²'s.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let route = Self.route(for: url) else { return false }
        pendingRoute = route
        return true
    }

    /// The route a URL names: a widget's (`WidgetsLink`), a Live Activity's (`ProjectActivityLink`: the project's hub on
    /// Now), or nil for anything else.
    nonisolated static func route(for url: URL) -> Route? {
        if let link = WidgetsLink(url) { return link.route }
        if let link = ProjectActivityLink(url) { return .project(link.projectID, tab: .now) }
        return nil
    }
}

extension PushMailbox {
    /// The app's own mailbox courier, from the pairing and keys `link` holds, putting through its connection's relay
    /// path (#691): nil's ends when there is nothing to put through — not paired, or no connection this session.
    @MainActor
    static func forLink(_ link: PhoneLink) -> PushMailbox {
        PushMailbox(
            ends: { [weak link] in
                guard let link, let record = link.record, let mac = try? record.mac(),
                      let recordKey = try? link.keyring.keys.recordKey(), let deviceKey = try? link.keyring.keys.deviceKey()
                else { return nil }
                return Ends(
                    pairing: mac.pairing, device: mac.device, macRecordKey: mac.recordKey, recordKey: recordKey,
                    deviceKey: deviceKey, presence: link.keyring.session)
            },
            put: { [weak link] item, id, presence in
                guard let link,
                      let answer = await link.connection?.putInMailbox(item, id: id, presence: presence, within: PushActions.relayLimit),
                      answer else { throw RemoteKitError("mailbox", PushMailbox.unreachable) }
            })
    }
}

extension WidgetsLink {
    /// The app's screen for a widget's link (docs/iphone-app.md, "The widgets"). `.needs` carries the card too, which the
    /// Needs screen does not scroll to yet.
    var route: Route {
        switch self {
        case .needs(let project, _): .needs(project: project)
        case .conversation(let id): .conversation(id)
        case .dashboard(let project): .dashboard(project: project)
        case .usage: .usage
        }
    }
}
