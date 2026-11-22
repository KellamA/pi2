import Foundation
import RemoteKit

/// A small harness: each check prints a line, and the program exits non-zero if any failed.
enum Check {
	nonisolated(unsafe) static var passed = 0
	nonisolated(unsafe) static var failed: [String] = []
	/// Every error a refusal threw, so that `errorsHoldNoSecret` can read them all at the end.
	nonisolated(unsafe) static var errors: [String] = []

	static func that(_ condition: @autoclosure () throws -> Bool, _ name: String) {
		do {
			if try condition() {
				passed += 1
			} else {
				failed.append(name)
				print("FAIL \(name)")
			}
		} catch {
			failed.append("\(name): \(error)")
			print("FAIL \(name): threw \(error)")
		}
	}

	/// That `body` throws, and the error is RemoteKit's own.
	static func refuses(_ name: String, _ body: () throws -> Void) {
		do {
			try body()
			failed.append(name)
			print("FAIL \(name): was taken")
		} catch let error as RemoteKitError {
			errors.append(String(describing: error))
			passed += 1
			if verbose { print("ok   refused \(name): \(error)") }
		} catch {
			failed.append(name)
			print("FAIL \(name): threw something other than RemoteKitError: \(type(of: error))")
		}
	}

	/// Runs `body`, counting a throw as a failure.
	static func runs(_ name: String, _ body: () throws -> Void) {
		do {
			try body()
			passed += 1
		} catch {
			failed.append("\(name): \(error)")
			print("FAIL \(name): \(error)")
		}
	}

	static func section(_ title: String) { print("== \(title)") }

	/// `--verbose` prints every refusal with the error it gave.
	static let verbose = CommandLine.arguments.contains("--verbose")
}

extension Data {
	init?(hex: String) {
		let characters = Array(hex.utf8)
		guard characters.count % 2 == 0 else { return nil }
		var bytes = [UInt8]()
		bytes.reserveCapacity(characters.count / 2)
		var index = 0
		while index < characters.count {
			guard let high = Self.nibble(characters[index]), let low = Self.nibble(characters[index + 1]) else { return nil }
			bytes.append(high << 4 | low)
			index += 2
		}
		self.init(bytes)
	}

	private static func nibble(_ character: UInt8) -> UInt8? {
		switch character {
		case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
		case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
		case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
		default: nil
		}
	}

	var hex: String { map { String(format: "%02x", $0) }.joined() }
}
