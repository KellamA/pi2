import Darwin
import Foundation

/// pi² Remote's log: `remote.log` in the data folder, readable by the person alone, kept under a megabyte (the one
/// before is `remote.log.1`). The engine starts pi² Remote with its standard output and error going nowhere, so before
/// the data folder is known (a refusal at start), lines go to standard error, for whoever started it.
///
/// It says what happened in fixed words, ids and addresses. Never a key, the pairing's secret `s`, a digit, a
/// signature or a line a device or the engine sent: what the channel carries is the person's.
package final class Log: @unchecked Sendable {
	private let lock = NSLock()
	private var file: URL?
	private static let limit = 1_000_000

	package static let shared = Log()

	/// From now on, lines go to `remote.log` in `folder`.
	package func open(folder: URL) {
		lock.withLock { file = folder.appendingPathComponent("remote.log") }
	}

	package func say(_ text: String) {
		let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
		let line = "\(stamp) \(text)\n"
		lock.withLock {
			guard let file else {
				FileHandle.standardError.write(Data("pi² Remote: \(text)\n".utf8))
				return
			}
			var info = stat()
			if lstat(file.path, &info) == 0, info.st_size > Log.limit {
				_ = rename(file.path, file.path + ".1")
			}
			let descriptor = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
			guard descriptor >= 0 else { return }
			defer { close(descriptor) }
			let bytes = Array(line.utf8)
			_ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
		}
	}
}

package func log(_ text: String) { Log.shared.say(text) }

/// Says `text` at most once a minute for each `kind`: for what anyone on the network can make happen at will.
final class Seldom: @unchecked Sendable {
	private var said: [String: TimeInterval] = [:]
	static let shared = Seldom()

	func say(_ kind: String, _ text: String) {
		let now = Date().timeIntervalSince1970
		guard now - (said[kind] ?? 0) >= 60 else { return }
		said[kind] = now
		log("\(text) (said at most once a minute)")
	}
}
