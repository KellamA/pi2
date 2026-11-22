import Foundation
import RemoteKit

/// SplitMix64: a small generator whose whole sequence follows from its seed, so a run is the same run again.
struct SplitMix64: RandomNumberGenerator {
	var state: UInt64

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}

	mutating func bytes(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8.random(in: 0...255, using: &self) } }

	/// A stable number for a name (FNV-1a), so each target's sequence depends on the seed and its name alone.
	static func hash(_ name: String) -> UInt64 {
		var hash: UInt64 = 0xcbf2_9ce4_8422_2325
		for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
		return hash
	}
}

/// One parser under the fuzzer: inputs to start from, words that mean something to it, and a run that answers whether
/// the input was taken. A run checks what must hold of what it takes, and calls `Fuzz.violation` if it does not.
struct Target {
	let name: String
	var seeds: [[UInt8]]
	var dictionary: [[UInt8]] = []
	var maxLength = 4096
	let run: ([UInt8]) -> Bool
}

enum Fuzz {
	static let interesting: [UInt8] = [0, 1, 2, 0x7f, 0x80, 0xff, 0xfe, 0x22, 0x5c, 0x7b, 0x7d, 0x5b, 0x5d, 0x2c, 0x3a, 0x25, 0x26, 0x3d, 0x0a, 0x2b]

	/// Something a target took that it must not have, or that did not hold: say what, with the input, and stop.
	static func violation(_ target: String, _ what: String, _ input: [UInt8]) -> Never {
		print("pi2-remote-fuzz: \(target): \(what), on this input (hex):")
		print(input.map { String(format: "%02x", $0) }.joined())
		exit(1)
	}

	/// Runs a parser and answers whether it took the input; any error but RemoteKit's own is a violation, since every
	/// refusal must be one RemoteKit names (Errors.swift).
	static func takes(_ target: String, _ input: [UInt8], _ body: () throws -> Void) -> Bool {
		do {
			try body()
			return true
		} catch is RemoteKitError {
			return false
		} catch {
			violation(target, "threw \(type(of: error)), not a RemoteKitError", input)
		}
	}

	static func mutate(_ input: [UInt8], corpus: [[UInt8]], dictionary: [[UInt8]], maxLength: Int, using rng: inout SplitMix64) -> [UInt8] {
		var bytes = input
		for _ in 0..<Int.random(in: 1...4, using: &rng) {
			let count = bytes.count
			switch Int.random(in: 0..<13, using: &rng) {
			case 0 where count > 0:
				bytes[Int.random(in: 0..<count, using: &rng)] ^= 1 << UInt8.random(in: 0..<8, using: &rng)
			case 1 where count > 0:
				bytes[Int.random(in: 0..<count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
			case 2 where count > 0:
				bytes[Int.random(in: 0..<count, using: &rng)] = interesting.randomElement(using: &rng)!
			case 3:
				bytes.insert(contentsOf: rng.bytes(Int.random(in: 1...8, using: &rng)), at: Int.random(in: 0...count, using: &rng))
			case 4 where count > 0:
				let start = Int.random(in: 0..<count, using: &rng)
				bytes.removeSubrange(start..<min(count, start + Int.random(in: 1...16, using: &rng)))
			case 5 where count > 0:
				let start = Int.random(in: 0..<count, using: &rng)
				let piece = bytes[start..<min(count, start + Int.random(in: 1...32, using: &rng))]
				bytes.insert(contentsOf: piece, at: Int.random(in: 0...count, using: &rng))
			case 6 where count > 0:
				bytes.removeLast(Int.random(in: 1...count, using: &rng))
			case 7:
				bytes += rng.bytes(Int.random(in: 1...32, using: &rng))
			case 8 where !corpus.isEmpty:
				let other = corpus.randomElement(using: &rng)!
				if !other.isEmpty {
					let cut = Int.random(in: 0...count, using: &rng)
					let from = Int.random(in: 0..<other.count, using: &rng)
					bytes = Array(bytes[..<cut]) + Array(other[from...])
				}
			case 9 where !dictionary.isEmpty:
				bytes.insert(contentsOf: dictionary.randomElement(using: &rng)!, at: Int.random(in: 0...count, using: &rng))
			case 10 where count > 1:
				bytes.swapAt(Int.random(in: 0..<count, using: &rng), Int.random(in: 0..<count, using: &rng))
			case 11 where count > 0:
				let at = Int.random(in: 0..<count, using: &rng)
				bytes[at] = Bool.random(using: &rng) ? bytes[at] &+ 1 : bytes[at] &- 1
			case 12 where count > 1:
				// A length field: two bytes, big-endian, of a value that matters.
				let at = Int.random(in: 0..<(count - 1), using: &rng)
				let value = [0, 1, 15, 16, 17, 255, 256, 65_516, 65_519, 65_535, count, count - 3].randomElement(using: &rng)!
				bytes[at] = UInt8(truncatingIfNeeded: value >> 8)
				bytes[at + 1] = UInt8(truncatingIfNeeded: value)
			default:
				bytes.append(UInt8.random(in: 0...255, using: &rng))
			}
		}
		return bytes.count > maxLength ? Array(bytes.prefix(maxLength)) : bytes
	}

	struct Result {
		let name: String
		let iterations: UInt64
		let taken: UInt64
		let corpus: Int
	}

	/// Runs one target until `budget` has passed, or for `iterations` if given.
	static func run(_ target: Target, seed: UInt64, budget: Duration, iterations limit: UInt64?) -> Result {
		var rng = SplitMix64(state: seed ^ SplitMix64.hash(target.name))
		var corpus = target.seeds
		var known = Set(corpus)
		let clock = ContinuousClock()
		let end = clock.now + budget
		var iteration: UInt64 = 0
		var taken: UInt64 = 0
		// Every seed first, as it is.
		for seed in target.seeds {
			Crash.record(target: target.name, iteration: iteration, input: seed)
			if target.run(seed) { taken += 1 }
			iteration += 1
		}
		while true {
			if let limit {
				if iteration >= limit { break }
			} else if iteration % 32 == 0, clock.now >= end {
				break
			}
			let input: [UInt8]
			if Int.random(in: 0..<16, using: &rng) == 0 || corpus.isEmpty {
				input = rng.bytes(Int.random(in: 0...min(target.maxLength, 512), using: &rng))
			} else {
				input = mutate(corpus.randomElement(using: &rng)!, corpus: corpus, dictionary: target.dictionary, maxLength: target.maxLength, using: &rng)
			}
			Crash.record(target: target.name, iteration: iteration, input: input)
			if target.run(input) {
				taken += 1
				// What a parser took is a good place to start from again: it reaches deeper than what it refused.
				if corpus.count < 1024, known.insert(input).inserted { corpus.append(input) }
			}
			iteration += 1
		}
		return Result(name: target.name, iterations: iteration, taken: taken, corpus: corpus.count)
	}
}
