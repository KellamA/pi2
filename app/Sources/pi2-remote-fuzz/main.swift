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

import Foundation

func argument(_ name: String) -> String? {
	guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
	return CommandLine.arguments[index + 1]
}

setvbuf(stdout, nil, _IOLBF, 0)
let seed = UInt64(argument("--seed") ?? "674") ?? 674
let seconds = Double(argument("--seconds") ?? "60") ?? 60
let iterations = argument("--iterations").flatMap { UInt64($0) }
var targets: [Target]
do {
	targets = try Targets.all(seed: seed)
} catch {
	print("pi2-remote-fuzz: could not make the targets: \(error)")
	exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--replay"), index + 2 < CommandLine.arguments.count {
	let name = CommandLine.arguments[index + 1]
	let hex = Array(CommandLine.arguments[index + 2].utf8)
	var input: [UInt8] = []
	var at = 0
	while at + 1 < hex.count, let byte = UInt8(String(decoding: hex[at...at + 1], as: UTF8.self), radix: 16) {
		input.append(byte)
		at += 2
	}
	guard let target = targets.first(where: { $0.name == name }) else {
		print("pi2-remote-fuzz: no target \(name)")
		exit(1)
	}
	Crash.install()
	print("\(name): \(target.run(input) ? "taken" : "refused")")
	exit(0)
}

if let only = argument("--target") { targets = targets.filter { $0.name == only } }
guard !targets.isEmpty else {
	print("pi2-remote-fuzz: no such target")
	exit(1)
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
