import Foundation
import Observation
import PiModels

/// What a window or screen with a background command's output keeps up to date while it shows: the one loop the Mac's
/// output window (app/Sources/pi2/BackgroundViews.swift, as `BackgroundOutputFeed`) and the phone's command's output
/// screen (iphone/Sources/Conversations/BackgroundCommandsListing.swift, as `BackgroundCommandsFeed`) both follow. It
/// asks for the output from where the last answer ended, and the engine holds the request until there is more or the
/// command ends (`background.output` with `wait`), so output shows as it arrives. Between answers it waits half a
/// second, so a command that prints without pause is followed twice a second at most. Reading here does not change what
/// counts as read for the agent. See docs/background.md.
@MainActor
@Observable
public final class BackgroundOutputFollower {
    /// The engine keeps the last 128 KB of a command's output; the window keeps up to twice that before cutting it back.
    public static let keep = 128 * 1024

    public let id: String
    /// The engine's last answer: how the command stands.
    public private(set) var latest: BackgroundOutput?
    /// Why the output cannot be shown, from the engine.
    public private(set) var problem: String?
    /// The output shown: plain text, exactly as the command printed it.
    public private(set) var text = ""
    /// How many characters it printed before `text` that are not shown, because they were not kept.
    public private(set) var notShown = 0
    /// Goes up whenever `text` is replaced rather than added to, so the view sets it whole.
    public private(set) var replaced = 0

    public init(id: String) {
        self.id = id
    }

    /// A follower that shows `output` as an answer, for a test or a debug sample: nothing is asked of the engine.
    public convenience init(id: String, showing output: BackgroundOutput) {
        self.init(id: id)
        take(output, askedFrom: 0)
    }

    /// One ask of the engine: `background.output` for this command from `from` on, the engine holding the request up to
    /// `wait` seconds until there is more or the command ends, its answer read as `BackgroundOutput`. Each app gives its
    /// own, since it asks through its own client.
    public typealias Ask = (_ from: Int, _ wait: Int) async throws -> BackgroundOutput

    /// Follows the command until it ends or the task is cancelled (the window closed, the page went). `ask` asks the
    /// engine; `connected` says whether it is reachable, so that a failure while it is not is waited out (two seconds,
    /// then asked again as if the first) rather than ending the follow.
    public func follow(_ ask: Ask, connected: () -> Bool) async {
        var from = 0
        var first = true
        while !Task.isCancelled {
            do {
                // The first answer comes at once, so the view can say how the command stands before it prints.
                let answer = try await ask(from, first ? 0 : 20)
                first = false
                take(answer, askedFrom: from)
                from = answer.total
                problem = nil
                if !answer.running { return }
                try? await Task.sleep(for: .milliseconds(500))
            } catch {
                // The engine is out of reach for now: ask again once it is back, when it says whether it still has it.
                if !connected() {
                    try? await Task.sleep(for: .seconds(2))
                    first = true
                    continue
                }
                problem = error.localizedDescription
                return
            }
        }
    }

    /// Joins an answer onto what is shown, or starts again from what the engine kept.
    public func take(_ answer: BackgroundOutput, askedFrom: Int) {
        latest = answer
        if answer.dropped > 0 || answer.from < askedFrom || askedFrom == 0 {
            // More was printed since the last answer than the engine keeps, or this is the first: start again from what it has.
            text = answer.output
            notShown = answer.from
            replaced += 1
        } else if !answer.output.isEmpty {
            text += answer.output
        }
        // A command that prints for hours would otherwise fill the view without end: keep the last part, from a new line.
        let units = text.utf16.count
        if units > 2 * Self.keep {
            var cut = text.utf16.index(text.utf16.startIndex, offsetBy: units - Self.keep)
            if let newline = text[cut...].firstIndex(of: "\n") { cut = text.index(after: newline) }
            notShown += text[..<cut].utf16.count
            text = String(text[cut...])
            replaced += 1
        }
    }
}
