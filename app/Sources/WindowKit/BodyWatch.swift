import Observation

/// Says when a body that should read nothing that changes did read something that changed: for the app's scene body
/// (#436).
///
/// SwiftUI works a scene body out again whenever something it read changes, and with it every scene, setting each
/// window's settings again (its hosting view's sizing options among them, which #400 was about). The app's scene body
/// once read the inbox, the agents and the mode, so every request from a sub-chat did that, every few seconds while
/// agents worked. What shows them now are views of their own, which SwiftUI draws again on their own. This watches the
/// body so that a read put back is noticed: it wraps the body in an observation of its own and, the first time in a
/// launch something it read changes, reports a line for the log. The reads it sees are also SwiftUI's: an observation
/// inside another one passes what it saw on to the outer one, so SwiftUI updates the scenes as it did without it.
@MainActor
public final class BodyWatch {
    public private(set) var reported = false
    private let name: String

    /// `name` says which body, in the line reported.
    public nonisolated init(_ name: String) {
        self.name = name
    }

    /// Works out `body`, and calls `report` the first time something it read changes.
    public func watch<T>(report: @escaping @MainActor @Sendable (String) -> Void, _ body: () -> T) -> T {
        withObservationTracking(body) { [weak self] in
            // Called on the thread making the change, before it is made; the app's state changes on the main thread.
            Task { @MainActor in self?.changed(report) }
        }
    }

    private func changed(_ report: @MainActor (String) -> Void) {
        guard !reported else { return }
        reported = true
        report("\(name) read something that has changed since, so SwiftUI works out every scene again, and sets each window's settings again, for each change of it. Show what changes in a view of its own, which reads it in its own body (#436).")
    }
}
