import BrowserKit
import Foundation
import Network

/// Stands in for the app on an engine's socket: offers BrowserKit as the browser and carries out what the engine asks,
/// reading the engine's requests and writing its answers exactly as the app does. With it the engine's side (what may
/// be done, when to ask) and BrowserKit's side (doing it) can be tried together, against the local fixture pages.
@MainActor
final class EngineLink {
    private let connection: NWConnection
    private let browser: BrowserController
    private var buffer = Data()
    private var nextID = 1
    /// What to do when the engine closes the connection.
    var closed: () -> Void = { exit(0) }

    init(socket: String, browser: BrowserController) {
        connection = NWConnection(to: .unix(path: socket), using: .tcp)
        self.browser = browser
    }

    /// Connect and offer the browser. Returns once the engine has the offer.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var answered = false
            connection.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    guard !answered else { return }
                    switch state {
                    case .ready:
                        answered = true
                        continuation.resume()
                    case .failed(let error), .waiting(let error):
                        answered = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .main)
        }
        receive()
        send("browser.register", [:])
    }

    private func send(_ method: String, _ params: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: ["id": nextID, "method": method, "params": params]) else { return }
        nextID += 1
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { self.buffer.append(data) }
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    let line = Data(self.buffer[self.buffer.startIndex..<newline])
                    self.buffer.removeSubrange(self.buffer.startIndex...newline)
                    if !line.isEmpty { self.handle(line) }
                }
                if isComplete || error != nil {
                    // The engine went away; so does its stand-in app.
                    self.closed()
                    return
                }
                self.receive()
            }
        }
    }

    private struct Envelope: Decodable {
        let event: String?
    }

    private func handle(_ line: Data) {
        guard (try? JSONDecoder().decode(Envelope.self, from: line))?.event == "browser" else { return }
        guard let event = try? JSONDecoder().decode(BrowserEvent.self, from: line) else {
            print("unreadable \(String(decoding: line, as: UTF8.self))")
            return
        }
        Task { @MainActor in
            let reply = await browser.perform(event.request)
            send("browser.result", reply.result(for: event.requestId))
        }
    }
}
