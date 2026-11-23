import Foundation

/// What the contract's table says a phone may send of what these screens could send (docs/iphone.md 4.2), so that a
/// control is drawn as the design says: changeable, changeable with the Mac told of it, or "on the Mac". The engine is
/// the judge (`deviceMay` in `answers.ts`, P5); this only keeps the screens from offering what it will refuse.
enum SettingsReach: Equatable {
    /// A phone may send it in an open session.
    case phone
    /// A phone may send it, and the Mac notifies the person, since it widens what agents may do (4.2, 4.4).
    case widens
    /// Only the Mac may: a secret or a sign-in, a program started on the Mac, the Mac's upkeep, or Allow everything.
    case mac

    /// Where 4.2 places `method` with these parameters.
    static func of(_ method: String, _ params: [String: Any] = [:]) -> SettingsReach {
        switch method {
        // Names, pins, notes; the person's ordinary acts; starts.
        case "projects.rename", "projects.archive", "github.detach", "settings.setAwake", "settings.setAutoArchive",
             "settings.setCompaction", "coauthor.set", "schedules.delete":
            return .phone
        case "schedules.runNow":
            return params["confirmLimit"] == nil ? .phone : .widens
        // Changes that widen or cannot be undone.
        case "projects.set", "projects.unarchive", "projects.delete", "github.attach", "agents.save", "schedules.save",
             "usage.setBudget", "memory.setEnabled":
            return .widens
        case "chat.set":
            // Only choosing the default model, or turning the web or memory off, narrows.
            if params["instructions"] != nil { return .widens }
            if params["web"] as? Bool == true || params["memory"] as? Bool == true { return .widens }
            return .phone
        case "agents.allowEverything":
            return params["on"] as? Bool == true ? .mac : .phone
        default:
            // Everything 4.2 keeps to the Mac (secrets and sign-ins, picture models, programs started on the Mac, the
            // app's host roles, the Mac's upkeep, devices), and any request it does not name, which P5 places there.
            return .mac
        }
    }

    /// The Mac's settings a phone does not change, each with why (docs/design/iphone.md, "What stays on the Mac, and
    /// why"; docs/iphone.md 4.2's last row). Drawn as a list, so the person knows where to go.
    static let onTheMac: [(title: String, why: String, symbol: String)] = [
        ("Providers, keys and sign-ins", "Secrets never leave the Mac.", "key"),
        ("Default model for new agents", "Set on the Mac until the engine lets a phone choose it.", "cpu"),
        ("Models for pictures", "They spend on the Mac’s keys.", "photo"),
        ("Agents’ variables", "Their values are secrets; agents’ pages show the names.", "lock"),
        ("MCP servers, computer use and pi²’s browser", "Programs and permissions of the Mac.", "desktopcomputer"),
        ("Local models", "Installed and run on the Mac.", "internaldrive"),
        ("Command priority", "The Mac’s own upkeep.", "speedometer"),
        ("Storage, backups and updates", "The Mac’s own upkeep.", "externaldrive"),
        ("Devices and pairing", "Only at the Mac, so a lost phone cannot add one.", "iphone"),
        ("Allow everything, turned on", "Ends all asking for an agent; turning it off works here.", "checkmark.shield"),
    ]
}
