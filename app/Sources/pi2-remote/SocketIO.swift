import Darwin
import Dispatch
import Foundation

/// One non-blocking socket, read and written on pi² Remote's one queue: the control connection to the engine, or a
/// phone's TCP connection. Everything pi² Remote holds is touched on that queue alone, which is why its classes are
/// `@unchecked Sendable`: the queue, not the compiler, keeps them from being raced.
package final class SocketIO: @unchecked Sendable {
	package let descriptor: Int32
	private let queue: DispatchQueue
	private var reader: DispatchSourceRead?
	private var writer: DispatchSourceWrite?
	private var writerRunning = false
	private var outgoing: [Data] = []
	private var offset = 0
	private(set) package var pending = 0
	private(set) package var isClosed = false
	private var sourcesLeft = 0

	/// Bytes as they come. Called on the queue.
	package var onBytes: (Data) -> Void = { _ in }
	/// The socket closed, from either side. Called once, on the queue.
	package var onClose: () -> Void = {}

	package init(descriptor: Int32, queue: DispatchQueue) {
		self.descriptor = descriptor
		self.queue = queue
		let flags = fcntl(descriptor, F_GETFL)
		_ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
		_ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
		var on: Int32 = 1
		_ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
	}

	/// Starts reading. Call once, on the queue.
	package func start() {
		let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
		let writer = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
		reader.setEventHandler { self.readAvailable() }
		writer.setEventHandler { self.flush() }
		let descriptor = self.descriptor
		sourcesLeft = 2
		// Strong references: each source lets go of its handlers once cancelled, which every socket is in the end.
		let done: @Sendable () -> Void = {
			self.sourcesLeft -= 1
			if self.sourcesLeft == 0 { Darwin.close(descriptor) }
		}
		reader.setCancelHandler(handler: done)
		writer.setCancelHandler(handler: done)
		self.reader = reader
		self.writer = writer
		reader.resume()
	}

	private func readAvailable() {
		var buffer = [UInt8](repeating: 0, count: 64 * 1024)
		while !isClosed {
			let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
			if count > 0 {
				onBytes(Data(buffer[0 ..< count]))
				continue
			}
			if count < 0, errno == EAGAIN || errno == EINTR { return }
			close()
			return
		}
	}

	/// Queues `data` to be written, in order.
	package func send(_ data: Data) {
		guard !isClosed, !data.isEmpty else { return }
		outgoing.append(data)
		pending += data.count
		flush()
	}

	private func flush() {
		while !isClosed, let first = outgoing.first {
			let count = first.withUnsafeBytes { bytes in Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset) }
			if count > 0 {
				offset += count
				pending -= count
				if offset == first.count {
					outgoing.removeFirst()
					offset = 0
				}
				continue
			}
			if count < 0, errno == EAGAIN || errno == EINTR {
				if !writerRunning, let writer {
					writerRunning = true
					writer.resume()
				}
				return
			}
			close()
			return
		}
		if writerRunning, let writer {
			writerRunning = false
			writer.suspend()
		}
	}

	/// Closes the socket once what is queued is written, as far as it can be at once; then closes it either way.
	package func finish() {
		flush()
		close()
	}

	package func close() {
		guard !isClosed else { return }
		isClosed = true
		outgoing.removeAll()
		pending = 0
		if let reader, let writer {
			reader.cancel()
			if !writerRunning { writer.resume() }
			writer.cancel()
		} else {
			Darwin.close(descriptor)
		}
		onClose()
		onClose = {}
		onBytes = { _ in }
	}
}
