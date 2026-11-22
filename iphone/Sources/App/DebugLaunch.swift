#if DEBUG
import Foundation
import PiModels

/// What a debug build's environment asks of it at launch, so that a screen can be opened with data in it and pictured
/// in the simulator without a tap (docs/iphone-app.md). `xcrun simctl launch` passes `SIMCTL_CHILD_<NAME>` to the app as
/// `<NAME>`. None of it is compiled into a release build.
///
/// - `PI2_TRANSPORT=replay`: connect to the recorded session (`ReplayTransport`).
/// - `PI2_CONNECTION=not-paired | demo | connecting | home | relay | direct | home-relay-down | out-of-reach`: what the
///   connection bar says. With the replay it is `home` unless given; without it, `not-paired`.
/// - `PI2_SHOW=<route>`: the route to open: `home`, `dashboard[:<project>]`, `project:<project>[#chat|now|work|more]`,
///   `conversation:<id>`, `needs[:<project>]`, where `<project>` is a project's name or id; it opens once the project is
///   known. `face-id-check` opens the Face ID check from the first screen (`FirstScreen`).
struct DebugLaunch {
    var transport: String?
    var connection: String?
    var show: String?

    static let current: DebugLaunch? = {
        let environment = ProcessInfo.processInfo.environment
        let launch = DebugLaunch(transport: environment["PI2_TRANSPORT"], connection: environment["PI2_CONNECTION"], show: environment["PI2_SHOW"])
        return launch.transport == nil && launch.connection == nil && launch.show == nil ? nil : launch
    }()

    /// Starts the session as the environment says.
    @MainActor
    func apply(to session: AppSession) {
        let replay = transport == "replay" ? ReplayTransport.recording() : nil
        if transport == "replay", replay == nil {
            session.note("PI2_TRANSPORT=replay, but this build has no recording (session.jsonl) in its bundle.")
        }
        let connection = connection.flatMap(Self.connection(named:)) ?? (replay == nil ? .notPaired : .connected(.home))
        if let replay {
            session.macName = "Recorded Mac"
            session.start(replay, as: connection)
        } else {
            session.connection = connection
        }
    }

    static func connection(named name: String) -> AppSession.Connection? {
        switch name {
        case "not-paired": .notPaired
        case "demo": .demo
        case "connecting": .connecting
        case "home": .connected(.home)
        case "relay": .connected(.relay)
        case "direct": .connected(.direct)
        case "home-relay-down": .connected(.home, relayReachable: false)
        case "out-of-reach": .outOfReach(lastSeen: Date(timeIntervalSinceNow: -40 * 60))
        default: nil
        }
    }

    /// `PI2_SHOW`'s route, once the projects it names are known; nil until then, and for a value that names no route.
    func route(projects: [ProjectRow]) -> Route? {
        show.flatMap { Self.route($0, projects: projects) }
    }

    static func route(_ text: String, projects: [ProjectRow]) -> Route? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : nil
        func project(_ named: String) -> String? {
            projects.first { $0.id == named }?.id ?? projects.first { $0.name == named }?.id
        }
        switch parts.first {
        case "home":
            return .home
        case "dashboard":
            guard let argument else { return .dashboard() }
            return project(argument).map { .dashboard(project: $0) }
        case "needs":
            guard let argument else { return .needs() }
            return project(argument).map { .needs(project: $0) }
        case "conversation":
            return argument.flatMap(Int.init).map { .conversation($0) }
        case "project":
            guard let argument else { return nil }
            let named = argument.split(separator: "#", maxSplits: 1).map(String.init)
            let tab = named.count > 1 ? HubTab(rawValue: named[1]) : .chat
            guard let tab, let id = project(named[0]) else { return nil }
            return .project(id, tab: tab)
        default:
            return nil
        }
    }
}
#endif
