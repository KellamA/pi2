/// The switches of docs/projects.md 8.1: what each lets a project's orchestrator do without asking, in the Mac's words
/// (app/Sources/pi2/ProjectAgentsTab.swift). The names are the engine's, as `projects.set` takes them. Each is a change a
/// phone may send (docs/iphone.md 4.2, `projects.set`), and the Mac tells the person of one turned on from a phone.
struct ProjectSettingsSwitch: Identifiable {
    let name: String
    let title: String
    let allows: String
    /// What turning it on is confirmed with, when it does not read as the plain line.
    let confirm: String?

    var id: String { name }

    /// What the person is asked when they turn it on: what the orchestrator may then do without asking them.
    var confirmMessage: String {
        let line = confirm ?? allows
        return "The orchestrator may then \(line.prefix(1).lowercased() + line.dropFirst())"
    }

    static let all: [ProjectSettingsSwitch] = [
        .init(name: "startAgents", title: "Start agents", allows: "Hand work to the project's agents, and start them, without asking you.", confirm: nil),
        .init(name: "fileWork", title: "File work", allows: "Add work to the project's list without asking you.", confirm: nil),
        .init(name: "closeWork", title: "Close work", allows: "Mark work finished or closed without asking you.", confirm: nil),
        .init(name: "makeAgents", title: "Make and change agents", allows: "Make, change and remove the project's agents, and update them from their templates, without asking you.", confirm: nil),
        .init(name: "addRules", title: "Add rules", allows: "Add the rules you dictate to the project's rules without asking you.", confirm: nil),
        .init(name: "merge", title: "Merge pull requests", allows: "Merge a pull request through work without asking you.", confirm: nil),
        .init(name: "release", title: "Release", allows: "Nothing pi² does is held back by this switch: it tells the orchestrator to ask you before releasing anything.", confirm: "release what it has made without asking you; nothing pi² does is held back by this switch"),
        .init(name: "passLimits", title: "Go past limits", allows: "Start work past the project's limits without asking you.", confirm: nil),
    ]
}
