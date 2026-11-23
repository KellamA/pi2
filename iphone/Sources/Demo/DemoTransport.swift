
import EngineKit
import Foundation

/// The demo mode's engine (docs/iphone.md 9.4): one more `EngineTransport`, so every screen in the demo is the real one,
/// drawn by the same client from the same events. Unlike the debug build's replay it answers: the script in `Script/`
/// answers each request as the engine would, against `DemoWorld`, the recording held in memory. It opens no connection
/// of any kind, registers for nothing and writes nothing: everything it does is in this process's memory.
@MainActor
final class DemoTransport: EngineTransport {
    /// The Mac the demo stands in for, as the connection bar names it.
    static let macName = "Demo Mac"

    let world: DemoWorld
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?

    /// The recording in this build's bundle (`Recording/demo-session.jsonl`), or nil when it is not there.
    static func recorded(in bundle: Bundle = .main) -> DemoTransport? {
        guard let text = recording(in: bundle) else { return nil }
        return DemoTransport(recording: text)
    }

    static func recording(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "demo-session", withExtension: "jsonl") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    init(recording: String, now: Date = Date()) {
        world = DemoWorld(recording: recording, now: now)
    }

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        self.handler = handler
        world.send = { [weak self] data in self?.deliver(data) }
        let greeting = world.greeting()
        // A moment later, as a connection is ready after it is started.
        Task { @MainActor [weak self] in
            self?.handler?(.ready)
            self?.handler?(.received(greeting))
        }
    }

    func send(_ data: Data) {
        guard let request = DemoRequest(line: data) else { return }
        // The answer goes after anything the answer itself sent (the events that change), as the engine sends them.
        let reply = DemoScript.reply(to: request, in: world)
        deliver(DemoWorld.line(reply))
    }

    func cancel() {
        handler = nil
        world.stop()
    }

    /// Ends the demo's connection, as leaving the demo does: the client is told it closed, and lets it go.
    func close() {
        let handler = handler
        cancel()
        handler?(.closed("The demo was left."))
    }

    /// Hands bytes to the client after the request that caused them has been sent, as a connection would.
    private func deliver(_ data: Data) {
        Task { @MainActor [weak self] in self?.handler?(.received(data)) }
    }
}
