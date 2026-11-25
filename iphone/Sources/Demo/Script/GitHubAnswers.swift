import Foundation

/// A project's work on GitHub in the demo (#684; the Work tab's GitHub side, #694, and a pull request's page, #695),
/// answered as `engine/src/github.ts` answers it, against the `github` event the recording holds: **Demo site**, its
/// repository read through a stand-in for `gh` when the recording was made, with an open pull request whose checks pass,
/// a finding on it, and the issue it fixes. Merging merges it and closes that issue; Send back posts nothing anywhere
/// but tells the conversation that opened it, which answers; the diff is the one the recording kept (`answer` lines).
/// Nothing reaches GitHub: every answer changes the event, which the engine would have read again from GitHub.
extension DemoScript {
    static let github: [String: DemoAnswer] = [
        // The listing is the recording's: reading it again finds what it holds.
        "github.refresh": { request, world in
            _ = try DemoGitHub.attached(request, world: world)
            return [:]
        },
        // One issue, or with `pull: true` one pull request, read whole into the listing.
        "github.show": { request, world in
            let project = try DemoGitHub.attached(request, world: world)
            let number = try DemoGitHub.number(request)
            if request.params["pull"] as? Bool == true {
                guard var pull = DemoGitHub.pull(number, of: project, world: world) else {
                    throw DemoRefusal("There is no pull request #\(number) in \(DemoGitHub.repository(project, world: world)).")
                }
                pull.removeValue(forKey: "partial")
                DemoGitHub.keep(pull: pull, in: project, world: world)
                return ["pull": pull]
            }
            let recorded = world.recordedAnswer("github.show", ["projectId": project, "number": number])?["item"] as? [String: Any]
            guard var item = recorded ?? DemoGitHub.issue(number, of: project, world: world) else { throw DemoRefusal("Unknown work item: #\(number)") }
            item.removeValue(forKey: "partial")
            DemoGitHub.keep(item: item, in: project, world: world)
            return ["item": item]
        },
        "github.diff": { request, world in
            let project = try DemoGitHub.attached(request, world: world)
            let number = try DemoGitHub.number(request)
            if let recorded = world.recordedAnswer("github.diff", ["projectId": project, "number": number]) { return recorded }
            guard DemoGitHub.pull(number, of: project, world: world) != nil else {
                throw DemoRefusal("GitHub refused it: no pull requests found for branch \"\(number)\"")
            }
            return ["diff": ""]
        },
        // Past the merge question, as the person merges at the Mac (`mergePull`).
        "github.merge": { request, world in
            let project = try DemoGitHub.attached(request, world: world, write: true)
            let number = try DemoGitHub.number(request)
            guard var pull = DemoGitHub.pull(number, of: project, world: world) else {
                throw DemoRefusal("There is no pull request #\(number) in \(DemoGitHub.repository(project, world: world)).")
            }
            switch pull["state"] as? String {
            case "closed": throw DemoRefusal("Pull request #\(number) is closed, so it cannot be merged.")
            case "merged": return [:]
            default: break
            }
            if pull["mergeable"] as? String == "no" {
                throw DemoRefusal("Pull request #\(number) cannot be merged: it conflicts with \(pull["base"] as? String ?? "its base").")
            }
            pull["state"] = "merged"
            pull.removeValue(forKey: "partial")
            DemoGitHub.keep(pull: pull, in: project, world: world)
            // As GitHub does: "Fixes #N" closes the issue as completed.
            if let fixes = (pull["work"] as? NSNumber)?.intValue, var issue = DemoGitHub.issue(fixes, of: project, world: world),
               issue["state"] as? String != "done", issue["state"] as? String != "dropped" {
                issue["state"] = "done"
                issue["takenBy"] = NSNull()
                issue["closedAt"] = world.now
                issue["updatedAt"] = world.now
                DemoGitHub.keep(item: issue, in: project, world: world)
            }
            return [:]
        },
        // The reason on it, then to the conversation that opened it, as an input of its own kind (`sendBack`).
        "github.sendBack": { request, world in
            let project = try DemoGitHub.attached(request, world: world, write: true)
            guard let reason = request.params["reason"] as? String else { throw DemoRefusal("reason must be text") }
            let number = try DemoGitHub.number(request)
            if reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw DemoRefusal("Say why it goes back, in text.") }
            guard let pull = DemoGitHub.pull(number, of: project, world: world) else {
                throw DemoRefusal("There is no pull request #\(number) in \(DemoGitHub.repository(project, world: world)).")
            }
            guard let opened = ((pull["openedBy"] as? [String: Any])?["conversationId"] as? NSNumber)?.intValue,
                  world.conversations[opened] != nil, DemoLibrary.row(opened, world: world) != nil else { return [:] }
            let text = "The person sent back pull request #\(number): \(reason)"
            world.append([["id": world.newItemID(), "kind": "marker", "text": text, "details": ["wake": ["text": text]]]], to: opened)
            DemoLibrary.touch(opened, title: nil, world: world)
            DemoReplies.take(DemoReplies.Message(submission: world.newSubmissionID(), text: text, mode: "queue", resumed: true), in: opened, world: world)
            return [:]
        },
        // The recording holds no write whose outcome pi² could not tell.
        "github.settle": { request, world in
            let project = try DemoGitHub.attached(request, world: world)
            guard request.params["intent"] is String else { throw DemoRefusal("intent must be the id of a write whose outcome is unknown") }
            guard DemoSettings.isBool(request.params["happened"]) else { throw DemoRefusal("happened must be true or false") }
            let unknown = DemoGitHub.listing(project, world: world)?["unknown"] as? [[String: Any]] ?? []
            guard unknown.contains(where: { $0["id"] as? String == request.string("intent") }) else {
                throw DemoRefusal("That write is not waiting to be settled.")
            }
            return [:]
        },
    ]
}

/// The `github` event's listings, read and changed as `github.ts` keeps them.
@MainActor
enum DemoGitHub {
    /// The project a request names in `projectId`, with a repository attached, refused in the engine's words.
    static func attached(_ request: DemoRequest, world: DemoWorld, write: Bool = false) throws -> String {
        guard let id = request.string("projectId") else { throw DemoRefusal("projectId must be a project's id") }
        guard let project = DemoProjects.project(id, world: world), !(project["deletedAt"] is NSNumber) else { throw DemoRefusal("Unknown project: \(id)") }
        if write, project["archivedAt"] is NSNumber { throw DemoRefusal(DemoSettings.archived) }
        guard project["repository"] is [String: Any], listing(id, world: world) != nil else {
            throw DemoRefusal("This project has no repository attached.")
        }
        return id
    }

    static func number(_ request: DemoRequest) throws -> Int {
        guard let number = request.params["number"] as? NSNumber, !DemoSettings.isBool(number),
              number.doubleValue == Double(number.intValue), number.intValue >= 1 else {
            throw DemoRefusal("number must be a pull request's number")
        }
        return number.intValue
    }

    static func listing(_ project: String, world: DemoWorld) -> [String: Any]? {
        (world.event("github")?["projects"] as? [String: Any])?[project] as? [String: Any]
    }

    /// "owner/name".
    static func repository(_ project: String, world: DemoWorld) -> String {
        let repository = listing(project, world: world)?["repository"] as? [String: Any]
        return "\(repository?["owner"] as? String ?? "")/\(repository?["name"] as? String ?? "")"
    }

    static func pull(_ number: Int, of project: String, world: DemoWorld) -> [String: Any]? {
        (listing(project, world: world)?["pulls"] as? [[String: Any]] ?? []).first { ($0["number"] as? NSNumber)?.intValue == number }
    }

    static func issue(_ number: Int, of project: String, world: DemoWorld) -> [String: Any]? {
        (listing(project, world: world)?["issues"] as? [[String: Any]] ?? []).first { ($0["id"] as? NSNumber)?.intValue == number }
    }

    /// A fresh reading of one issue or pull request in the listing, which the event then carries (`keepInListing`).
    static func keep(item: [String: Any]? = nil, pull: [String: Any]? = nil, in project: String, world: DemoWorld) {
        world.change("github") { event in
            var projects = event["projects"] as? [String: Any] ?? [:]
            guard var listing = projects[project] as? [String: Any] else { return }
            if let item, let id = (item["id"] as? NSNumber)?.intValue {
                let issues = (listing["issues"] as? [[String: Any]] ?? []).filter { ($0["id"] as? NSNumber)?.intValue != id } + [item]
                listing["issues"] = issues.sorted { ($0["id"] as? NSNumber)?.intValue ?? 0 > ($1["id"] as? NSNumber)?.intValue ?? 0 }
            }
            if let pull, let number = (pull["number"] as? NSNumber)?.intValue {
                let pulls = (listing["pulls"] as? [[String: Any]] ?? []).filter { ($0["number"] as? NSNumber)?.intValue != number } + [pull]
                listing["pulls"] = pulls.sorted { ($0["number"] as? NSNumber)?.intValue ?? 0 > ($1["number"] as? NSNumber)?.intValue ?? 0 }
            }
            projects[project] = listing
            event["projects"] = projects
        }
    }
}
