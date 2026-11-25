import Foundation

/// A conversation's worktree in the demo (#684; the board's Branches page, #696), answered as `engine/src/worktrees.ts`
/// answers it, against the `branches` event the recording holds: Demo site's conversations work in a git repository,
/// the other projects' in none. Making a worktree moves the conversation to a checkout of its own on a new branch, which
/// the event then shows; removing it moves the conversation back. No git runs and no folder is made: the demo only
/// changes what the event says, as the engine's would once git had done it.
extension DemoScript {
    static let worktrees: [String: DemoAnswer] = [
        "worktree.suggest": { request, world in
            let id = try DemoWorktrees.conversation(request)
            let row = DemoLibrary.row(id, world: world)
            return ["branch": DemoWorktrees.suggest(row?["title"] as? String ?? "", fallback: "\(row?["agentId"] as? String ?? "conversation")-\(id)")]
        },
        "worktree.create": { request, world in
            let id = try DemoWorktrees.conversation(request)
            if let branch = request.params["branch"], !(branch is String) { throw DemoRefusal("branch must be text") }
            guard let status = DemoWorktrees.status(id, world: world) else {
                if world.conversations[id] == nil { throw DemoRefusal("Unknown conversation: \(id)") }
                let cwd = (world.conversations[id]?.state["agent"] as? [String: Any])?["cwd"]
                throw DemoRefusal(cwd is String ? "This conversation's folder is not in a git repository" : "Choose a folder in a git repository for this conversation first")
            }
            if status["managed"] as? Bool == true { throw DemoRefusal("This conversation already has a worktree of its own") }
            let row = DemoLibrary.row(id, world: world)
            let requested = (request.string("branch") ?? "").trimmingCharacters(in: .whitespaces)
            var branch = requested.isEmpty
                ? DemoWorktrees.suggest(row?["title"] as? String ?? "", fallback: "\(row?["agentId"] as? String ?? "conversation")-\(id)")
                : requested
            guard DemoWorktrees.isBranchName(branch) else { throw DemoRefusal("“\(branch)” cannot be a branch name") }
            let repo = status["repo"] as? String ?? "repository"
            let taken = Set(DemoWorktrees.all(world).values.filter { $0["repo"] as? String == repo }.compactMap { $0["branch"] as? String })
            if taken.contains(branch) {
                // A suggested name gets a number; a branch the person named is checked out where it already is.
                guard requested.isEmpty else {
                    throw DemoRefusal("git could not make the worktree: fatal: '\(branch)' is already used by a worktree. Retry, or choose another branch name")
                }
                let stem = branch
                var n = 2
                while taken.contains(branch) {
                    branch = "\(stem)-\(n)"
                    n += 1
                }
            }
            let folder = branch.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            let path = "\(DemoWorktrees.home)/worktrees/\(repo)-d3e0a1/\(folder)"
            var made = status
            made["root"] = path
            made["branch"] = branch
            made["worktree"] = true
            made["managed"] = true
            made["upstream"] = NSNull()
            made["ahead"] = 0
            made["behind"] = 0
            made["base"] = status["branch"] ?? NSNull()
            made["unmerged"] = 0
            made["changes"] = 0
            made["conflicts"] = 0
            made["operation"] = NSNull()
            made["added"] = 0
            made["removed"] = 0
            made["state"] = "clean"
            DemoWorktrees.kept(id, origin: status, world: world)
            DemoWorktrees.set(id, made, world: world)
            world.changeState(of: id) { state in
                var agent = state["agent"] as? [String: Any] ?? [:]
                agent["cwd"] = path
                state["agent"] = agent
            }
            return ["path": path, "branch": branch]
        },
        "worktree.remove": { request, world in
            let id = try DemoWorktrees.conversation(request)
            guard let own = DemoWorktrees.status(id, world: world), own["managed"] as? Bool == true else {
                throw DemoRefusal("This conversation has no worktree of its own")
            }
            if world.conversations[id]?.state["busy"] as? Bool == true { throw DemoRefusal("The agent is working in this worktree. Stop it first") }
            let force = request.params["force"] as? Bool == true
            if !force, (own["changes"] as? Int ?? 0) > 0 || (own["conflicts"] as? Int ?? 0) > 0 {
                throw DemoRefusal("The worktree has changes that are not committed. Commit them, or remove it anyway")
            }
            let branch = own["branch"] as? String
            let origin = DemoWorktrees.origin(of: id, world: world)
            DemoWorktrees.set(id, origin, world: world)
            if let back = origin?["root"] as? String {
                world.changeState(of: id) { state in
                    var agent = state["agent"] as? [String: Any] ?? [:]
                    agent["cwd"] = back
                    state["agent"] = agent
                }
            }
            // Its branch has no commits beyond where it started, so it is merged, and goes when asked.
            let deleted = request.params["deleteBranch"] as? Bool == true && branch != nil
            return ["branchDeleted": deleted, "note": NSNull(), "branch": branch ?? NSNull(), "keptBecause": NSNull(), "squashed": NSNull()]
        },
    ]
}

@MainActor
enum DemoWorktrees {
    /// The recording's data folder, as `scripts/demo-recording` writes it.
    static let home = "/Users/someone/Library/Application Support/pi2-demo"
    private static let originsKey = "DemoWorktrees.origins"

    static func conversation(_ request: DemoRequest) throws -> Int {
        guard let id = request.params["id"] as? NSNumber, !DemoSettings.isBool(id) else {
            throw DemoRefusal("Unknown conversation: \(request.params["id"] ?? "undefined")")
        }
        return id.intValue
    }

    static func all(_ world: DemoWorld) -> [String: [String: Any]] {
        (world.event("branches")?["conversations"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    }

    static func status(_ id: Int, world: DemoWorld) -> [String: Any]? { all(world)[String(id)] }

    static func set(_ id: Int, _ status: [String: Any]?, world: DemoWorld) {
        world.change("branches") { event in
            var conversations = event["conversations"] as? [String: Any] ?? [:]
            conversations[String(id)] = status
            event["conversations"] = conversations
        }
    }

    /// Where the conversation worked before its worktree, to go back to.
    static func kept(_ id: Int, origin: [String: Any], world: DemoWorld) {
        var origins = world.kept[originsKey] as? [Int: [String: Any]] ?? [:]
        origins[id] = origin
        world.kept[originsKey] = origins
    }

    static func origin(of id: Int, world: DemoWorld) -> [String: Any]? {
        var origins = world.kept[originsKey] as? [Int: [String: Any]] ?? [:]
        let origin = origins.removeValue(forKey: id)
        world.kept[originsKey] = origins
        return origin
    }

    /// `suggestBranch`: "pi2/" and the title's words, lower case, hyphens between, at most 40 characters.
    static func suggest(_ title: String, fallback: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var slug = folded.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        slug = String(slug.prefix(40))
        while slug.hasSuffix("-") { slug.removeLast() }
        return "pi2/\(slug.isEmpty ? fallback : slug)"
    }

    /// What `git check-ref-format --branch` refuses, in the main.
    static func isBranchName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.hasPrefix("/") && !name.hasSuffix("/") && !name.hasSuffix(".") && !name.hasSuffix(".lock")
            && !name.contains("..") && !name.contains("//") && !name.contains("@{") && name != "@"
            && name.range(of: "[\\x00-\\x20~^:?*\\[\\\\\\x7f]", options: .regularExpression) == nil
    }
}
