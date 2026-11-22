#if DEBUG
import UIKit

/// A debug build's way to picture the states of the conversation's screen that the recorded session never reaches
/// (docs/iphone-app.md, "Drawing a screen and picturing it"), chosen with `PI2_CONVERSATION_SAMPLE` in the environment
/// (`SIMCTL_CHILD_PI2_CONVERSATION_SAMPLE` with `xcrun simctl launch`). None of it is compiled into a release build.
///
/// - `busy`, `failed`, `stopped`, `archived`, `waiting`: what is drawn around the transcript is a sample, and says so
///   in a line of its own, over the real page. Nothing is answered: the samples are only drawn.
/// - `photos`: opens the photo picker, as Attach › Photo Library does. `pictures`: puts two drawn pictures through
///   the same preparation a photo goes through, into the strip above the field.
/// - `send:<text>`: sends `<text>` through the session at launch, as Send does, so that a picture shows what the
///   engine (or the recording, which refuses it) answered.
enum ConversationSample {
    case busy
    case failed
    case stopped
    case archived
    case waiting
    case photos
    case pictures
    case send(String)

    static let current: ConversationSample? = ProcessInfo.processInfo.environment["PI2_CONVERSATION_SAMPLE"].flatMap(named)

    static func named(_ text: String) -> ConversationSample? {
        if text.hasPrefix("send:") { return .send(String(text.dropFirst(5))) }
        return switch text {
        case "busy": .busy
        case "failed": .failed
        case "stopped": .stopped
        case "archived": .archived
        case "waiting": .waiting
        case "photos": .photos
        case "pictures": .pictures
        default: nil
        }
    }

    /// The status drawn: the engine's, with the sample's state over it.
    func status(over real: ConversationStatus) -> ConversationStatus {
        var status = real
        let note = ConversationStatus.Banner(id: "sample", text: "Debug sample: these lines are not from the engine.", symbol: "hammer", tone: .accent)
        switch self {
        case .busy:
            status.busy = true
            status.arrivalSteered = "\(status.agentName) reads this once the command `npm test` has finished: it cannot be left half done."
            status.arrivalQueued = "\(status.agentName) reads this once it has answered."
            status.chips = [
                .init(id: "a", kind: .sending(macAway: false), label: "Sending", summary: "And check the docs too"),
                .init(id: "b", kind: .sent, label: "Sent", summary: "Use the second branch"),
                .init(id: "c", kind: .queued(submission: 41), label: "After the command `npm test`", summary: "Then open a pull request"),
                .init(id: "d", kind: .queued(submission: 42), label: "Queued until the answer", summary: "What is left after that?"),
            ]
            status.banners = [note]
        case .failed:
            status.busy = false
            status.failure = .init(message: "The model returned an error: overloaded", stopped: false, canContinue: true)
            status.banners = [note]
        case .stopped:
            status.busy = false
            status.failure = .init(message: "Stopped", stopped: true, canContinue: true)
            status.banners = [note]
        case .archived:
            status.archived = .itself
            status.banners = [note]
        case .waiting:
            status.waiting = [
                .init(id: "a", text: "\(status.agentName) needs approval: Run npm --prefix engine test"),
                .init(id: "b", text: "Forge asks for more reach: write to the docs folder"),
            ]
            status.banners = [note]
        case .send, .photos, .pictures:
            break
        }
        return status
    }

    /// For `send:`, sends the text once, as Send does; for `pictures`, adds two drawn pictures.
    @MainActor
    func act(sending: (String) -> Void, pictures: ConversationPictures) async {
        // Once the conversation has come, so that the field and its draft are there.
        try? await Task.sleep(for: .seconds(1.5))
        switch self {
        case .send(let text):
            sending(text)
        case .pictures where pictures.entries.isEmpty:
            for (index, hue) in [0.62, 0.08].enumerated() {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900)).image { context in
                    UIColor(hue: hue, saturation: 0.5, brightness: 0.9, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
                    UIColor.white.setFill()
                    context.fill(CGRect(x: 200, y: 200, width: 800, height: 500))
                }
                pictures.add(image, name: "Photo \(index + 1)")
            }
        default:
            break
        }
    }

    /// Whether the photo picker opens at launch.
    static var opensPhotos: Bool {
        if case .photos = current { true } else { false }
    }
}
#endif
