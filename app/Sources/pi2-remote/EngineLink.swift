import Dispatch
import Foundation
import RemoteKit

/// The control connection to the engine (docs/iphone.md 5.5; engine/src/remote.ts): descriptor 3, one end of the socket
/// pair the engine made for this process. One JSON object a line, each way:
///
/// - pi² Remote's own requests, `{"id","method","params"}` with a `remote.*` method, answered `{"id","result"}` or
///   `{"id","error"}`;
/// - a device's lines in a session, `{"session","message"}` both ways;
/// - the `remote` event, `{"event":"remote","kind",…}`, the engine's to pi² Remote alone.
///
/// A line from the engine is at most `maxLineLength` long: a longer one is a fault, and pi² Remote stops (the engine
/// starts it again). A session's lines are passed on as their bytes, never read: the engine wrote them for the device.
package final class EngineLink: @unchecked Sendable {
	/// The longest line taken from the engine: RemoteKit's limit on an attached device's lines (`Lines.defaultMaxLength`),
	/// since what the engine sends a session goes on to the phone whole.
	package static let maxLineLength = Lines.defaultMaxLength

	private let io: SocketIO
	private var partial = Data()
	private var nextID: Int64 = 1
	private var waiting: [Int64: (Result<JSONValue, Refused>) -> Void] = [:]

	/// A `remote` event: its fields, `kind` among them.
	package var onEvent: (JSONValue) -> Void = { _ in }
	/// A line the engine sent a session: the session's id and the message's bytes, a JSON object as the engine wrote it.
	package var onSessionLine: (String, Data) -> Void = { _, _ in }
	/// The connection closed, or the engine sent what it never sends.
	package var onClose: (String) -> Void = { _ in }

	package init(io: SocketIO) {
		self.io = io
		io.onBytes = { [unowned self] in self.take($0) }
		io.onClose = { [unowned self] in
			self.failWaiting()
			self.onClose("the engine ended the control connection")
		}
	}

	package func start() { io.start() }

	/// What waits to be written to the engine.
	package var pending: Int { io.pending }

	/// Calls `then` whenever what waits for the engine falls to `below` bytes or fewer.
	package func onDrained(below: Int, _ then: @escaping () -> Void) {
		io.drainedBelow = below
		io.onDrained = then
	}

	private func take(_ bytes: Data) {
		var rest = bytes[...]
		while let newline = rest.firstIndex(of: 0x0A) {
			let piece = rest[rest.startIndex ..< newline]
			rest = rest[rest.index(after: newline)...]
			guard partial.count + piece.count <= Self.maxLineLength else { return overlong() }
			let line = partial.isEmpty ? Data(piece) : partial + piece
			partial = Data()
			if !line.isEmpty { heard(line) }
			if io.isClosed { return }
		}
		guard partial.count + rest.count <= Self.maxLineLength else { return overlong() }
		partial.append(contentsOf: rest)
	}

	private func overlong() {
		partial = Data()
		fail("the engine sent a line longer than \(Self.maxLineLength) bytes")
	}

	private func fail(_ why: String) {
		io.onClose = {}
		io.close()
		failWaiting()
		onClose(why)
	}

	private func failWaiting() {
		let answers = waiting
		waiting = [:]
		for answer in answers.values { answer(.failure(Refused("the engine's connection closed"))) }
	}

	private func heard(_ line: Data) {
		if let (session, message) = Self.sessionLine(line) {
			onSessionLine(session, message)
			return
		}
		guard let value = try? JSON.parse(line), case .object = value else {
			log("the engine sent a line that is not one JSON object; left")
			return
		}
		if value["event"]?.stringValue == "remote" {
			onEvent(value)
		} else if let id = value["id"]?.integerValue, let answer = waiting.removeValue(forKey: id) {
			if let error = value["error"] {
				answer(.failure(Refused(error.stringValue ?? "the engine refused")))
			} else {
				answer(.success(value["result"] ?? .null))
			}
		}
	}

	/// `{"session":"<id>","message":<the message>}`, as remote.ts writes it, read without parsing the message: its id
	/// and its bytes. Nil for any other line.
	package static func sessionLine(_ line: Data) -> (String, Data)? {
		let head = Array(#"{"session":""#.utf8)
		let middle = Array(#"","message":"#.utf8)
		guard line.count > head.count + middle.count + 2, line.starts(with: head), line.last == UInt8(ascii: "}") else { return nil }
		var index = line.startIndex + head.count
		let idStart = index
		while index < line.endIndex, index - idStart <= 64, SessionID.idByte(line[index]) { index += 1 }
		let id = String(decoding: line[idStart ..< index], as: UTF8.self)
		guard SessionID(id) != nil, line[index...].starts(with: middle) else { return nil }
		let message = line[(index + middle.count) ..< (line.endIndex - 1)]
		guard message.first == UInt8(ascii: "{") else { return nil }
		return (id, Data(message))
	}

	/// One of pi² Remote's own requests; `answer` is called on the queue with the result or the engine's refusal.
	package func request(_ method: String, _ params: JSONValue = .object([]), answer: @escaping (Result<JSONValue, Refused>) -> Void = { _ in }) {
		guard !io.isClosed else { return answer(.failure(Refused("the engine's connection closed"))) }
		let id = nextID
		nextID += 1
		waiting[id] = answer
		var line = JSON.write(.object([("id", .integer(id)), ("method", .string(method)), ("params", params)]))
		line.append(0x0A)
		io.send(line)
	}

	/// A device's line in its session. `message` must be one JSON object, read strictly by the caller, with no line break:
	/// it is put in the line as it is.
	package func send(session: SessionID, message: Data) {
		var line = Data(#"{"session":"#.utf8)
		line.append(JSON.write(.string(session.text)))
		line.append(contentsOf: #","message":"#.utf8)
		line.append(message)
		line.append(contentsOf: "}\n".utf8)
		io.send(line)
	}
}

extension SessionID {
	/// The bytes a session's id may hold: letters, digits, `_` and `-`.
	package static func idByte(_ byte: UInt8) -> Bool {
		switch byte {
		case UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"): true
		default: false
		}
	}
}
