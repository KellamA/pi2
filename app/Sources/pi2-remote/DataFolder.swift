import Darwin
import Foundation

/// The data folder of the engine that started pi² Remote: where `engine.pid` is, where its log goes, and in a development
/// build, where its keys and its list of devices are kept in files.
///
/// - **Release**: the usual data folder, `~/Library/Application Support/pi2`, the home folder taken from the user
///   database, never from the environment. A release build reads no variable or file that could point it elsewhere
///   (decision 24), so a release copy run on another data folder (`PI2_HOME`, as `check-release-build.mts` runs one)
///   finds its engine's process id missing there, and exits: it has no remote access.
/// - **Development**: the data folder the engine runs on, which a development engine always has in its environment as
///   `PI2_HOME` (the app sets it, as do the tests), read from the parent's own environment; failing that, the one
///   the app's bundle id names, as `DevelopmentBuild` names it. Never the usual data folder, even when named: that
///   belongs to the installed pi².
package struct DataFolder: Sendable, Equatable {
	package let url: URL

	package static func usual() throws -> URL {
		guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { throw Refusal("this user has no home folder") }
		return URL(fileURLWithPath: String(cString: home), isDirectory: true).appendingPathComponent("Library/Application Support/pi2", isDirectory: true)
	}

	package static func resolve(kind: BuildKind, parent: pid_t, bundle: AppBundle?) throws -> DataFolder {
		// Only a development build reads anything of the engine's environment.
		let named = kind == .development ? ParentProcess.environment(of: parent)?["PI2_HOME"] : nil
		let folder = try choose(kind: kind, named: named, bundle: bundle, usual: usual())
		try checkOwned(folder)
		return DataFolder(url: folder.standardizedFileURL)
	}

	/// Which folder, before it is looked at: `named` is the engine's `PI2_HOME`, which only a development build reads.
	package static func choose(kind: BuildKind, named: String?, bundle: AppBundle?, usual: URL) throws -> URL {
		let folder: URL
		switch kind {
		case .release:
			folder = usual
		case .development:
			if let named, !named.isEmpty, named.hasPrefix("/") {
				folder = URL(fileURLWithPath: named, isDirectory: true)
			} else if let suffix = bundle.map({ developmentSuffix(bundleID: $0.bundleID) }) {
				folder = usual.deletingLastPathComponent().appendingPathComponent("pi2-\(suffix)", isDirectory: true)
			} else {
				throw Refusal("the engine names no data folder (PI2_HOME), and pi² Remote is in no app's bundle to name one")
			}
			if sameFolder(folder, usual) { throw Refusal("a development build of pi² Remote never uses the usual data folder, which is the installed pi²'s") }
		}
		return folder
	}

	/// The part of a development build's bundle id after `dev.pi2.app.`, as `DevelopmentBuild.suffix` takes it.
	package static func developmentSuffix(bundleID: String?) -> String {
		let prefix = "dev.pi2.app."
		guard let id = bundleID?.lowercased(), id.hasPrefix(prefix) else { return "dev" }
		let rest = String(id.dropFirst(prefix.count))
		let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-."))
		guard !rest.isEmpty, rest.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }), !rest.hasPrefix("."), !rest.contains("..") else { return "dev" }
		return rest
	}

	/// Whether two folders are one, however written: a trailing slash, a link, another case.
	package static func sameFolder(_ a: URL, _ b: URL) -> Bool {
		func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
		return canonical(a) == canonical(b)
	}

	/// The folder is a real folder (not a link), this user's, and writable by nobody else.
	package static func checkOwned(_ folder: URL) throws {
		var info = stat()
		guard lstat(folder.path, &info) == 0 else { throw Refusal("the data folder does not exist") }
		guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Refusal("the data folder is not a folder (a link is not taken)") }
		guard info.st_uid == getuid() else { throw Refusal("the data folder is not this user's") }
		guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw Refusal("the data folder can be written by other users") }
	}
}

/// What can be read of the engine's process from outside it.
package enum ParentProcess {
	/// The environment `pid` was started with (KERN_PROCARGS2), or nil if it cannot be read. Only a development build
	/// reads it: there it is how the engine's data folder is known, since the engine starts pi² Remote with an empty
	/// environment of its own.
	package static func environment(of pid: pid_t) -> [String: String]? {
		var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
		var argmax: Int32 = 0
		var size = MemoryLayout<Int32>.size
		guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
		var buffer = [UInt8](repeating: 0, count: Int(argmax))
		mib = [CTL_KERN, KERN_PROCARGS2, pid]
		size = buffer.count
		guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
		let bytes = buffer[0 ..< size]
		let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
		var index = MemoryLayout<Int32>.size
		// The executable's path, then the zeros that pad it.
		while index < size, bytes[index] != 0 { index += 1 }
		while index < size, bytes[index] == 0 { index += 1 }
		// The arguments, then the environment, each ending in a zero.
		var strings: [String] = []
		var start = index
		while index < size {
			if bytes[index] == 0 {
				if index == start { break }
				strings.append(String(decoding: bytes[start ..< index], as: UTF8.self))
				start = index + 1
			}
			index += 1
		}
		guard strings.count >= Int(argc) else { return nil }
		var environment: [String: String] = [:]
		for entry in strings.dropFirst(Int(argc)) {
			guard let equals = entry.firstIndex(of: "=") else { continue }
			let name = String(entry[..<equals])
			if environment[name] == nil { environment[name] = String(entry[entry.index(after: equals)...]) }
		}
		return environment
	}
}
