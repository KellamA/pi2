import PiModels

/// What an approval's card says, in the Mac card's words (`InboxCard` in `app/Sources/pi2/InboxViews.swift`), so that
/// one request reads the same on both.
enum NeedApprovalWords {
    /// "Beacon wants to run a command", in the words of what the tool does.
    static func request(tool: String, agent: String?, arguments: JSONValue?, background: Bool?, site: String?) -> String {
        let who = agent ?? "The agent"
        switch tool {
        case "bash":
            return background == true ? "\(who) wants to run a command in the background" : "\(who) wants to run a command"
        case "write": return "\(who) wants to write a file"
        case "edit": return "\(who) wants to edit a file"
        case "write_document": return "\(who) wants to write \(documentKind(arguments?["path"]?.stringValue))"
        case "computer":
            return arguments?["app"]?.stringValue.map { "\(who) wants to use \($0)" } ?? "\(who) wants to use an app on the Mac"
        case "browser": return "\(who) wants to act on \(site.flatMap { $0.isEmpty ? nil : $0 } ?? "a web page")"
        case "delegate": return "\(who) wants a worktree for a sub-chat"
        case "schedule_task":
            let title = (arguments?["title"]?.stringValue ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return title.isEmpty ? "\(who) wants to schedule work" : "\(who) wants to schedule “\(title)”"
        default: return "\(who) wants to use \(tool)"
        }
    }

    /// What the action would do, in words, when the app or the engine put it so (a computer or browser action, a
    /// schedule's time): shown above the call. Nil for a call shown only as written.
    static func described(item: InboxItem?, need: NeedItem) -> String? {
        let tool = item?.tool ?? need.tool ?? ""
        if tool == "schedule_task" { return item?.when ?? item?.question ?? need.question }
        guard ["computer", "browser", "delegate"].contains(tool) else { return nil }
        return item?.question ?? need.question
    }

    /// A choice that stops asking: what the Mac's "Always Allow" buttons offer, with what each covers.
    struct Offer: Equatable {
        let decision: NeedReply.Decision
        let title: String
        let detail: String
    }

    /// The Inbox's wider answers for `item`, as its card on the Mac offers them: none for a project's switch or a
    /// schedule, a rule only where the engine offered one.
    static func always(item: InboxItem?, agent: String?) -> [Offer] {
        guard let item, item.projectSwitch == nil, item.tool != "schedule_task" else { return [] }
        var offers: [Offer] = []
        if item.tool == "bash", let rule = item.rule, !rule.words.isEmpty {
            let folder = rule.folder.split(separator: "/").last.map(String.init) ?? rule.folder
            offers.append(Offer(
                decision: .rule,
                title: "Always allow “\(rule.command)” \(rule.place)",
                detail: "\(agent ?? "This agent") may then run commands that start with “\(rule.command)” in \(folder)\(rule.worktrees == true ? " and its worktrees" : "") without asking, from now on."
            ))
        }
        switch item.tool {
        case "computer":
            if let app = item.arguments["app"]?.stringValue {
                offers.append(Offer(decision: .always, title: "Always allow in \(app)", detail: "Stop asking about \(app) for the rest of this conversation."))
            }
        case "browser":
            if let site = item.site, !site.isEmpty {
                offers.append(Offer(decision: .always, title: "Always allow on \(site)", detail: "Stop asking about actions on \(site) for the rest of this conversation."))
            }
        case "delegate":
            offers.append(Offer(decision: .always, title: "Always allow here", detail: "Stop asking about worktrees for sub-chats in this conversation."))
        default:
            offers.append(Offer(decision: .always, title: "Always allow \(item.tool) here", detail: "Stop asking about \(item.tool) in this conversation."))
        }
        return offers
    }

    private static func documentKind(_ path: String?) -> String {
        switch (path ?? "").split(separator: ".").last?.lowercased() {
        case "docx": "a Word document"
        case "rtf": "an RTF document"
        case "odt": "an OpenDocument file"
        case "html": "an HTML page"
        default: "a document"
        }
    }
}
