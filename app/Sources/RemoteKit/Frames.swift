import Foundation

// Framing (iphone.md 5.2). Outside the channel, on TCP, each Noise message is preceded by its length in two bytes,
// big-endian; on the relay each is one binary WebSocket message, which needs nothing here. Inside the channel, each
// transport message's plaintext is one frame:
//
//     kind (1 byte) | length of the body (2 bytes, big-endian) | body | padding (zero bytes)
//
// The padding lets a frame's size say less (the phone pads its frames to the next 256 bytes). It is all zeros, and a
// frame with anything else after its body is refused.

/// What a frame is (iphone.md 5.2).
public enum FrameKind: UInt8, Sendable, CaseIterable {
	/// The last or only piece of an engine line.
	case data = 1
	/// A piece of an engine line that goes on in the next frame.
	case more = 2
	/// How many lines the sender has received in all, as eight bytes, big-endian (5.8).
	case ack = 3
	/// Nothing; keeps a path's connection alive. Its body is empty.
	case ping = 4
	/// The end of the channel, as Noise asks the application to say. Its body is empty.
	case bye = 5
}

public struct Frame: Equatable, Sendable {
	public static let headerLength = 3
	/// The longest body a frame can carry: a transport message's plaintext, less the header.
	public static let maxBodyLength = Noise.maxPlaintextLength - headerLength
	/// What the phone pads its frames to.
	public static let paddingBlock = 256

	public let kind: FrameKind
	public let body: Data

	public init(_ kind: FrameKind, _ body: Data = Data()) throws {
		guard body.count <= Self.maxBodyLength else { throw RemoteKitError("frame", "a body too long") }
		switch kind {
		case .ack: guard body.count == 8 else { throw RemoteKitError("frame", "an ack's body is not eight bytes") }
		case .ping, .bye: guard body.isEmpty else { throw RemoteKitError("frame", "a body where none belongs") }
		case .more: guard !body.isEmpty else { throw RemoteKitError("frame", "an empty piece of a line") }
		case .data: break
		}
		self.kind = kind
		self.body = body
	}

	public static func ack(_ count: UInt64) -> Frame { try! Frame(.ack, Bytes.bigEndian(count)) }

	/// The count an ack carries.
	public var ackCount: UInt64? { kind == .ack ? Bytes.readUInt64(body, at: 0) : nil }

	/// The frame's bytes, padded with zeros to the next multiple of `padTo` (never past the longest plaintext).
	public func encoded(padTo block: Int? = nil) -> Data {
		var out = Data([kind.rawValue])
		out.append(Bytes.bigEndian(UInt16(body.count)))
		out.append(body)
		if let block, block > 1 {
			let padded = min((out.count + block - 1) / block * block, Noise.maxPlaintextLength)
			out.append(Data(repeating: 0, count: padded - out.count))
		}
		return out
	}

	/// Reads one frame from a transport message's plaintext: its header, its body, and padding that is all zeros.
	public static func decode(_ bytes: Data) throws -> Frame {
		guard bytes.count >= headerLength else { throw RemoteKitError("frame", "too short for its header") }
		guard bytes.count <= Noise.maxPlaintextLength else { throw RemoteKitError("frame", "too long") }
		let start = bytes.startIndex
		guard let kind = FrameKind(rawValue: bytes[start]) else { throw RemoteKitError("frame", "an unknown kind") }
		let length = Int(Bytes.readUInt16(bytes, at: 1))
		guard headerLength + length <= bytes.count else { throw RemoteKitError("frame", "a body longer than the frame") }
		let body = Data(bytes[(start + headerLength)..<(start + headerLength + length)])
		let padding = bytes[(start + headerLength + length)...]
		guard !padding.contains(where: { $0 != 0 }) else { throw RemoteKitError("frame", "bytes after the body that are not padding") }
		return try Frame(kind, body)
	}
}

/// An engine line cut into frames: `more` frames, then a `data` frame.
public enum Lines {
	/// The longest line a channel takes until the device is attached: its own first lines (the Mac's proof, `pair` with
	/// its attestation, `attach`) are a few kilobytes at most. So a pairing claimer, who needs only `s`, or a device that
	/// has not yet attached, can make the other end hold no more than this.
	public static let firstLinesMaxLength = 64 * 1024

	/// The longest line taken once the device is attached, unless the channel is given another: a greeting is the size of
	/// the person's library (iphone.md 5.9), so this is generous.
	public static let defaultMaxLength = 64 * 1024 * 1024

	public static func frames(for line: Data, maxBody: Int = Frame.maxBodyLength) throws -> [Frame] {
		guard !line.isEmpty else { throw RemoteKitError("line", "empty") }
		// A line break inside a line would let one line pass as two where pi² Remote writes them to the engine.
		guard !line.contains(0x0a), !line.contains(0x0d) else { throw RemoteKitError("line", "holds a line break") }
		let size = max(1, min(maxBody, Frame.maxBodyLength))
		var frames: [Frame] = []
		var offset = line.startIndex
		while line.endIndex - offset > size {
			frames.append(try Frame(.more, Data(line[offset..<(offset + size)])))
			offset += size
		}
		frames.append(try Frame(.data, Data(line[offset...])))
		return frames
	}
}

/// Puts lines back together from `more` and `data` frames.
public struct LineAssembler: Sendable {
	/// The longest line taken: a frame that would pass it is refused before its bytes are held.
	public var maxLength: Int
	private var pending = Data()

	public init(maxLength: Int = Lines.defaultMaxLength) {
		self.maxLength = maxLength
	}

	/// Whether a line has been begun and not finished.
	public var isPartway: Bool { !pending.isEmpty }

	/// How much of a line begun and not finished it holds, in bytes: zero between lines (#908).
	public var unfinishedLength: Int { pending.count }

	/// Takes a `data` or `more` frame; gives back the line a `data` frame ends.
	public mutating func take(_ frame: Frame) throws -> Data? {
		guard frame.kind == .data || frame.kind == .more else { throw RemoteKitError("line", "a frame that is not part of a line") }
		guard pending.count + frame.body.count <= maxLength else { throw RemoteKitError("line", "longer than allowed") }
		guard !frame.body.contains(0x0a), !frame.body.contains(0x0d) else { throw RemoteKitError("line", "holds a line break") }
		pending.append(frame.body)
		guard frame.kind == .data else { return nil }
		let line = pending
		pending = Data()
		guard !line.isEmpty else { throw RemoteKitError("line", "empty") }
		return line
	}
}

/// The TCP path's framing: each Noise message preceded by its length, two bytes, big-endian.
public struct LengthFraming: Sendable {
	/// No Noise message pi² sends is shorter: a transport message is at least its tag.
	public static let minLength = Noise.tagLength

	private var buffer = [UInt8]()

	public init() {}

	public static func encode(_ message: Data) throws -> Data {
		guard message.count >= minLength, message.count <= Noise.maxMessageLength else { throw RemoteKitError("TCP framing", "a message of an impossible length") }
		return Bytes.bigEndian(UInt16(message.count)) + message
	}

	/// Bytes waiting for the rest of their message.
	public var buffered: Int { buffer.count }

	/// Takes bytes as they arrive and gives back each whole message they finish. Linear in what is pushed: the messages
	/// are read where they lie, and what is left is moved to the front once.
	public mutating func push(_ bytes: Data) throws -> [Data] {
		buffer.append(contentsOf: bytes)
		var messages: [Data] = []
		var offset = 0
		while buffer.count - offset >= 2 {
			let length = Int(buffer[offset]) << 8 | Int(buffer[offset + 1])
			guard length >= Self.minLength else {
				buffer.removeAll()
				throw RemoteKitError("TCP framing", "a message of an impossible length")
			}
			guard buffer.count - offset >= 2 + length else { break }
			messages.append(Data(buffer[(offset + 2)..<(offset + 2 + length)]))
			offset += 2 + length
		}
		buffer.removeFirst(offset)
		return messages
	}
}
