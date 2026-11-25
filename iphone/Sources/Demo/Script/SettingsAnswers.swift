import Foundation

/// A project's settings and limits, the app's settings a phone may change, and schedules, answered in the demo (#697) as
/// the engine answers them: `projects.ts` (`projects.delete`; `.set`, `.rename` and `.archive` are `ProjectAnswers.swift`'s,
/// `.unarchive` with `settings.setAutoArchive` `ConversationsAnswers.swift`'s), `github.ts` (`github.attach`, `.detach`),
/// `keepawake.ts`
/// (`settings.setAwake`), `settingsrequests.ts` (`settings.setCompaction`, `chat.set`), `coauthor.ts` (`coauthor.set`) and
/// `scheduleruns.ts` with `schedules.ts` (`schedules.save`, `.delete`, `.runNow`, which starts a conversation with the
/// schedule's agent on its prompt, answered by the demo model). Each checks what the engine checks, refuses in its words,
/// changes the event the engine sends again, and answers what it answers. An agent's model and summary size are saved
/// with `agents.save`, `Script/AgentAnswers.swift`'s.
extension DemoScript {
    static let settings: [String: DemoAnswer] = [
        // MARK: A project
        "projects.delete": { request, world in
            let id = try DemoSettings.projectID(request)
            try DemoSettings.lifecycle(id, in: world, checkBusy: true) { project in
                project["deletedAt"] = world.now
            }
            // Its agents' schedules are held, as the engine holds them.
            let agents = Set(DemoSettings.agents(world).filter { $0["projectId"] as? String == id }.compactMap { $0["id"] as? String })
            if DemoSettings.schedules(world).contains(where: { agents.contains($0["agentId"] as? String ?? "") }) {
                world.change("schedules") { event in
                    event["schedules"] = DemoSettings.schedules(world).map { schedule in
                        guard agents.contains(schedule["agentId"] as? String ?? "") else { return schedule }
                        var held = schedule
                        held["holdReason"] = DemoSettings.projectDeleted
                        return held
                    }
                }
            }
            return [:]
        },
        "github.attach": { request, world in
            let id = try DemoSettings.projectID(request, key: "projectId")
            _ = try DemoSettings.project(id, in: world)
            guard let given = request.params["repository"], !(given is NSNull) else {
                throw DemoRefusal("This folder's origin remote is not on GitHub. Name the repository as owner/name.")
            }
            guard let text = given as? String, text.split(separator: "/").count == 2 else { throw DemoRefusal("repository must be owner/name") }
            throw DemoRefusal("The demo cannot reach GitHub to check \(text): nothing was attached. On a Mac paired with this iPhone, pi² attaches it.")
        },
        "github.detach": { request, world in
            let id = try DemoSettings.projectID(request, key: "projectId")
            try DemoSettings.changeProject(id, in: world) { project, _ in project["repository"] = NSNull() }
            return [:]
        },

        // MARK: The app's settings
        "settings.setAwake": { request, world in
            for key in ["keep", "battery"] where request.params[key] != nil && !DemoSettings.isBool(request.params[key]) {
                throw DemoRefusal("\(key) must be true or false")
            }
            var answer: [String: Any] = [:]
            world.change("awake") { event in
                for key in ["keep", "battery"] { if let value = request.params[key] { event[key] = value } }
                answer = ["keep": event["keep"] ?? true, "battery": event["battery"] ?? false]
            }
            return answer
        },
        "settings.setCompaction": { request, world in
            let given = request.params["defaultCompactionTokens"]
            var value: Any = NSNull()
            if let given, !(given is NSNull) {
                guard let number = given as? NSNumber, !DemoSettings.isBool(given), number.doubleValue == Double(number.intValue), number.intValue >= 1 else {
                    throw DemoRefusal("The size for summarizing must be a whole number of tokens, 1 or more, or unset.")
                }
                value = number.intValue
            } else if given == nil {
                throw DemoRefusal("The size for summarizing must be a whole number of tokens, 1 or more, or unset.")
            }
            world.change("compactionSettings") { event in event["defaultCompactionTokens"] = value }
            return ["defaultCompactionTokens": value]
        },
        "coauthor.set": { request, world in
            if let enabled = request.params["enabled"], !DemoSettings.isBool(enabled) { throw DemoRefusal("enabled must be true or false") }
            let line = try request.params["line"].map(DemoSettings.checkCoauthorLine)
            var answer: [String: Any] = [:]
            world.change("coauthor") { event in
                if let enabled = request.params["enabled"] { event["enabled"] = enabled }
                if let line { event["line"] = line }
                answer = ["line": event["line"] ?? ""]
            }
            return answer
        },
        "chat.set": { request, world in
            var next = world.event("chat") ?? ["event": "chat"]
            if let instructions = request.params["instructions"] {
                guard let text = instructions as? String else { throw DemoRefusal("instructions must be text") }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 20_000 { throw DemoRefusal("The chat instructions can be 20,000 characters at most; these are \(trimmed.count.formatted())") }
                next["instructions"] = trimmed
            }
            if let model = request.params["defaultModel"] {
                if model is NSNull {
                    next["defaultModel"] = NSNull()
                } else {
                    guard let ref = model as? [String: Any], ref["provider"] is String, ref["modelId"] is String else {
                        throw DemoRefusal("defaultModel must be { provider, modelId }, or null for the model used last in a chat")
                    }
                    guard DemoSettings.knownModel(ref, in: world) else { throw DemoRefusal("Unknown model: \(ref["provider"] ?? "")/\(ref["modelId"] ?? "")") }
                    next["defaultModel"] = ["provider": ref["provider"] ?? "", "modelId": ref["modelId"] ?? ""]
                }
            }
            for key in ["web", "memory"] {
                guard let value = request.params[key] else { continue }
                guard DemoSettings.isBool(value) else { throw DemoRefusal("\(key) must be true or false") }
                next[key] = value
            }
            world.change("chat") { event in event = next }
            var answer = next
            answer.removeValue(forKey: "event")
            return answer
        },

        // MARK: Schedules
        "schedules.save": { request, world in
            let input = request.params["schedule"] as? [String: Any] ?? [:]
            let title = (input["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = (input["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { throw DemoRefusal("Give the schedule a name") }
            if prompt.isEmpty { throw DemoRefusal("Write what the agent should do") }
            guard let agentID = input["agentId"] as? String, let agent = DemoSettings.agents(world).first(where: { $0["id"] as? String == agentID }) else {
                throw DemoRefusal("Choose an agent")
            }
            let rule = try DemoSettings.checkRepeat(input["repeat"])
            let previous = (input["id"] as? String).map { id in DemoSettings.schedules(world).first { $0["id"] as? String == id } }
            if let previous, previous == nil { throw DemoRefusal("Unknown schedule: \(input["id"] ?? "")") }
            let old = previous ?? nil
            let now = world.now
            let enabled = input["enabled"] as? Bool ?? old?["enabled"] as? Bool ?? true
            let next = DemoSettings.nextRun(rule, after: now)
            if rule["kind"] as? String == "once", next == nil, enabled { throw DemoRefusal("That time has already passed") }
            if let project = agent["projectId"] as? String,
               DemoSettings.projects(world).first(where: { $0["id"] as? String == project })?["deletedAt"] != nil {
                throw DemoRefusal(DemoSettings.projectDeleted)
            }
            let id = input["id"] as? String ?? "s\(String(Int(now), radix: 36))\(String(Int.random(in: 0..<1_000_000), radix: 36))"
            var schedule: [String: Any] = [
                "id": id, "title": title, "agentId": agentID, "prompt": prompt, "repeat": rule,
                "enabled": enabled && next != nil, "nextRunAt": next.map { $0 as Any } ?? NSNull(),
                "lastRunAt": old?["lastRunAt"] ?? NSNull(), "lastConversationId": old?["lastConversationId"] ?? NSNull(),
                "pending": NSNull(), "createdAt": old?["createdAt"] ?? now,
            ]
            if let createdBy = old?["createdBy"] { schedule["createdBy"] = createdBy }
            if let copy = old?["projectAgentId"], old?["agentId"] as? String == agentID { schedule["projectAgentId"] = copy }
            world.change("schedules") { event in
                var all = (event["schedules"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != id }
                all.append(schedule)
                event["schedules"] = all.sorted { ($0["createdAt"] as? Double ?? 0) < ($1["createdAt"] as? Double ?? 0) }
            }
            return ["id": id]
        },
        "schedules.runNow": { request, world in
            let id = try request.requireString("id")
            guard let schedule = DemoSettings.schedules(world).first(where: { $0["id"] as? String == id }) else { throw DemoRefusal("Unknown schedule: \(id)") }
            if let held = schedule["holdReason"] as? String { throw DemoRefusal(held) }
            let agent = try DemoAgents.agent(schedule["agentId"] as? String, world: world)
            let conversation = try DemoLibrary.startWith(agent, title: schedule["title"] as? String ?? "", world: world)
            world.change("schedules") { event in
                event["schedules"] = DemoSettings.schedules(world).map { each in
                    guard each["id"] as? String == id else { return each }
                    var ran = each
                    ran["lastRunAt"] = world.now
                    ran["lastConversationId"] = conversation
                    return ran
                }
            }
            let prompt = schedule["prompt"] as? String ?? ""
            DemoReplies.take(DemoReplies.Message(submission: world.newSubmissionID(), text: prompt, mode: "queue"), in: conversation, world: world)
            return ["conversationId": conversation]
        },
        "schedules.delete": { request, world in
            let id = try request.requireString("id")
            world.change("schedules") { event in
                event["schedules"] = (event["schedules"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != id }
            }
            return [:]
        },
    ]
}

/// The engine's checks and words the settings' answers share.
@MainActor
enum DemoSettings {
    static let archived = "This project is archived. Restore it first."
    static let projectDeleted = "This agent’s project was deleted. Choose another agent."
    static let stopFirst = "Stop the project's agents first."

    static func projects(_ world: DemoWorld) -> [[String: Any]] { world.event("projects")?["projects"] as? [[String: Any]] ?? [] }
    static func agents(_ world: DemoWorld) -> [[String: Any]] { world.event("agents")?["agents"] as? [[String: Any]] ?? [] }
    static func schedules(_ world: DemoWorld) -> [[String: Any]] { world.event("schedules")?["schedules"] as? [[String: Any]] ?? [] }

    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func projectID(_ request: DemoRequest, key: String = "id") throws -> String {
        guard let id = request.string(key) else { throw DemoRefusal("\(key) must be a project's id") }
        return id
    }

    /// A project that exists and was not deleted (`live`).
    static func project(_ id: String, in world: DemoWorld) throws -> [String: Any] {
        guard let project = projects(world).first(where: { $0["id"] as? String == id }), project["deletedAt"] == nil else {
            throw DemoRefusal("Unknown project: \(id)")
        }
        return project
    }

    /// Changes project `id` as `applyProjectChange` does: refused while it is archived; the `projects` event sent again.
    static func changeProject(_ id: String, in world: DemoWorld, _ body: (inout [String: Any], [[String: Any]]) throws -> Void) throws {
        var project = try project(id, in: world)
        if project["archivedAt"] != nil { throw DemoRefusal(archived) }
        try body(&project, projects(world))
        project["updatedAt"] = world.now
        replace(project, in: world)
    }

    /// Archives, restores or deletes project `id`, refused while its agents work, as the engine's `lifecycle` does.
    static func lifecycle(_ id: String, in world: DemoWorld, checkBusy: Bool, _ body: (inout [String: Any]) -> Void) throws {
        var project = try project(id, in: world)
        if checkBusy, busy(id, in: world) { throw DemoRefusal(stopFirst) }
        body(&project)
        project["updatedAt"] = world.now
        replace(project, in: world)
    }

    private static func replace(_ project: [String: Any], in world: DemoWorld) {
        world.change("projects") { event in
            event["projects"] = (event["projects"] as? [[String: Any]] ?? []).map { $0["id"] as? String == project["id"] as? String ? project : $0 }
        }
    }

    /// Whether something of the project works now: a conversation of it busy, as the library says.
    /// As `projects.archive` in `ProjectAnswers.swift` reads it: a run of it going, or something of it waiting for the person.
    private static func busy(_ id: String, in world: DemoWorld) -> Bool {
        (world.event("activity")?["runs"] as? [[String: Any]] ?? []).contains { $0["projectId"] as? String == id }
            || DemoNeeds.items(world).contains { $0["projectId"] as? String == id }
    }

    /// Whether the `providers` event lists the model `{ provider, modelId }`.
    static func knownModel(_ ref: [String: Any], in world: DemoWorld) -> Bool {
        (world.event("providers")?["models"] as? [[String: Any]] ?? []).contains {
            $0["provider"] as? String == ref["provider"] as? String && $0["id"] as? String == ref["modelId"] as? String
        }
    }

    /// `checkCoauthorLine`.
    static func checkCoauthorLine(_ value: Any) throws -> String {
        let fallback = "Co-authored-by: pi² <noreply@pi2.invalid>"
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw DemoRefusal("Write the line, such as \(fallback)") }
        let line = text.trimmingCharacters(in: .whitespaces)
        if line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x2028 || $0.value == 0x2029 }) {
            throw DemoRefusal("The line must be a single line, with no line breaks or tabs: git reads a trailer one line at a time")
        }
        let prefix = "co-authored-by:"
        guard line.lowercased().hasPrefix(prefix) else { throw DemoRefusal("Start the line with “Co-authored-by:”, the trailer git hosts read as a co-author") }
        let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard let open = rest.lastIndex(of: "<"), rest.hasSuffix(">") else {
            throw DemoRefusal("After Co-authored-by: give a name, then an address in angle brackets, as in \(fallback)")
        }
        let name = rest[..<open].trimmingCharacters(in: .whitespaces)
        let address = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
        guard !name.isEmpty, !name.contains("<"), !name.contains(">"), !address.contains(" ") else {
            throw DemoRefusal("After Co-authored-by: give a name, then an address in angle brackets, as in \(fallback)")
        }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasSuffix("."), !parts[1].hasPrefix(".") else {
            throw DemoRefusal("The address in angle brackets must be of the form name@domain; \(address) is not")
        }
        return "Co-authored-by: \(name) <\(address)>"
    }

    /// `validateRepeat`.
    static func checkRepeat(_ value: Any?) throws -> [String: Any] {
        let rule = value as? [String: Any] ?? [:]
        func int(_ key: String, _ range: ClosedRange<Int>, _ what: String) throws -> Int {
            guard let number = rule[key] as? NSNumber, !isBool(rule[key]), number.doubleValue == Double(number.intValue), range.contains(number.intValue) else {
                throw DemoRefusal("\(what) must be a whole number from \(range.lowerBound) to \(range.upperBound)")
            }
            return number.intValue
        }
        switch rule["kind"] as? String {
        case "once":
            guard let at = (rule["at"] as? NSNumber)?.doubleValue, at.isFinite else { throw DemoRefusal("Pick a date and time") }
            return ["kind": "once", "at": at]
        case "interval":
            return ["kind": "interval", "minutes": try int("minutes", 1...(60 * 24 * 30), "The interval in minutes")]
        case "daily":
            return ["kind": "daily", "hour": try int("hour", 0...23, "The hour"), "minute": try int("minute", 0...59, "The minute")]
        case "weekly":
            return ["kind": "weekly", "weekday": try int("weekday", 0...6, "The weekday"), "hour": try int("hour", 0...23, "The hour"),
                    "minute": try int("minute", 0...59, "The minute")]
        default:
            throw DemoRefusal("Unknown kind of schedule")
        }
    }

    /// `nextRun`: the first run strictly after `after` (milliseconds), in local time; nil when there is none.
    static func nextRun(_ rule: [String: Any], after: Double) -> Double? {
        let calendar = Calendar.current
        switch rule["kind"] as? String {
        case "once":
            let at = rule["at"] as? Double ?? 0
            return at > after ? at : nil
        case "interval":
            return after + Double(rule["minutes"] as? Int ?? 60) * 60_000
        case "daily", "weekly":
            let start = Date(timeIntervalSince1970: after / 1000)
            for day in 0..<8 {
                guard let date = calendar.date(byAdding: .day, value: day, to: start),
                      let next = calendar.date(bySettingHour: rule["hour"] as? Int ?? 0, minute: rule["minute"] as? Int ?? 0, second: 0, of: date) else { continue }
                // The engine counts weekdays from Sunday as 0; the calendar from Sunday as 1.
                let fits = rule["kind"] as? String == "daily" || calendar.component(.weekday, from: next) - 1 == rule["weekday"] as? Int
                if fits, next.timeIntervalSince1970 * 1000 > after { return next.timeIntervalSince1970 * 1000 }
            }
            return nil
        default:
            return nil
        }
    }
}
