import Foundation
import Network

/// A very small web server on this Mac, for the pages the probe checks BrowserKit against.
final class FixtureServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    struct Response {
        var status = 200
        var headers: [String: String] = ["Content-Type": "text/html; charset=utf-8"]
        var body = Data()

        static func html(_ text: String) -> Response { Response(body: Data(text.utf8)) }
        static func redirect(_ to: String) -> Response { Response(status: 302, headers: ["Location": to]) }
        static let notFound = Response(status: 404, body: Data("<title>Not found</title><p>Nothing here.</p>".utf8))
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "pi2.fixture-server")
    private let lock = NSLock()
    private var seen: [Request] = []
    private let respond: @Sendable (Request) -> Response

    /// Every request that arrived, oldest first.
    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    var port: Int { Int(listener.port?.rawValue ?? 0) }
    var origin: String { "http://127.0.0.1:\(port)" }

    init(respond: @escaping @Sendable (Request) -> Response) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.respond = respond
    }

    /// Whether `start` has been answered; the listener reports its state more than once.
    private var started = false

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.started else { return }
                switch state {
                case .ready:
                    self.started = true
                    continuation.resume()
                case .failed(let error):
                    self.started = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.read(connection, Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func read(_ connection: NWConnection, _ soFar: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = soFar
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.lock.lock()
                self.seen.append(request)
                self.lock.unlock()
                self.send(self.respond(request), on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer)
            }
        }
    }

    /// A whole request, once all of it has arrived.
    private static func parse(_ data: Data) -> Request? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let body = data[headEnd.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let reasons = [200: "OK", 302: "Found", 404: "Not Found"]
        var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "OK")\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
