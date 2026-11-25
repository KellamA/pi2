#if DEBUG
import OSLog
import SwiftUI
import TranscriptKit
import UIKit

/// What a debug build's environment asks the conversation's screen to do, as a tap would, so that each of its requests
/// can be made and pictured against a throwaway copy with no hand on the simulator (docs/iphone-app.md, "Launch
/// arguments"; docs/development.md, "Trying the phone against a copy"). Each goes through the screen's own controls'
/// code and the real request, so what shows is what the engine answered. None of it is compiled into a release build.
///
/// `PI2_CONVERSATION_ACT` holds one step or several separated by `|`, done in order, each once what it needs has come
/// (the conversation, a run, a queued message), or given up after two minutes:
/// - `send:<text>`: sends `<text>`, as Send does (steered while the agent works, as the field's default).
/// - `steer:<text>`, `queue:<text>`: once the agent works, sends `<text>` to steer it or to the queue.
/// - `stop`: once the agent works, presses Stop. `take-back`: once a message waits in the queue, takes the first back.
/// - `continue`: once a run has stopped and can be resumed, presses Continue. `restore`: once the conversation shows
///   as archived, presses Restore.
/// - `pictures:<count>[:<text>]`: adds `<count>` pictures of noise, about 4 MB each once prepared as a chosen photo
///   is, and sends them with `<text>` once they are ready.
/// - `older`: scrolls the page to its top, a few times, so that it asks for the entries before those it has.
/// - `open-picture`: opens the last picture the page shows of an entry, as a tap on it does.
enum ConversationDebugAct: Equatable {
    case send(String)
    case steer(String)
    case queue(String)
    case stop
    case takeBack
    case carryOn
    case restore
    case pictures(count: Int, text: String)
    case older
    case openPicture

    static let current: [ConversationDebugAct] = parse(ProcessInfo.processInfo.environment["PI2_CONVERSATION_ACT"] ?? "")

    static func parse(_ text: String) -> [ConversationDebugAct] {
        text.split(separator: "|").compactMap { named(String($0)) }
    }

    static func named(_ text: String) -> ConversationDebugAct? {
        let (name, argument) = text.firstIndex(of: ":").map { (String(text[..<$0]), String(text[text.index(after: $0)...])) } ?? (text, "")
        switch name {
        case "send": return argument.isEmpty ? nil : .send(argument)
        case "steer": return argument.isEmpty ? nil : .steer(argument)
        case "queue": return argument.isEmpty ? nil : .queue(argument)
        case "stop": return .stop
        case "take-back": return .takeBack
        case "continue": return .carryOn
        case "restore": return .restore
        case "older": return .older
        case "open-picture": return .openPicture
        case "pictures":
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard let count = parts.first.flatMap({ Int($0) }), (1...ConversationPictureLimits.count).contains(count) else { return nil }
            return .pictures(count: count, text: parts.count > 1 ? parts[1] : "")
        default: return nil
        }
    }
}

/// What the screen hands the acts: what it shows now, and its controls' actions.
@MainActor
struct ConversationDebugControls {
    /// What the screen still waits for before it can act, or nil once it can.
    let missing: () -> String?
    let status: () -> ConversationStatus
    let send: (_ text: String, _ steer: Bool) -> Void
    let stop: () -> Void
    let withdraw: (Int) -> Void
    let carryOn: () -> Void
    let restore: (Int?) -> Void
    let pictures: ConversationPictures
    let page: () -> TranscriptUIKitView?

    private static let log = Logger(subsystem: "dev.pi2.ios", category: "conversation")

    static func note(_ text: String) {
        log.notice("\(text, privacy: .public)")
    }

    /// Whether the acts have been started: once a launch, by the first screen whose page shows.
    private static var started = false

    /// Does the acts asked for, in order, once each can be done.
    func run(_ acts: [ConversationDebugAct]) async {
        guard !acts.isEmpty, !Self.started else { return }
        Self.started = true
        Self.log.notice("acts: \(acts.count) asked; waiting for \(missing() ?? "nothing", privacy: .public)")
        guard await wait(for: "the conversation", { missing() == nil }) else {
            Self.log.notice("acts: still waiting for \(missing() ?? "nothing", privacy: .public)")
            return
        }
        for act in acts {
            Self.log.notice("act: \(String(describing: act), privacy: .public)")
            switch act {
            case .send(let text):
                send(text, true)
            case .steer(let text), .queue(let text):
                guard await wait(for: "a run", { status().busy }) else { return }
                if case .steer = act { send(text, true) } else { send(text, false) }
            case .stop:
                guard await wait(for: "a run", { status().busy }) else { return }
                stop()
            case .takeBack:
                guard await wait(for: "a queued message", { queued != nil }), let queued else { return }
                withdraw(queued)
            case .carryOn:
                guard await wait(for: "a run to continue", { status().failure?.canContinue == true }) else { return }
                carryOn()
            case .restore:
                guard await wait(for: "the archive", { status().archived != nil }), let archived = status().archived else { return }
                if case .parent(let root) = archived { restore(root) } else { restore(nil) }
            case .pictures(let count, let text):
                for index in 0..<count {
                    guard let image = await Self.photo(seed: index) else { return }
                    pictures.add(image, name: "Photo \(index + 1).jpg")
                }
                guard await wait(for: "the pictures", { !pictures.isReading }) else { return }
                for picture in pictures.ready {
                    Self.log.notice("picture \(picture.name, privacy: .public): \(picture.data.count) bytes, \(picture.mimeType, privacy: .public)")
                }
                send(text, true)
            case .older:
                for _ in 0..<6 {
                    page()?.scrollView.setContentOffset(.zero, animated: false)
                    try? await Task.sleep(for: .seconds(2))
                }
            case .openPicture:
                guard await wait(for: "the page", { page()?.isReady == true }), let view = page() else { return }
                let opened = try? await view.callAsyncJavaScript(Self.openPicture, contentWorld: .page)
                Self.log.notice("open-picture: \(String(describing: opened), privacy: .public)")
            }
            // Long enough for the request's answer to be drawn before the next step looks at the screen.
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private var queued: Int? {
        for chip in status().chips {
            if case .queued(let submission) = chip.kind { return submission }
        }
        return nil
    }

    private func wait(for what: String, _ condition: () -> Bool) async -> Bool {
        let end = Date(timeIntervalSinceNow: 120)
        while !condition() {
            if Date() > end || Task.isCancelled {
                Self.log.notice("act: gave up waiting for \(what, privacy: .public)")
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// Shows the last picture of an entry, waits for the page to have fetched it, and taps it.
    private static let openPicture = """
        const thumbs = document.querySelectorAll('[data-picture]');
        if (thumbs.length === 0) return 'no picture';
        const thumb = thumbs[thumbs.length - 1];
        thumb.scrollIntoView({ block: 'center' });
        for (let i = 0; i < 300 && thumb.classList.contains('loading'); i++) await new Promise((done) => setTimeout(done, 100));
        if (thumb.classList.contains('failed')) return 'failed: ' + thumb.getAttribute('data-picture');
        thumb.click();
        return 'opened ' + thumb.getAttribute('data-picture');
        """

    /// A picture of noise as large as a message's picture may be drawn, 2000 by 2000, each channel its own noise, which
    /// compresses worse than any photo: about 4.5 MB once prepared as a photo is, under the engine's 5 MB.
    private static func photo(seed: Int) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let width = ConversationPictureLimits.side, height = ConversationPictureLimits.side
            var generator = SystemRandomNumberGenerator()
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            // One channel kept bright, which tells the pictures apart.
            let tint = UInt64(0xC0) << (8 * UInt64(seed % 3))
            bytes.withUnsafeMutableBytes { raw in
                let words = raw.bindMemory(to: UInt64.self)
                for index in words.indices {
                    words[index] = generator.next() | tint | tint << 32
                }
            }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let image = context.makeImage() else { return nil }
            return UIImage(cgImage: image)
        }.value
    }
}
#endif
