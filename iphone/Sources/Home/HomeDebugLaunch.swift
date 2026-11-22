
#if DEBUG
import Foundation

/// What a debug build's environment asks of the projects list at launch, so that each of its states can be pictured in
/// the simulator without a tap (docs/iphone-app.md, "Launch arguments"; `SIMCTL_CHILD_PI2_HOME` with `xcrun simctl
/// launch`). None of it is compiled into a release build. `PI2_HOME` is one of:
///
/// - `scroll:chats` or `scroll:more`: the list scrolled to its Chats or More, once the projects are in.
/// - `search:<words>`: the words typed in the search field.
/// - `why`: the connection bar's explanation open.
/// - `archive:<project>`: Archive chosen on the project of that name, as a tap would, which sends the request (the
///   recorded session refuses it, and the list shows the refusal).
enum HomeDebugLaunch {
    static let value = ProcessInfo.processInfo.environment["PI2_HOME"]

    private static func argument(_ name: String) -> String? {
        guard let value, value.hasPrefix(name + ":") else { return nil }
        return String(value.dropFirst(name.count + 1))
    }

    static var scroll: String? { argument("scroll") }
    static var search: String? { argument("search") }
    static var archive: String? { argument("archive") }
    static var explains: Bool { value == "why" }
}
#endif
