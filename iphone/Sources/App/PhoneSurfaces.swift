
import EngineKit
import Foundation
import Observation
import os
import PiModels

/// What pi² shows of the Mac outside its own screens, kept in step with the one session (docs/iphone-app.md, "The
/// widgets", "The share sheet", "Pushes", "The Live Activity"; #901): the widgets' file, and where a tap on a widget
/// opens the app.
///
/// It follows the session's state itself (`withObservationTracking`), not a view, so that it keeps the widgets in step
/// while iOS has pi² running in the background with no scene, as for a Shortcut. What is written for an extension goes
/// in the app group's container, which an unsigned build does not have (#682): there each write does nothing.
@MainActor
@Observable
final class PhoneSurfaces {
    let session: AppSession
    @ObservationIgnored let widgets: WidgetsPublisher
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
        paired: @escaping @MainActor () -> Bool,
        lastHeard: @escaping @MainActor () -> Date?
    ) {
        self.session = session
        self.widgets = widgets
        self.paired = paired
        self.lastHeard = lastHeard
        follow()
    }

    /// The app's own: made with the link's pairing and store.
    convenience init(link: PhoneLink) {
        self.init(session: link.session, paired: { [weak link] in link?.paired ?? false }, lastHeard: { [weak link] in link?.store.lastHeard })
    }

    // MARK: - Following the session

    /// What the extensions are made from, read in one place so that a change to any of it is seen.
    private struct Seen {
        var connection: AppSession.Connection
        var paired: Bool
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
        _ = (e.needs, e.activity, e.projects, e.allAgents, e.usage, e.extras["limits"], session.macName)
        return Seen(connection: session.connection, paired: paired())
    }

    private func changed(_ seen: Seen) {
        let before = lastConnection
        lastConnection = seen.connection
        if seen.connection == .demo, before != .demo {
            // The demo's values are not the Mac's.
            widgets.clear()
        }
        if let snapshot = widgetsSnapshot(seen) { widgets.update(snapshot) }
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

    // MARK: - The app's moments

    /// The app left the foreground: the widgets show the phone's last state.
    func movedToBackground() {
        widgets.flush()
    }

    /// The store was wiped, or the pairing ended (unpaired, revoked, the keys gone): nothing of the Mac stays for an
    /// extension to show.
    func forgetTheMac() {
        widgets.clear()
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

    /// The route a URL names: a widget's (`WidgetsLink`), or nil for anything else.
    nonisolated static func route(for url: URL) -> Route? {
        if let link = WidgetsLink(url) { return link.route }
        return nil
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
