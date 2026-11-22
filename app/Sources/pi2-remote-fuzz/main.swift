// Runs every parser in RemoteKit that reads bytes from the network (#674, iphone.md 5.2) against mutated and random
// input: base64url, ids and keys, JSON, frames, lines, the TCP framing, the pairing payload, the channel's own lines,
// both handshakes from both sides, transport messages, sealed items and what they hold. Each target starts from good
// input, mutates it, and keeps what its parser took as a place to start from again. A parser that traps ends the run
// with the input that made it (Crash.swift); a parser that takes what it must not, or reads back as something else,
// ends it with the input and what was wrong (Fuzz.violation).
//
//   cd app && swift build --product pi2-remote-fuzz && .build/debug/pi2-remote-fuzz --seed 674 --seconds 60
//
// --seed N        the run's seed (674 if not given): the same seed makes the same keys, handshakes and mutations
// --seconds S     how long the whole run takes, shared out among the targets (60 if not given)
// --iterations N  each target runs N times, whatever the time
// --target NAME   only that target
// --replay NAME HEX  runs NAME once on the input HEX (as a crash printed it), with the same --seed
// --help          prints this and runs nothing
//
// Any other argument, or a value it cannot read, stops it with the usage and exit code 2.

import Foundation

let usage = """
	usage: pi2-remote-fuzz [--seed N] [--seconds S | --iterations N] [--target NAME]
	       pi2-remote-fuzz [--seed N] --replay NAME HEX
	       pi2-remote-fuzz --help
	"""

/// Stops with the usage and exit code 2: an argument this program does not know, or a value it cannot read, must never
/// quietly change or shorten a run (in CI least of all).
func refuse(_ why: String) -> Never {
	FileHandle.standardError.write(Data("pi2-remote-fuzz: \(why)\n\(usage)\n".utf8))
	exit(2)
}

var seed: UInt64 = 674
var seconds: Double = 60
var iterations: UInt64?
var only: String?
var replay: (name: String, hex: String)?
var arguments = CommandLine.arguments.dropFirst()
@MainActor func value(_ name: String) -> String {
	guard let next = arguments.popFirst() else { refuse("\(name) needs a value") }
	return next
}
while let argument = arguments.popFirst() {
	switch argument {
	case "--help":
		print(usage)
		exit(0)
	case "--seed":
		guard let number = UInt64(value(argument)) else { refuse("--seed takes a whole number") }
		seed = number
	case "--seconds":
		guard let number = Double(value(argument)), number.isFinite, number > 0, number <= 86_400 else { refuse("--seconds takes a number of seconds above zero") }
		seconds = number
	case "--iterations":
		guard let number = UInt64(value(argument)), number > 0 else { refuse("--iterations takes a whole number above zero") }
		iterations = number
	case "--target":
		only = value(argument)
	case "--replay":
		replay = (value(argument), value(argument))
	default:
		refuse("unknown argument \(argument)")
	}
}

setvbuf(stdout, nil, _IOLBF, 0)
var targets: [Target]
do {
	targets = try Targets.all(seed: seed)
} catch {
	print("pi2-remote-fuzz: could not make the targets: \(error)")
	exit(1)
}

if let replay {
	let hex = Array(replay.hex.utf8)
	guard hex.count % 2 == 0 else { refuse("--replay takes hex") }
	var input: [UInt8] = []
	var at = 0
	while at + 1 < hex.count {
		guard let byte = UInt8(String(decoding: hex[at...at + 1], as: UTF8.self), radix: 16) else { refuse("--replay takes hex") }
		input.append(byte)
		at += 2
	}
	guard let target = targets.first(where: { $0.name == replay.name }) else { refuse("no target \(replay.name)") }
	Crash.install()
	print("\(replay.name): \(target.run(input) ? "taken" : "refused")")
	exit(0)
}

if let only {
	targets = targets.filter { $0.name == only }
	guard !targets.isEmpty else { refuse("no target \(only)") }
}

Crash.install()
print("pi2-remote-fuzz: seed \(seed), \(iterations.map { "\($0) iterations a target" } ?? "\(Int(seconds)) seconds"), \(targets.count) targets")
let budget = Duration.milliseconds(Int64(seconds * 1000 / Double(targets.count)))
var total: UInt64 = 0
for target in targets {
	let result = Fuzz.run(target, seed: seed, budget: budget, iterations: iterations)
	total += result.iterations
	print("ok   \(result.name): \(result.iterations) inputs, \(result.taken) taken, \(result.corpus) kept to start from")
}
print("pi2-remote-fuzz: \(total) inputs, no crash, nothing taken that should not have been")
