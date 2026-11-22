import Darwin

/// What the fuzzer is running, kept where a signal handler can read it without allocating: if a parser traps (an
/// overflow, an index out of range, a force-unwrap), the handler writes the target, the iteration and the input in hex
/// to standard error, then lets the signal end the process as it would have. `--replay <target> <hex>` runs it again.
enum Crash {
	static let capacity = 1 << 20
	nonisolated(unsafe) static let input = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
	nonisolated(unsafe) static var length = 0
	nonisolated(unsafe) static let target = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
	nonisolated(unsafe) static var iteration: UInt64 = 0
	/// Room for the handler to write digits into.
	nonisolated(unsafe) static let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)

	static func record(target name: String, iteration: UInt64, input bytes: [UInt8]) {
		let count = min(bytes.count, capacity)
		if count > 0 { bytes.withUnsafeBufferPointer { input.update(from: $0.baseAddress!, count: count) } }
		length = count
		self.iteration = iteration
		var index = 0
		for byte in name.utf8.prefix(63) {
			target[index] = byte
			index += 1
		}
		target[index] = 0
	}

	static func install() {
		for signal in [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT, SIGFPE] {
			Darwin.signal(signal, handler)
		}
	}
}

private func say(_ text: StaticString) {
	_ = write(2, text.utf8Start, text.utf8CodeUnitCount)
}

private let handler: @convention(c) (Int32) -> Void = { signal in
	say("\npi2-remote-fuzz: crashed in target ")
	var length = 0
	while length < 63, Crash.target[length] != 0 { length += 1 }
	_ = write(2, Crash.target, length)
	say(" at iteration ")
	var value = Crash.iteration
	var position = 32
	repeat {
		position -= 1
		Crash.scratch[position] = 48 + UInt8(value % 10)
		value /= 10
	} while value > 0
	_ = write(2, Crash.scratch + position, 32 - position)
	say(", on this input (hex):\n")
	let hex: StaticString = "0123456789abcdef"
	for index in 0..<Crash.length {
		let byte = Crash.input[index]
		Crash.scratch[0] = hex.utf8Start[Int(byte >> 4)]
		Crash.scratch[1] = hex.utf8Start[Int(byte & 15)]
		_ = write(2, Crash.scratch, 2)
	}
	say("\n")
	Darwin.signal(signal, SIG_DFL)
	raise(signal)
}
