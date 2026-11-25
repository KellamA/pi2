import Foundation
import PiModels
import TranscriptKit

/// Draws agents' pages for the engine (docs/design/presenting.md, "Drawing a page: the engine asks the app"). The engine
/// never loads a page: the app says it draws (`present.register`, on every connection), and the engine sends
/// `present.draw` for each page to picture. Each is drawn offscreen by `PresentedPageDrawing`, in a borderless window
/// that is never put on screen and never takes the focus, its files fetched with `presented.file` alone, and what it
/// found goes back in `present.drawn` within the contract's bounds.
///
/// The latest app to register draws: once another (a second copy of pi², a test copy on the same data folder) has, the
/// engine asks it, not this one. What this one was already asked it still draws and answers; the engine takes the first
/// answer for a page and says `answered: false` to the other, which is let go. A draw asked on a connection that has
/// since gone is not answered: the engine forgot it with the connection, and asks again of whoever registers next.
@MainActor
final class PresentedDrawing {
    /// Pages drawn at the same time. Each is a web content process of its own (some tens of MB) and its picture is
    /// taken on the main thread; one call presents at most six items, so two rounds draw the most a call can ask for,
    /// and a register that asks for every page still pending draws them three at a time.
    static let atOnce = 3
    /// Draws waiting their turn; past it the oldest is let go unanswered, and its page stays pending in the engine,
    /// which asks again when an app next registers (as the engine forgets its own oldest past 200).
    static let waitingAtMost = 64
    /// A draw that has not finished this long after it started is answered as failed, before the engine's 20 seconds.
    static let longest: Duration = .seconds(17)

    typealias Request = PresentedDrawRequest

    private var waiting: [(request: Request, connection: Int)] = []
    private var drawing = 0
    /// Request ids asked for and not yet answered or let go, so one asked twice is drawn once.
    private var known: Set<String> = []
    /// Which connection the app is on: a draw asked on an earlier one is not answered on a later one.
    private var connection = 0

    /// Says to the engine that this app draws pages: on every connection, as the computer and the browser roles are.
    func register(_ engine: EngineClient) {
        connection += 1
        // What was asked on the connection before is the engine's no more; it asks again for every page still pending.
        for entry in waiting { known.remove(entry.request.requestId) }
        waiting.removeAll()
        Task { _ = try? await engine.call("present.register") }
    }

    /// A `present.draw` event.
    func take(_ line: Data, engine: EngineClient) {
        guard let request = Request(line) else {
            engine.note("presenting: a present.draw the app could not read was not drawn")
            return
        }
        guard known.insert(request.requestId).inserted else { return }
        waiting.append((request, connection))
        if waiting.count > Self.waitingAtMost {
            let dropped = waiting.removeFirst()
            known.remove(dropped.request.requestId)
            engine.note("presenting: more than \(Self.waitingAtMost) pages waited to be drawn; \(dropped.request.presentation) of conversation \(dropped.request.conversation) waits for the next time pi² registers")
        }
        next(engine)
    }

    /// `present.drawn`'s parameters, kept on the main actor.
    struct Answer: @unchecked Sendable {
        let params: [String: Any]
    }

    private func next(_ engine: EngineClient) {
        while drawing < Self.atOnce, !waiting.isEmpty {
            let (request, asked) = waiting.removeFirst()
            let started = ContinuousClock.now
            // A drawing holds its place until it really ends, even once it has been answered as given up: its own
            // limits (PresentedPageDrawing) end it, and it returns only once the page's web content process has gone
            // (`PresentedProcesses`, which bounds the processes of drawings and windows together). So no more than
            // `atOnce` pages are ever being drawn, and none leaves a process behind.
            drawing += 1
            let work = Task { @MainActor in
                let answer = Answer(params: await self.draw(request, engine: engine))
                self.drawing -= 1
                self.next(engine)
                return answer
            }
            Task { @MainActor in
                let drawn = await Self.first(work, seconds: Double(Self.longest.components.seconds))
                let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
                let what = "\(request.presentation) v\(request.version) item \(request.item) of conversation \(request.conversation)"
                let params: [String: Any]
                if let drawn {
                    params = drawn.params
                    let ok = params["ok"] as? Bool == true
                    engine.note("presenting: drew \(what) in \(ms) ms\(ok ? "" : ": \(params["reason"] as? String ?? "")")")
                } else {
                    params = PresentedDrawAnswer.failed("it did not finish drawing in \(Self.longest.components.seconds) seconds")
                    engine.note("presenting: gave up drawing \(what) after \(ms) ms")
                }
                if asked == self.connection { await self.send(params, for: request, engine: engine) }
                self.known.remove(request.requestId)
            }
        }
    }

    /// What `work` gives, or nil if it has not given it in `seconds`; `work` is left to end by itself.
    private static func first(_ work: Task<Answer, Never>, seconds: Double) async -> Answer? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Answer?, Never>) in
            let once = Once(continuation)
            Task { @MainActor in once.give(await work.value) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                once.give(nil)
            }
        }
    }

    @MainActor
    private final class Once {
        private var continuation: CheckedContinuation<Answer?, Never>?
        init(_ continuation: CheckedContinuation<Answer?, Never>) { self.continuation = continuation }
        func give(_ answer: Answer?) {
            continuation?.resume(returning: answer)
            continuation = nil
        }
    }

    private func draw(_ request: Request, engine: EngineClient) async -> [String: Any] {
        // The page's manifest, by the item the conversation's record has: never a path the event names.
        let item: PresentedItem
        do {
            let records = try await engine.presentedList(conversation: request.conversation)
            guard let found = records.first(where: { $0.id == request.presentation })?.version(request.version),
                  found.items.indices.contains(request.item) else { return PresentedDrawAnswer.failed("the app could not find the page in the conversation's record") }
            item = found.items[request.item]
        } catch {
            return PresentedDrawAnswer.failed("the app could not read the conversation's record: \(error.localizedDescription)")
        }
        guard item.kind == .page else { return PresentedDrawAnswer.failed("that item is a picture, not a page") }
        let page: PresentedPage
        do {
            page = try engine.presentedPage(conversation: request.conversation, item: item)
        } catch {
            return PresentedDrawAnswer.failed("the app could not read the page's list of files: \(error.localizedDescription)")
        }
        let files = EnginePresentedFiles(engine: engine, conversation: request.conversation, presentation: request.presentation, version: request.version, item: request.item)
        let findings = await PresentedPageDrawing.draw(page: page, source: files, width: request.width, height: request.height)
        return PresentedDrawAnswer.params(findings, height: request.height)
    }

    /// Sends what was found. A refusal of the answer (past a bound the app missed) is followed by a plain failure, so
    /// that the page is not left waiting; `answered: false` (another app answered first, or the engine forgot the draw)
    /// is the end of it.
    private func send(_ params: [String: Any], for request: Request, engine: EngineClient) async {
        var answer = params
        answer["requestId"] = request.requestId
        do {
            _ = try await engine.call("present.drawn", answer)
        } catch {
            engine.note("presenting: the engine refused what was found drawing \(request.presentation) of conversation \(request.conversation): \(error.localizedDescription)")
            var failed = PresentedDrawAnswer.failed("the app's findings were refused: \(error.localizedDescription)")
            failed["requestId"] = request.requestId
            _ = try? await engine.call("present.drawn", failed)
        }
    }
}
