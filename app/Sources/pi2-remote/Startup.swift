import Darwin
import Foundation
import RemoteKit
import Security

/// The checks pi² Remote makes before anything else, and before it reads any key (docs/iphone.md 5.5, decision 24): it
/// must be the engine's own child, on the socket pair the engine made for it. Otherwise it exits.
///
/// - Descriptor 3 is a Unix stream socket whose other end is this process's parent, run by the same user.
/// - The parent's process id is the one in `engine.pid` in the data folder.
/// - In a release build, the parent is the Node the app's bundle carries: its executable is that file, and its code
///   satisfies that file's designated requirement (as `PeerKit` checks the app). A development build's engine runs on
///   the Node on the person's PATH, so there is no such file to hold it to.
///
/// **These checks are not enough by themselves.** Every command an agent runs is the engine's own child too, with a
/// socket pair to the engine as its standard output: `exec "…/pi² Remote" 3>&1` keeps the command's process id and
/// passes every check here, in a release build the code check as well (the parent is the engine). What proves the
/// engine is the first line on descriptor 3: the engine sends `start` first, and only on the socket pair it made for
/// pi² Remote (`firstLine`). So pi² Remote reads and makes no key, reads no list of devices and writes nothing until a
/// well-formed `start` has come, and exits if none comes within ten seconds. A command that rewrites the data folder
/// (`engine.pid`) and starts an engine of its own goes round pi² on purpose, which [projects.md 7.3] leaves out and
/// pi² Remote's own list of device keys narrows.
package enum Startup {
	package static let controlDescriptor: Int32 = 3

	/// What the checks found: the engine's process id, and the data folder.
	package struct Verified: Sendable {
		package let engine: pid_t
		package let folder: DataFolder
	}

	/// Every check, in order; nothing here reads a key.
	package static func verify(kind: BuildKind, descriptor: Int32 = controlDescriptor) -> Result<Verified, Refusal> {
		do {
			let parent = try checkControlSocket(descriptor)
			let bundle = AppBundle.containing(executable: AppBundle.ownExecutable())
			let folder = try DataFolder.resolve(kind: kind, parent: parent, bundle: bundle)
			try checkEnginePID(folder: folder.url, parent: parent)
			if kind == .release {
				guard let bundle else { throw Refusal("pi² Remote is not inside an app's bundle (Contents/Helpers/pi² Remote.app)") }
				try checkParentCode(descriptor: descriptor, parent: parent, node: bundle.node)
			}
			return .success(Verified(engine: parent, folder: folder))
		} catch let refusal as Refusal {
			return .failure(refusal)
		} catch {
			return .failure(Refusal("the start-up checks failed: \(error)"))
		}
	}

	/// How long the engine's `start` may take to come: it is written as pi² Remote is started.
	package static let startWithin: TimeInterval = 10
	/// The longest first line taken: a `start` names the relay, the switches and at most a few devices.
	package static let startMaxLength = 64 * 1024

	/// The first line on `descriptor`, which must be the engine's `start`: `{"event":"remote","kind":"start",…}` with a
	/// relay, switches, a pairing (or null), a list of devices and a minimum build. Read a byte at a time, so that nothing
	/// after it is taken from the control connection. Anything else, nothing within `seconds`, or the connection
	/// closing, is a refusal.
	package static func firstLine(_ descriptor: Int32 = controlDescriptor, within seconds: TimeInterval = startWithin) -> Result<JSONValue, Refusal> {
		let deadline = Date().addingTimeInterval(seconds)
		var line = [UInt8]()
		while true {
			let left = deadline.timeIntervalSinceNow
			guard left > 0 else { return .failure(Refusal("the engine's start did not come within \(Int(seconds)) seconds: pi² Remote was not started by pi²'s engine")) }
			var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
			let ready = poll(&poller, 1, Int32(max(1, left * 1000)))
			if ready < 0, errno == EINTR { continue }
			guard ready > 0 else { continue }
			var byte: UInt8 = 0
			let count = read(descriptor, &byte, 1)
			if count < 0, errno == EINTR || errno == EAGAIN { continue }
			guard count == 1 else { return .failure(Refusal("the control connection closed before the engine's start")) }
			if byte == 0x0A { break }
			line.append(byte)
			guard line.count <= startMaxLength else { return .failure(Refusal("the first line on descriptor \(descriptor) is too long to be the engine's start")) }
		}
		guard let value = try? JSON.parse(line), value["event"]?.stringValue == "remote", value["kind"]?.stringValue == "start",
		      value["relay"]?.stringValue != nil, case .object? = value["switches"], let pairing = value["pairing"], pairing.isNull || pairing.stringValue != nil,
		      case .array? = value["devices"], value["minimumBuild"]?.stringValue != nil
		else { return .failure(Refusal("the first line on descriptor \(descriptor) is not the engine's start: pi² Remote was not started by pi²'s engine")) }
		return .success(value)
	}

	/// Descriptor `descriptor` is a Unix stream socket whose other end is this process's parent, of the same user.
	/// Returns the parent's process id.
	package static func checkControlSocket(_ descriptor: Int32) throws -> pid_t {
		var info = stat()
		guard fstat(descriptor, &info) == 0 else { throw Refusal("descriptor \(descriptor) is not open: pi² Remote was not started by pi²'s engine") }
		guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw Refusal("descriptor \(descriptor) is not a socket: pi² Remote was not started by pi²'s engine") }
		var address = sockaddr_storage()
		var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
		let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
		guard named == 0, Int32(address.ss_family) == AF_UNIX else { throw Refusal("descriptor \(descriptor) is not a Unix socket") }
		var type: Int32 = 0
		var size = socklen_t(MemoryLayout<Int32>.size)
		guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &size) == 0, type == SOCK_STREAM else { throw Refusal("descriptor \(descriptor) is not a stream socket") }
		var peer: pid_t = 0
		size = socklen_t(MemoryLayout<pid_t>.size)
		guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0 else { throw Refusal("descriptor \(descriptor) cannot say which process is at its other end") }
		let parent = getppid()
		guard parent > 1 else { throw Refusal("pi² Remote has no parent: the engine that started it is gone") }
		guard peer == parent else { throw Refusal("the other end of descriptor \(descriptor) is process \(peer), not the process that started pi² Remote (\(parent))") }
		var credentials = xucred()
		size = socklen_t(MemoryLayout<xucred>.size)
		guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &size) == 0, credentials.cr_uid == getuid() else {
			throw Refusal("the other end of descriptor \(descriptor) is not run by this user")
		}
		return parent
	}

	/// The data folder's `engine.pid` names `parent`. Read without following a link, and at most a few bytes.
	package static func checkEnginePID(folder: URL, parent: pid_t) throws {
		let path = folder.appendingPathComponent("engine.pid").path
		let file = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
		guard file >= 0 else { throw Refusal("the data folder has no engine.pid to check the engine against") }
		defer { close(file) }
		var bytes = [UInt8](repeating: 0, count: 32)
		let count = read(file, &bytes, bytes.count)
		guard count > 0 else { throw Refusal("engine.pid could not be read") }
		let text = String(decoding: bytes[0 ..< count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
		guard let named = pid_t(text), named == parent else {
			throw Refusal("the process that started pi² Remote (\(parent)) is not the engine engine.pid names")
		}
	}

	/// In a release build: the parent is the Node at `node` in the app's bundle, by its executable's path and by its
	/// code, checked from the socket's audit token (which also names the process's version, so a process id given to
	/// another process after the engine ended is not taken for it).
	package static func checkParentCode(descriptor: Int32, parent: pid_t, node: URL) throws {
		var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
		guard proc_pidpath(parent, &path, UInt32(path.count)) > 0 else { throw Refusal("the engine's executable could not be named") }
		let running = URL(fileURLWithPath: text(path)).resolvingSymlinksInPath().standardizedFileURL.path
		guard running == node.resolvingSymlinksInPath().standardizedFileURL.path else {
			throw Refusal("the process that started pi² Remote is not the Node in this app's bundle")
		}
		var token = audit_token_t()
		var size = socklen_t(MemoryLayout<audit_token_t>.size)
		guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { throw Refusal("the engine's connection has no audit token") }
		guard Int32(bitPattern: token.val.5) == parent else { throw Refusal("the engine's connection names another process") }
		switch codeMatches(token: token, executable: node) {
		case .success: return
		case let .failure(refusal): throw refusal
		}
	}

	/// Whether the process with `token` satisfies the designated requirement of the code at `executable`.
	package static func codeMatches(token: audit_token_t, executable: URL) -> Result<Void, Refusal> {
		var token = token
		var staticCode: SecStaticCode?
		guard SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
			return .failure(Refusal("the bundle's Node could not be read"))
		}
		var requirement: SecRequirement?
		guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else {
			return .failure(Refusal("the bundle's Node has no requirement to check against"))
		}
		let attributes = [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }] as CFDictionary
		var guest: SecCode?
		guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else {
			return .failure(Refusal("the engine's process could not be found"))
		}
		guard SecCodeCheckValidity(guest, [], requirement) == errSecSuccess else {
			return .failure(Refusal("the engine's process is not the Node in this app's bundle"))
		}
		return .success(())
	}

	/// The audit token of the process at the other end of `descriptor`, for the check's own test of `codeMatches`.
	package static func peerToken(_ descriptor: Int32) -> audit_token_t? {
		var token = audit_token_t()
		var size = socklen_t(MemoryLayout<audit_token_t>.size)
		return getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 ? token : nil
	}
}

/// The app bundle pi² Remote is inside: `<app>/Contents/Helpers/pi² Remote.app/Contents/MacOS/pi² Remote`.
package struct AppBundle: Sendable, Equatable {
	package let url: URL

	/// The Node a release build carries, which runs its engine.
	package var node: URL { url.appendingPathComponent("Contents/Resources/node") }

	/// This process's executable, its links resolved.
	package static func ownExecutable() -> URL? {
		var size: UInt32 = 0
		_ = _NSGetExecutablePath(nil, &size)
		var path = [CChar](repeating: 0, count: Int(size) + 1)
		guard _NSGetExecutablePath(&path, &size) == 0 else { return nil }
		return URL(fileURLWithPath: text(path)).resolvingSymlinksInPath().standardizedFileURL
	}

	/// The outer app's bundle, if `executable` is where build.sh puts pi² Remote; nil otherwise.
	package static func containing(executable: URL?) -> AppBundle? {
		guard let executable else { return nil }
		let macOS = executable.deletingLastPathComponent()
		let contents = macOS.deletingLastPathComponent()
		let helper = contents.deletingLastPathComponent()
		let helpers = helper.deletingLastPathComponent()
		let outerContents = helpers.deletingLastPathComponent()
		let outer = outerContents.deletingLastPathComponent()
		guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", helper.pathExtension == "app",
		      helpers.lastPathComponent == "Helpers", outerContents.lastPathComponent == "Contents", outer.pathExtension == "app"
		else { return nil }
		return AppBundle(url: outer)
	}

	/// The outer app's bundle id, read from its Info.plist; nil if it has none.
	package var bundleID: String? {
		guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
		      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
		else { return nil }
		return plist["CFBundleIdentifier"] as? String
	}
}

/// The text of a C string in `buffer`, up to its first zero byte.
func text(_ buffer: [CChar]) -> String {
	let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
	return String(decoding: bytes, as: UTF8.self)
}
