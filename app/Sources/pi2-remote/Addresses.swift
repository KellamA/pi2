import Darwin
import Foundation

/// An IP address, as the listener sees a peer and as the Mac's own are listed. An IPv4 address mapped into IPv6 (which a
/// dual-stack socket reports for an IPv4 peer) is read as the IPv4 address it is.
package enum IPAddress: Hashable, Sendable, CustomStringConvertible {
	case v4([UInt8])
	case v6([UInt8])

	package init?(_ address: UnsafePointer<sockaddr>) {
		switch Int32(address.pointee.sa_family) {
		case AF_INET:
			let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
			self = .v4(bytes)
		case AF_INET6:
			let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
			if bytes[0 ..< 10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
				self = .v4(Array(bytes[12 ..< 16]))
			} else {
				self = .v6(bytes)
			}
		default:
			return nil
		}
	}

	package init?(_ text: String) {
		var four = in_addr()
		if inet_pton(AF_INET, text, &four) == 1 {
			self = .v4(withUnsafeBytes(of: four) { Array($0) })
			return
		}
		var six = in6_addr()
		guard inet_pton(AF_INET6, text, &six) == 1 else { return nil }
		let bytes = withUnsafeBytes(of: six) { Array($0) }
		if bytes[0 ..< 10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
			self = .v4(Array(bytes[12 ..< 16]))
		} else {
			self = .v6(bytes)
		}
	}

	package var description: String {
		switch self {
		case let .v4(bytes): return bytes.map(String.init).joined(separator: ".")
		case let .v6(bytes):
			var address = in6_addr()
			withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
			var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
			return inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)).map { String(cString: $0) } ?? "?"
		}
	}

	/// As the pairing payload and the `device` event write an address with its port: `a.b.c.d:port` or `[v6]:port`.
	package func withPort(_ port: UInt16) -> String {
		switch self {
		case .v4: "\(description):\(port)"
		case .v6: "[\(description)]:\(port)"
		}
	}

	package var isLoopback: Bool {
		switch self {
		case let .v4(b): b[0] == 127
		case let .v6(b): b[0 ..< 15].allSatisfy { $0 == 0 } && b[15] == 1
		}
	}

	package var isLinkLocal: Bool {
		switch self {
		case let .v4(b): b[0] == 169 && b[1] == 254
		case let .v6(b): b[0] == 0xFE && b[1] & 0xC0 == 0x80
		}
	}

	/// Whether a connection from this address came by the `home` path, on the Mac's own network (loopback, link-local,
	/// private and unique-local addresses), or by `direct`, from another address the phone could reach (a private
	/// network's shared range, as Tailscale's, or any address with **Direct from any address** on): the path the engine
	/// is told (docs/iphone.md 1, 5.4). The Mac cannot see how the phone found it; the address is what it has.
	package var path: String {
		if isLoopback || isLinkLocal { return "home" }
		switch self {
		case let .v4(b): return b[0] == 10 || (b[0] == 172 && b[1] & 0xF0 == 16) || (b[0] == 192 && b[1] == 168) ? "home" : "direct"
		case let .v6(b): return b[0] & 0xFE == 0xFC ? "home" : "direct"
		}
	}

	/// Whether the home listener takes a connection from this address while **Direct from any address** is off
	/// (docs/iphone.md 5.4, decision 32): link-local, private (RFC 1918), unique-local (fc00::/7), and the shared range
	/// private networks use (100.64.0.0/10, as Tailscale does); and loopback, which is this Mac.
	package var isLocalOrPrivate: Bool {
		if isLoopback || isLinkLocal { return true }
		switch self {
		case let .v4(b):
			return b[0] == 10 || (b[0] == 172 && b[1] & 0xF0 == 16) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] & 0xC0 == 64)
		case let .v6(b):
			return b[0] & 0xFE == 0xFC
		}
	}
}

package enum MacAddresses {
	/// The Mac's addresses the phone may try (5.4, 5.6), each with `port`: every address of an interface that is up and
	/// not loopback, IPv4 and IPv6, but link-local IPv6, which needs a zone the pairing payload cannot carry
	/// (remotekit.md). At most 16, as the payload takes.
	package static func current(port: UInt16) -> [String] {
		var first: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&first) == 0, let first else { return [] }
		defer { freeifaddrs(first) }
		var found: [String] = []
		var cursor: UnsafeMutablePointer<ifaddrs>? = first
		while let entry = cursor {
			defer { cursor = entry.pointee.ifa_next }
			let flags = Int32(entry.pointee.ifa_flags)
			guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.pointee.ifa_addr, let ip = IPAddress(UnsafePointer(address)) else { continue }
			if case .v6 = ip, ip.isLinkLocal { continue }
			let text = ip.withPort(port)
			if !found.contains(text) { found.append(text) }
		}
		return Array(found.prefix(16))
	}
}

/// How many connections the home listener holds before they authenticate, and how often a peer may send a first
/// message (5.4, 3.4; the security reads of #767 and #675). A first message costs pi² Remote eight trials of key
/// agreement before anything is authenticated, so it is limited by source and in all; a handshake that found its device
/// is limited for that device too. A source is an IPv4 address or an IPv6 /64, which one host holds whole.
package final class Admission: @unchecked Sendable {
	package static let maxPending = 8
	package static let maxPendingPerSource = 4
	package static let firstMessagesPerSourcePerMinute = 20
	/// First messages that found no paired device, in all: eight trials cost under a millisecond, so this many a minute
	/// is cheap, and a real phone's, which find their device, are not counted in it (D1).
	package static let unknownFirstMessagesPerMinute = 600
	package static let handshakesPerDevicePerMinute = 6
	package static let window: TimeInterval = 60
	/// How long a connection may take to send its first message (D1): a phone sends it at once.
	package static let firstMessageWithin: TimeInterval = 3
	/// How long a first message that found its device is remembered, so that the same one again (a replay) is closed
	/// before it uses up the device's handshakes (D1); and the most remembered.
	package static let replayKept: TimeInterval = 600
	package static let replayMax = 1024

	package enum Admit: Equatable { case taken, sourceFull, allFull }

	private var pending: [IPAddress: Int] = [:]
	private var firstMessages: [IPAddress: [TimeInterval]] = [:]
	private var unknown: [TimeInterval] = []
	private var handshakes: [String: [TimeInterval]] = [:]
	private var seen: [Data: TimeInterval] = [:]

	package init() {}

	package var pendingCount: Int { pending.values.reduce(0, +) }

	/// A new connection from `source`, before it authenticates: taken, or which limit it is over.
	package func admit(_ source: IPAddress) -> Admit {
		let key = source.limitKey
		guard pending[key, default: 0] < Self.maxPendingPerSource else { return .sourceFull }
		guard pendingCount < Self.maxPending else { return .allFull }
		pending[key, default: 0] += 1
		return .taken
	}

	/// The connection from `source` authenticated, or closed.
	package func release(_ source: IPAddress) {
		let key = source.limitKey
		guard let count = pending[key] else { return }
		pending[key] = count > 1 ? count - 1 : nil
	}

	/// A first message from `source`, before any key agreement: allowed, or over a limit.
	package func firstMessage(from source: IPAddress, now: TimeInterval) -> Bool {
		let key = source.limitKey
		unknown.removeAll { now - $0 >= Self.window }
		var mine = (firstMessages[key] ?? []).filter { now - $0 < Self.window }
		guard unknown.count < Self.unknownFirstMessagesPerMinute, mine.count < Self.firstMessagesPerSourcePerMinute else {
			firstMessages[key] = mine
			return false
		}
		mine.append(now)
		firstMessages[key] = mine
		if firstMessages.count > 4096 { firstMessages = firstMessages.filter { !$0.value.isEmpty && now - $0.value.last! < Self.window } }
		return true
	}

	/// A first message found no paired device: it counts against the limit for all.
	package func unknownFirstMessage(now: TimeInterval) { unknown.append(now) }

	/// Whether this first message was seen before, from a device, within `replayKept` (its ephemeral key, the first 32
	/// bytes, is fresh in every real handshake).
	package func replayed(_ message: Data, now: TimeInterval) -> Bool {
		guard let at = seen[Data(message.prefix(32))] else { return false }
		return now - at < Self.replayKept
	}

	/// A first message that found its device, remembered.
	package func remember(_ message: Data, now: TimeInterval) {
		seen = seen.filter { now - $0.value < Self.replayKept }
		while seen.count >= Self.replayMax, let oldest = seen.min(by: { $0.value < $1.value }) { seen.removeValue(forKey: oldest.key) }
		seen[Data(message.prefix(32))] = now
	}

	/// A handshake for `device`: allowed, or more than a few this minute (3.4).
	package func handshake(for device: String, now: TimeInterval) -> Bool {
		var mine = (handshakes[device] ?? []).filter { now - $0 < Self.window }
		guard mine.count < Self.handshakesPerDevicePerMinute else {
			handshakes[device] = mine
			return false
		}
		mine.append(now)
		handshakes[device] = mine
		return true
	}
}

extension IPAddress {
	/// What the listener's limits count as one source: an IPv4 address, or the /64 an IPv6 address is in.
	package var limitKey: IPAddress {
		switch self {
		case .v4: self
		case let .v6(bytes): .v6(Array(bytes[0 ..< 8]) + Array(repeating: 0, count: 8))
		}
	}

	/// 100.64.0.0/10, RFC 6598's shared address space: carrier-grade NAT's, and the range private networks such as
	/// Tailscale number their devices in.
	package var isSharedAddressSpace: Bool {
		if case let .v4(b) = self { return b[0] == 100 && b[1] & 0xC0 == 64 }
		return false
	}

	/// The local address `descriptor` is bound to (for an accepted connection, the one the peer reached).
	package static func local(of descriptor: Int32) -> IPAddress? {
		var address = sockaddr_storage()
		var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
		let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
		guard named == 0 else { return nil }
		return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { IPAddress($0) } }
	}
}

extension MacAddresses {
	/// The name of the interface that has `address`, or nil.
	package static func interface(of address: IPAddress) -> String? {
		var first: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&first) == 0, let first else { return nil }
		defer { freeifaddrs(first) }
		var cursor: UnsafeMutablePointer<ifaddrs>? = first
		while let entry = cursor {
			defer { cursor = entry.pointee.ifa_next }
			if let raw = entry.pointee.ifa_addr, IPAddress(UnsafePointer(raw)) == address { return String(cString: entry.pointee.ifa_name) }
		}
		return nil
	}
}

/// Whether the home listener takes, or keeps, a connection from `peer` (5.4, decision 32; #675's security read B, M4
/// and D2). A development build's listener is on 127.0.0.1 alone, so anything that reaches it is taken. A release
/// build's takes anything with **Direct from any address** on; with it off, link-local, private (RFC 1918) and
/// unique-local addresses, and loopback; and from 100.64.0.0/10 only a connection that came by a tunnel interface
/// (`utun…`, as Tailscale's), since the same range is carrier-grade NAT's, whose other customers a Mac numbered in it
/// would take otherwise.
package func admits(peer: IPAddress, arrivedOn interface: String?, kind: BuildKind, direct: Bool) -> Bool {
	guard kind == .release, !direct else { return true }
	if peer.isSharedAddressSpace { return interface?.hasPrefix("utun") == true }
	return peer.isLocalOrPrivate
}

/// The home path's TCP listener (5.4): in loopback mode on 127.0.0.1 alone; otherwise on every address, IPv4 and IPv6,
/// with a peer outside the local and private ranges refused unless **Direct from any address** is on. Plain BSD
/// sockets: in loopback mode nothing here can ask macOS for the Local Network privilege, and nothing is advertised.
package final class Listener: @unchecked Sendable {
	package let loopbackOnly: Bool
	package private(set) var port: UInt16 = 0
	private let descriptor: Int32
	private let queue: DispatchQueue
	private var source: DispatchSourceRead?

	/// A connection accepted, with its peer's address. The callee owns the descriptor.
	package var onAccept: (Int32, IPAddress) -> Void = { descriptor, _ in close(descriptor) }

	package init(loopbackOnly: Bool, queue: DispatchQueue) throws {
		self.loopbackOnly = loopbackOnly
		self.queue = queue
		let family = loopbackOnly ? AF_INET : AF_INET6
		descriptor = socket(family, SOCK_STREAM, 0)
		guard descriptor >= 0 else { throw Refusal("the home listener could not be made") }
		_ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
		var bound: Int32
		if loopbackOnly {
			var address = sockaddr_in()
			address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
			address.sin_family = sa_family_t(AF_INET)
			address.sin_port = 0
			address.sin_addr.s_addr = inet_addr("127.0.0.1")
			bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
		} else {
			var dual: Int32 = 0
			_ = setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &dual, socklen_t(MemoryLayout<Int32>.size))
			var address = sockaddr_in6()
			address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
			address.sin6_family = sa_family_t(AF_INET6)
			address.sin6_port = 0
			address.sin6_addr = in6addr_any
			bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
		}
		guard bound == 0, listen(descriptor, 16) == 0 else {
			close(descriptor)
			throw Refusal("the home listener could not listen (\(String(cString: strerror(errno))))")
		}
		var address = sockaddr_storage()
		var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
		_ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
		port = withUnsafePointer(to: &address) { pointer in
			loopbackOnly
				? pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
				: pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
		}
		_ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
	}

	package func start() {
		let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
		source.setEventHandler { self.acceptAll() }
		let descriptor = self.descriptor
		source.setCancelHandler { close(descriptor) }
		self.source = source
		source.resume()
	}

	private func acceptAll() {
		while true {
			var address = sockaddr_storage()
			var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
			let connection = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(descriptor, $0, &length) } }
			guard connection >= 0 else { return }
			let peer = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { IPAddress($0) } }
			guard let peer else {
				close(connection)
				continue
			}
			onAccept(connection, peer)
		}
	}

	package func stop() {
		if let source {
			source.cancel()
		} else {
			close(descriptor)
		}
		source = nil
	}

	/// The addresses a phone may try for this listener.
	package var addresses: [String] {
		loopbackOnly ? [IPAddress.v4([127, 0, 0, 1]).withPort(port)] : MacAddresses.current(port: port)
	}
}
