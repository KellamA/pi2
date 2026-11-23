import Foundation

/// Where a tap on a widget opens the app: one of the app's routes, in a URL, since the extension cannot name `Route`
/// (which is `App/`'s). The app takes it in `onOpenURL` and opens the route it names, once Face ID has opened the
/// session (docs/iphone.md 4.5): the widget never answers anything itself.
///
/// | Link | URL | Route |
/// |---|---|---|
/// | `.needs(project: nil, need: nil)` | `pi2-widget://needs` | `.needs()` |
/// | `.needs(project: p, need: n)` | `pi2-widget://needs?project=p&need=n` | `.needs(project: p)` |
/// | `.conversation(139)` | `pi2-widget://conversation?id=139` | `.conversation(139)` |
/// | `.dashboard(project: nil)` | `pi2-widget://dashboard` | `.dashboard()` |
/// | `.usage` | `pi2-widget://usage` | `.usage` |
///
/// The scheme is the widgets' own, not `pi2:`, which a release build does not take (docs/iphone.md 12.2, P12); WidgetKit
/// hands a widget's URL to its own app, so it need not be registered for other apps to open.
enum WidgetsLink: Hashable, Sendable {
    /// What needs the person: of a project, at one of its cards by its id, or of all.
    case needs(project: String? = nil, need: String? = nil)
    case conversation(Int)
    case dashboard(project: String? = nil)
    case usage

    static let scheme = "pi2-widget"

    var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        switch self {
        case .needs(let project, let need):
            parts.host = "needs"
            parts.queryItems = Self.items(["project": project, "need": need])
        case .conversation(let id):
            parts.host = "conversation"
            parts.queryItems = [URLQueryItem(name: "id", value: String(id))]
        case .dashboard(let project):
            parts.host = "dashboard"
            parts.queryItems = Self.items(["project": project])
        case .usage:
            parts.host = "usage"
        }
        return parts.url!
    }

    /// The link a URL names, or nil for any other URL: another scheme, another place, an id that is not one.
    init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == Self.scheme,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard let value = item.value, Self.isID(value), query[item.name] == nil else { return nil }
            query[item.name] = value
        }
        let allowed: Set<String>
        switch parts.host {
        case "needs":
            self = .needs(project: query["project"], need: query["need"])
            allowed = ["project", "need"]
        case "conversation":
            guard let id = query["id"].flatMap(Int.init), id > 0 else { return nil }
            self = .conversation(id)
            allowed = ["id"]
        case "dashboard":
            self = .dashboard(project: query["project"])
            allowed = ["project"]
        case "usage":
            self = .usage
            allowed = []
        default:
            return nil
        }
        guard Set(query.keys).isSubset(of: allowed) else { return nil }
    }

    private static func items(_ values: KeyValuePairs<String, String?>) -> [URLQueryItem]? {
        let items = values.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        return items.isEmpty ? nil : items
    }

    /// A project's, a need's or a conversation's id as the engine makes them: short, of letters, digits and `-_.:`.
    private static func isID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128
            && value.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_.:".unicodeScalars.contains($0) }
    }
}
