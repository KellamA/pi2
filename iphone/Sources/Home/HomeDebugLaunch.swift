
#if DEBUG
import Foundation

/// What a debug build's environment asks of the projects list at launch, so that each of its states can be pictured in
/// the simulator without a tap (docs/iphone-app.md, "Launch arguments"; `SIMCTL_CHILD_PI2_HOME` with `xcrun simctl
/// launch`). None of it is compiled into a release build. `PI2_HOME` is one of:
///
/// - `scroll:projects`, `scroll:chats` or `scroll:more`: the list scrolled to that section, once the projects are in.
/// - `search:<words>`: the words typed in the search field.
/// - `why`: the connection bar's explanation open.
/// - `archive:<project>`: Archive chosen on the project of that name, as a tap would, which sends the request (the
///   recorded session refuses it, and the list shows the refusal).
/// - `rename:<project>`: Rename… chosen on that project, its alert open with the name in it; `rename:<project>=<name>`
///   the alert answered with `<name>`, which sends the request.
/// - `stop:<project>`: Stop the Orchestrator chosen on that project.
/// - `new-chat`: New Chat tapped.
/// - `pin:<chat>`, `unpin:<chat>`, `archive-chat:<chat>`: the chat of that title pinned, unpinned or archived, as its
///   swipe would.
///
/// Each action goes through the real request, so the engine's answer or refusal shows.
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
    static var stop: String? { argument("stop") }
    static var newChat: Bool { value == "new-chat" }
    static var pin: String? { argument("pin") }
    static var unpin: String? { argument("unpin") }
    static var archiveChat: String? { argument("archive-chat") }

    static var rename: (project: String, name: String?)? { argument("rename").map(renaming) }

    /// `<project>` or `<project>=<name>`: the project, and the new name if one is given.
    static func renaming(_ words: String) -> (project: String, name: String?) {
        guard let equals = words.firstIndex(of: "=") else { return (words, nil) }
        return (String(words[..<equals]), String(words[words.index(after: equals)...]))
    }

    /// Whether the list may act yet: once the Mac answers (or the demo does). While the phone draws its store's copy,
    /// before Face ID and the channel, a request would get the store's refusal rather than the Mac's answer.
    static func acts(_ connection: AppSession.Connection) -> Bool {
        switch connection {
        case .connected, .demo: true
        case .notPaired, .connecting, .outOfReach: false
        }
    }
}
#endif
