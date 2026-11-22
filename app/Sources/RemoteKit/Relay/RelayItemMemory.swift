
import Foundation

/// The items an end has taken from the relay's mailbox in the last 25 hours, by writer and id, so that one handed over
/// twice is taken once (#767's security read). The relay is not trusted, and an item the Mac writes that is not a state
/// carries no number its reader could refuse a repeat by; a request item's nonce is the engine's to check as well, but a
/// receipt's is nobody's. An item lives a day at the relay at most, so 25 hours covers every copy it can hand over.
///
/// The relay's client keeps one in memory and checks every `take` against it. Kept only in memory it would forget
/// across a relaunch, so it is `Codable`: the phone keeps it in its store (#692) and the Mac where pi² Remote keeps its
/// state, and each gives it back to the next client it makes.
public struct RelayItemMemory: Codable, Equatable, Sendable {
	/// How long an id is kept: a day, an item's longest life at the relay, and an hour for clocks.
	public static let keptFor: Int64 = 25 * 3_600_000
	/// The most ids kept; the oldest go first. Far more than the mailboxes hold in a day (200 for the Mac, 100 for a
	/// device, each taken as fast as it comes).
	public static let most = 20_000

	/// "<writer> <id>" and when it was taken (ms since 1970).
	private var taken: [String: Int64] = [:]

	public init() {}

	/// Whether `item` was not taken in the last 25 hours; remembers it if so.
	public mutating func isNew(_ item: RelayMailItem, at now: Int64) -> Bool {
		forget(before: now - Self.keptFor)
		let key = "\(item.from.text) \(item.id.text)"
		if let at = taken[key], at > now - Self.keptFor { return false }
		taken[key] = now
		if taken.count > Self.most {
			for (oldest, _) in taken.sorted(by: { $0.value < $1.value }).prefix(taken.count - Self.most) { taken[oldest] = nil }
		}
		return true
	}

	public var count: Int { taken.count }

	private mutating func forget(before time: Int64) {
		guard taken.values.contains(where: { $0 <= time }) else { return }
		taken = taken.filter { $0.value > time }
	}

	// Read back strictly: a memory written by another hand is taken only if every entry is one this type writes.
	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		let read = try container.decode([String: Int64].self)
		guard read.count <= Self.most else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "too many items") }
		for key in read.keys {
			let parts = key.split(separator: " ", omittingEmptySubsequences: false)
			guard parts.count == 2, parts[0] == "mac" || DeviceID(String(parts[0])) != nil, ItemID(String(parts[1])) != nil else {
				throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an item's writer and id")
			}
		}
		taken = read
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(taken)
	}
}
