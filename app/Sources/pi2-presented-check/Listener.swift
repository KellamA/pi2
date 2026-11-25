// Listeners on 127.0.0.1 alone that a page drawn with the network off must never reach: every TCP connection and every
// UDP datagram is counted, and a request's path kept. They answer a request as a small web server would, so that the
// unguarded control page, which shows that each way of reaching the network does reach them when nothing stops it, gets
// an answer. Loopback only: nothing here reaches the local network or the internet.

import Foundation
import Network

final class Listener: @unchecked Sendable {
    private let tcp: NWListener
    private let udp: NWListener
    private let queue = DispatchQueue(label: "pi2.presented-check.listener")
    private let lock = NSLock()
    private var connectionCount = 0
    private var datagramCount = 0
    private var seenPaths: [String] = []

    var tcpPort: Int { Int(tcp.port?.rawValue ?? 0) }
    var udpPort: Int { Int(udp.port?.rawValue ?? 0) }
    var origin: String { "http://127.0.0.1:\(tcpPort)" }

    /// Every TCP connection accepted, every UDP datagram received, and the paths of the requests read.
    var counts: (connections: Int, datagrams: Int, paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (connectionCount, datagramCount, seenPaths)
    }

    init() throws {
        let tcpParameters = NWParameters.tcp
        tcpParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        tcp = try NWListener(using: tcpParameters)
        let udpParameters = NWParameters.udp
        udpParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        udp = try NWListener(using: udpParameters)
    }

    func start() async throws {
        try await ready(tcp) { [weak self] connection in
            guard let self else { return }
            self.lock.lock(); self.connectionCount += 1; self.lock.unlock()
            connection.start(queue: self.queue)
            self.read(connection, Data())
        }
        try await ready(udp) { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection)
        }
    }

    func stop() {
        tcp.cancel()
        udp.cancel()
    }

    private func ready(_ listener: NWListener, _ accept: @escaping @Sendable (NWConnection) -> Void) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.first() { continuation.resume() }
                case .failed(let error): if once.first() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = accept
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if data != nil { self.lock.lock(); self.datagramCount += 1; self.lock.unlock() }
            if error == nil { self.receive(connection) }
        }
    }

    private func read(_ connection: NWConnection, _ soFar: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = soFar
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
                self.lock.lock(); self.seenPaths.append(path); self.lock.unlock()
                let body = Data("/* \(path) */".utf8)
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(reply.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer)
            }
        }
    }
}

/// True the first time only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
