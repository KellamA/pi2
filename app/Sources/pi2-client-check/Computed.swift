import PiModels

// The computed properties of the models that the views read, written after each model's stored ones (`Computed`). Those
// that read the clock, the time zone or the language (a limit's "until 14:32", a schedule's "Every Monday", a list joined
// with "and") are left out: they would differ from one Mac to the next.

extension ToolCall: Computed {
    var computed: [(String, Any)] { [("summary", summary)] }
}

extension BranchStatus: Computed {
    var computed: [(String, Any)] { [("isDirty", isDirty)] }
}

extension InboxItem: Computed {
    var computed: [(String, Any)] { [("call", call)] }
}

extension RuleOffer: Computed {
    var computed: [(String, Any)] { [("command", command), ("place", place)] }
}

extension CommandRule: Computed {
    var computed: [(String, Any)] { [("id", id), ("command", command)] }
}

extension AgentProfile: Computed {
    var computed: [(String, Any)] { [("payload", Dump.json(payload)), ("asSaved", Raw(text: Dump.plain(asSaved)))] }
}

extension Repeat: Computed {
    var computed: [(String, Any)] { [("payload", Dump.json(payload))] }
}

extension Schedule: Computed {
    var computed: [(String, Any)] { [("payload", Dump.json(payload(isNew: false))), ("new", Dump.json(payload(isNew: true)))] }
}

extension RunFailure: Computed {
    var computed: [(String, Any)] { [("message", message)] }
}

extension TaskList: Computed {
    var computed: [(String, Any)] { [("doneCount", doneCount), ("isFinished", isFinished), ("current", current as Any)] }
}

extension TaskItem: Computed {
    var computed: [(String, Any)] { [("state", state.words)] }
}

extension Spend: Computed {
    var computed: [(String, Any)] { [("costText", costText), ("tokensText", tokensText)] }
}

extension ContextSize: Computed {
    var computed: [(String, Any)] { [("fraction", fraction as Any)] }
}

extension UsageSummary.ModelRow: Computed {
    var computed: [(String, Any)] { [("id", id)] }
}

extension ProviderInfo: Computed {
    var computed: [(String, Any)] { [("statusText", statusText)] }
}

extension ModelInfo: Computed {
    var computed: [(String, Any)] { [("ref", ref), ("listName", listName)] }
}

extension EndpointModel: Computed {
    var computed: [(String, Any)] { [("payload", Dump.json(payload))] }
}

extension NeedItem: Computed {
    var computed: [(String, Any)] {
        [("fromSubChat", fromSubChat), ("placeWords", placeWords), ("switchWords", switchWords as Any), ("named", named), ("short", short)]
    }
}

extension ProjectRule.Binds: Computed {
    var computed: [(String, Any)] { [("title", title)] }
}

extension ProjectRow: Computed {
    /// The switches of docs/projects.md 8.1, as the Agents tab asks each.
    var computed: [(String, Any)] {
        ["startAgents", "fileWork", "closeWork", "makeAgents", "addRules", "merge", "release", "passLimits"].map { ($0, allows($0)) }
    }
}
