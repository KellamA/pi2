
import Foundation

/// The items an end has taken from the relay's mailbox, opened, verified and kept in the last 25 hours, by writer and
/// id, so that one handed over again is dropped (#767's security read). The relay is not trusted, and an item the Mac
/// writes that is not a state carries no number its reader could refuse a repeat by; a request item's nonce is the
/// engine's to check as well, but a receipt's is nobody's. An item lives a day at the relay at most, so 25 hours covers
/// every copy an honest relay holds; a reader refuses Mac items older than about a day besides (remotekit.md), which is
/// what closes a replay after that.
///
/// **Only what the caller has opened and verified goes in** (`RelayClient.remember`, after `SealedItem.openRequest` or
/// `openMacItem` took the item and it is kept): items the relay made up are never remembered, so they cannot fill the
/// memory and push a real one out. At its bound it takes nothing more until ids are 25 hours old: it never forgets a
/// younger one to make room.
///
/// Kept only in memory it would forget across a relaunch, so it is `Codable`: the phone keeps it in its store (#692)
/// and pi² Remote where it keeps its state, and each gives it back to the next client it makes.
public struct RelayItemMemory: Codable, Equatable, Sendable {
	/// How long an id is kept: a day, an item's longest life at the relay, and an hour for clocks.
	public static let keptFor: Int64 = 25 * 3_600_000
	/// The most ids kept. Far more than the mailboxes hold in a day (200 for the Mac, 100 for a device, each taken as fast
	/// as it comes), and only verified items count.
	public static let most = 20_000

	/// "<writer> <id>" and when it was remembered (ms since 1970).
	private var taken: [String: Int64] = [:]
	/// The earliest time in `taken`, so that forgetting what is old looks at the entries only when something is.
	private var oldest: Int64 = .max

	public init() {}

	/// Whether `item` was remembered in the last 25 hours.
	public func contains(_ item: RelayMailItem, at now: Int64) -> Bool {
		guard let at = taken[Self.key(item)] else { return false }
		return at > now - Self.keptFor
	}

	/// Remembers an item its reader has opened, verified and kept. Answers false if the memory is full of ids younger
	/// than 25 hours, and takes nothing then.
	public mutating func remember(_ item: RelayMailItem, at now: Int64) -> Bool {
		forget(before: now - Self.keptFor)
		let key = Self.key(item)
		guard taken[key] != nil || taken.count < Self.most else { return false }
		taken[key] = now
		oldest = min(oldest, now)
		return true
	}

	public var count: Int { taken.count }

	private static func key(_ item: RelayMailItem) -> String { "\(item.from.text) \(item.id.text)" }

	private mutating func forget(before time: Int64) {
		guard oldest <= time else { return }
		taken = taken.filter { $0.value > time }
		oldest = taken.values.min() ?? .max
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
		oldest = read.values.min() ?? .max
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(taken)
	}

	public static func == (a: RelayItemMemory, b: RelayItemMemory) -> Bool { a.taken == b.taken }
}
