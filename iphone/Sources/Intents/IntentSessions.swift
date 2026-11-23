
import AppIntents
import EngineKit
import Foundation
import Observation
import PiModels

/// How Shortcuts and Siri reach the app's one session (docs/iphone.md 4.5, "Whatever the session"; #701).
///
/// App Intents run in the app's own process: when the person runs one, iOS starts pi² in the background if it is not
/// running, which runs `Pi2App.init` (and with it `Launch.start`) before any intent, but draws no scene. So the session
/// an intent uses is the one `Pi2App.init` made, the same one the screens use, registered here:
///
/// ```swift
/// IntentSessions.register(session)   // in Pi2App.init, after Launch.start(session)
/// ```
///
/// That line is `App/`'s (#680) to add, and the session's Face ID with it (`isOpen`, below). Until it is there, an
/// intent finds nothing registered and makes a session as `Pi2App.init` does (`AppSession()` and `Launch.start`), so
/// that it reaches the same Mac, recording or demo the app would. While the app's window is also open that is a second
/// connection beside the screens' one, which the registration ends.
@MainActor
enum IntentSessions {
    /// The registered session and what it says of Face ID.
    struct Registration {
        let session: AppSession
        /// Whether a session Face ID opened is open now (docs/iphone.md 4.5): nil while the app has no such session to
        /// ask about. `AppSession` has none yet (#680), and no screen of the app asks Face ID before it sends, so neither
        /// does an intent; once it has one, `register` is given it, and an intent run while it is closed opens pi² for
        /// Face ID before it sends anything.
        let isOpen: (@MainActor () -> Bool)?
    }

    private(set) static var registration: Registration?

    /// What an intent asks of the system that a unit test cannot answer: confirming a stop, and opening pi² for Face ID.
    /// Nil asks the system; a test sets its own.
    static var prompts: Prompts?

    struct Prompts {
        var confirm: @MainActor (_ question: String) async throws -> Void
        var foreground: @MainActor (_ why: String) async throws -> Void
    }

    /// Registers the app's session for every intent, with whether Face ID's session is open, once `AppSession` keeps one.
    static func register(_ session: AppSession, isOpen: (@MainActor () -> Bool)? = nil) {
        registration = Registration(session: session, isOpen: isOpen)
        keepPhrasesInStep(with: session)
    }

    /// Forgets the registration: for a test, which registers a session of its own.
    static func forget() {
        registration = nil
    }

    /// The registered session, or one made as `Pi2App.init` makes it while nothing registered one (see above).
    static func current() -> Registration {
        if let registration { return registration }
        let session = AppSession()
        Launch.start(session)
        session.note("An intent made its own session: Pi2App.init registers none yet (IntentSessions.register, #701).")
        register(session)
        return registration!
    }

    // MARK: - Ready

    /// How long an intent waits for the session to reach its Mac, or a recording or the demo, before it says the Mac
    /// cannot be reached. The channel's own wait is #680's; this only keeps Siri from waiting longer than it will.
    static var connectWait: Duration = .seconds(10)

    /// Where the session stands, once it has had its chance to connect.
    enum Reach: Equatable {
        /// No Mac is paired and the demo is off.
        case notPaired
        /// The engine answers: a Mac, the demo, the recording, or (out of reach) the phone's store of what the Mac last
        /// sent, whose writes go to the Outbox (#692).
        case connected(outOfReach: Bool)
        /// Nothing answers: the Mac is out of reach and the phone has nothing that stands in for it.
        case unreachable
    }

    /// Waits until the session's client answers, or says why it does not.
    static func reach(_ session: AppSession) async -> Reach {
        let end = ContinuousClock.now + connectWait
        while true {
            if session.connection == .notPaired { return .notPaired }
            if session.engine.status == .connected {
                // The library comes first after the greeting; projects and what needs the person with it.
                if !session.engine.hasLoadedLibrary, ContinuousClock.now < end {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                if case .outOfReach = session.connection { return .connected(outOfReach: true) }
                return .connected(outOfReach: false)
            }
            if case .outOfReach = session.connection, session.engine.transport == nil { return .unreachable }
            if ContinuousClock.now >= end { return .unreachable }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Whether the session is paired and its Mac out of reach.
    static func outOfReach(_ session: AppSession) -> Bool {
        if case .outOfReach = session.connection { return true }
        return false
    }

    /// Opens pi² for Face ID when the session's Face ID is closed, and waits for it to open; throws when it did not.
    static func unlock(_ registration: Registration, foreground system: @MainActor (String) async throws -> Void) async throws {
        guard let isOpen = registration.isOpen, !isOpen() else { return }
        if let foreground = prompts?.foreground {
            try await foreground(IntentWords.unlock)
        } else {
            try await system(IntentWords.unlock)
        }
        let end = ContinuousClock.now + .seconds(60)
        while !isOpen() {
            guard ContinuousClock.now < end else { throw IntentRefusal(IntentWords.stayedLocked) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Phrases

    /// Tells Siri which projects a phrase can name ("Stop pi² in Demo project") whenever the session's projects change.
    private static func keepPhrasesInStep(with session: AppSession) {
        let names = withObservationTracking {
            session.engine.projects.map(\.name)
        } onChange: {
            Task { @MainActor in
                guard registration?.session === session else { return }
                keepPhrasesInStep(with: session)
            }
        }
        if names != phraseNames {
            phraseNames = names
            PiShortcuts.updateAppShortcutParameters()
        }
    }

    private static var phraseNames: [String]?
}

/// What an intent says when it cannot go on, in words the person reads or hears.
struct IntentRefusal: Error, CustomLocalizedStringResourceConvertible {
    let words: String

    init(_ words: String) {
        self.words = words
    }

    var localizedStringResource: LocalizedStringResource { "\(words)" }
}
