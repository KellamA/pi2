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
///   known. `face-id-check` opens the Face ID check from the first screen (`FirstScreen`). And the next screens':
///   `work:<project>[#<number>]`, `pull-request:<project>#<number>[:<file>]`, `board:<project>[#agents|rules|notes|branches]`,
///   `agent:<id>` (a template) or `agent:<project>#<id>`, `templates`, `project-settings:<project>`, `settings`,
///   `schedules`, `usage`, `conversations[:<project>]`, `archive`, `background-commands[:<id>]`, `new-project`.
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
        /// `<project>[#<rest>]`: the project's id, once it is known, and what follows the `#`.
        func projectAndRest(_ text: String) -> (String, String?)? {
            let named = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return project(named[0]).map { ($0, named.count > 1 ? named[1] : nil) }
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
        case "work":
            guard case let (id, rest)? = argument.flatMap(projectAndRest) else { return nil }
            guard let rest else { return .work(project: id) }
            return Int(rest).map { .work(project: id, item: $0) }
        case "pull-request":
            guard case let (id, rest)? = argument.flatMap(projectAndRest), let rest else { return nil }
            let numbered = rest.split(separator: ":", maxSplits: 1).map(String.init)
            guard let number = Int(numbered[0]) else { return nil }
            return .pullRequest(project: id, number: number, file: numbered.count > 1 ? numbered[1] : nil)
        case "board":
            guard case let (id, rest)? = argument.flatMap(projectAndRest), let page = BoardPage(rawValue: rest ?? "agents") else { return nil }
            return .board(project: id, page: page)
        case "agent":
            guard let argument, !argument.isEmpty else { return nil }
            guard argument.contains("#") else { return .agent(argument) }
            guard case let (id, agent)? = projectAndRest(argument), let agent, !agent.isEmpty else { return nil }
            return .agent(agent, project: id)
        case "project-settings":
            return argument.flatMap(project).map { .projectSettings($0) }
        case "conversations":
            guard let argument else { return .conversations() }
            return project(argument).map { .conversations(project: $0) }
        case "background-commands":
            guard let argument else { return .backgroundCommands() }
            return argument.isEmpty ? nil : .backgroundCommands(output: argument)
        case "templates" where argument == nil: return .templates
        case "settings" where argument == nil: return .settings
        case "schedules" where argument == nil: return .schedules
        case "usage" where argument == nil: return .usage
        case "archive" where argument == nil: return .archive
        case "new-project" where argument == nil: return .newProject
        default:
            return nil
        }
    }
}
#endif
