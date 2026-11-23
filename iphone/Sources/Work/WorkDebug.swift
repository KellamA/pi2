#if DEBUG
import Foundation
import PiModels

/// What a debug build's environment asks the Work screens to do once they show, so that a state reached by a tap can be
/// pictured in the simulator without one (docs/iphone-app.md, "Drawing a screen and picturing it"). Each sends the real
/// request through the same client and shows what the engine answers: against the recorded session, its refusal. None
/// of it is compiled into a release build.
///
/// - `PI2_WORK_ACT=new`: opens New Work on the list. `new:<title>`: with that title, and adds it.
///   `give`: opens Give to an Agent for the first piece nobody has (on a piece's screen, for it). `give:<agent name>`:
///   gives it to that agent. On a piece's screen, `edit` opens its editor, `note:<text>` adds a note, `close` closes it
///   as done.
/// - `PI2_WORK_FILTER=open|waiting|done`: the list's segment.
enum WorkDebugAct {
    static let act = ProcessInfo.processInfo.environment["PI2_WORK_ACT"]
    static let filter = ProcessInfo.processInfo.environment["PI2_WORK_FILTER"].flatMap(WorkFilter.init(rawValue:))

    /// Done once a launch, by the first view that shows.
    @MainActor private static var done: Set<String> = []

    /// Whether `name` was asked for and not done yet; marks it done. `new-send` is `new:<title>`'s second step: adding it.
    @MainActor static func take(_ name: String) -> Bool {
        let asked = name == "new-send" ? argument("new") != nil : (act == name || act?.hasPrefix(name + ":") == true)
        guard asked, !done.contains(name) else { return false }
        done.insert(name)
        return true
    }

    /// What follows `name:` in the act asked for.
    static func argument(_ name: String) -> String? {
        guard let act, act.hasPrefix(name + ":") else { return nil }
        return String(act.dropFirst(name.count + 1))
    }
}

/// Sample listings a debug build draws in place of the Mac's, when `PI2_WORK_SAMPLE` asks, for the states the recorded
/// session has none of: an attached repository's issues and pull requests, GitHub out of reach, its first read, a write
/// of unknown outcome, an empty list, the list not come yet, a start the project's limit held. Plainly sample data: the
/// screen says so at its top, and every request it sends still goes to the engine, which answers for itself. Never in a
/// release build.
///
/// `PI2_WORK_SAMPLE=github | trouble | unknown | first | empty | loading | held`.
enum WorkSample {
    static let current = ProcessInfo.processInfo.environment["PI2_WORK_SAMPLE"]

    /// The sample's listing for `project`, or nil for a name that is no sample. `held` keeps the real listing.
    static func listing(_ name: String, project: ProjectRow, agents: [AgentProfile], real: WorkListing,
                        now: Date = .now) -> WorkListing? {
        let repository = "octo/sample"
        switch name {
        case "held":
            return real
        case "empty":
            return WorkListing(source: .kept, arrived: true, items: [])
        case "loading":
            return WorkListing(source: .kept, arrived: false, items: [])
        case "first":
            return WorkListing.github(event(project.id, ["state": "loading", "readAt": nil, "issues": [], "pulls": []]),
                                      project: project.id, repository: repository)
        case "github", "trouble", "unknown":
            var value = github(agents: agents, now: now)
            if name == "trouble" {
                value["state"] = "signed_out"
                value["error"] = "gh: not logged in"
                value["readAt"] = ms(now.addingTimeInterval(-2 * 3600))
            }
            if name == "unknown" {
                value["unknown"] = [["intent": "merge:619", "summary": "merging pull request #619", "at": ms(now.addingTimeInterval(-600))]]
            }
            return WorkListing.github(event(project.id, value), project: project.id, repository: repository)
        default:
            return nil
        }
    }

    /// A start the daily spending limit held, for `item` and `agent`: the limit itself is the shared reading
    /// (`WorkLimit` in PiModels, #828).
    static func heldStart(item: WorkItem, agent: AgentProfile) -> WorkHeldStart? {
        let reading = WorkLimit(decode(["id": "limit-sample", "limit": "dailySpend", "reason": "$4.90 of today's $5.00 is spent"]))
        return reading.map { WorkHeldStart(item: item, agent: agent, limit: $0) }
    }

    // MARK: - The sample repository

    private static func github(agents: [AgentProfile], now: Date) -> [String: Any?] {
        let first = agents.first?.id ?? "forge"
        let second = agents.dropFirst().first?.id ?? first
        func at(_ minutes: Double) -> Double { ms(now.addingTimeInterval(-minutes * 60)) }
        func issue(_ id: Int, _ title: String, _ state: String, text: String = "", holder: (String, Int)? = nil,
                   modelClass: String? = nil, notes: [(String?, String, Double)] = [], result: String? = nil,
                   changed: Double, partial: Bool = false) -> [String: Any?] {
            [
                "id": id, "title": title, "text": text, "state": state, "class": modelClass,
                "takenBy": holder.map { ["agentId": $0.0, "conversationId": $0.1] },
                "notes": notes.map { ["at": at($0.2), "by": $0.0.map { ["kind": "agent", "agentId": $0] } ?? ["kind": "person"], "text": $0.1] },
                "result": result, "updatedAt": at(changed), "url": "https://github.com/octo/sample/issues/\(id)", "partial": partial,
            ]
        }
        let issues: [[String: Any?]] = [
            issue(621, "Dashboard on narrow windows", "open",
                  text: "The Dashboard's columns overlap below 900 points. Fold them into pages, as the phone does.",
                  modelClass: "local", changed: 12),
            issue(618, "Rules tab: token count", "in_progress", text: "Show how many tokens the rules take, beside their heading.",
                  holder: (second, 214), modelClass: "cloud", changed: 30),
            issue(615, "Archive a project with work open", "waiting",
                  text: "Archiving a project while its agents hold work leaves the work held by nobody who can finish it.",
                  holder: (first, 207), notes: [(first, "Waiting on you: should archiving stop the work, or wait for it to finish?", 45)],
                  changed: 45),
            issue(611, "Usage by project", "blocked", text: "Show each project's spending on the Usage page.",
                  holder: (second, 199), notes: [(second, "Needs #604 first: the engine does not count spending by project yet.", 90)],
                  changed: 90),
            issue(604, "Spending by project in the engine", "done", text: "Count each run's spending against its project.",
                  result: "Merged in #609: every run's cost is kept with its project.", changed: 300),
            issue(600, "An older picture of the board", "dropped", changed: 2000, partial: true),
        ]
        let pulls: [[String: Any?]] = [
            ["number": 619, "title": "Hub: fold the board", "state": "open", "draft": false, "checks": "passing", "failingChecks": [],
             "mergeable": "yes", "findings": [["agentName": "Reviewer", "verdict": "approve", "at": at(8), "url": "", "text": "Folding works at both widths."]],
             "work": 612],
            ["number": 620, "title": "Notes: wrap long lines", "state": "open", "draft": false, "checks": "failing",
             "failingChecks": [["name": "engine", "url": ""]], "mergeable": "yes", "findings": []],
            ["number": 617, "title": "A narrower sidebar", "state": "open", "draft": true, "checks": "pending", "failingChecks": [],
             "mergeable": "unknown", "findings": []],
            ["number": 613, "title": "Fix the badge count", "state": "merged", "draft": false, "checks": "passing", "failingChecks": [],
             "mergeable": "unknown", "findings": []],
        ]
        return ["state": "ok", "readAt": at(3), "reading": false, "issues": issues, "pulls": pulls, "unknown": []]
    }

    private static func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }

    /// The `github` event that carries `value` for one project.
    private static func event(_ project: String, _ value: [String: Any?]) -> JSONValue? {
        decode(["projects": [project: value]])
    }

    private static func decode(_ object: Any) -> JSONValue? {
        guard let data = try? JSONSerialization.data(withJSONObject: clean(object)) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Optionals as JSON's null, for `JSONSerialization`.
    private static func clean(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first.map { clean($0.value) } ?? NSNull()
        }
        if let dictionary = value as? [String: Any?] {
            return dictionary.mapValues { $0.map(clean) ?? NSNull() }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(clean)
        }
        if let array = value as? [Any?] {
            return array.map { $0.map(clean) ?? NSNull() }
        }
        if let array = value as? [Any] {
            return array.map(clean)
        }
        return value
    }
}
#endif
