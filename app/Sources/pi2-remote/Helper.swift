import Darwin
import Dispatch
import Foundation
import RemoteKit

/// pi² Remote, from its start (docs/iphone.md 5.5, decision 24; docs/pi2-remote.md).
///
/// In this order, so that a copy the engine did not start, and send `start`, exits before it reads any key:
///
/// 1. which kind of build it is (`BuildKind`);
/// 2. the start-up checks (`Startup`): descriptor 3 is a socket to its parent, the parent is the process `engine.pid`
///    names, and in a release build the Node of the app's bundle;
/// 3. the first line on descriptor 3 is the engine's `start`, within ten seconds (`Startup.firstLine`): every command
///    an agent runs is the engine's child too, so the checks of step 2 alone do not prove the engine, and nothing is
///    read or written before this;
/// 4. only then its log, the keys and pi² Remote's own list of devices (`KeyVaults`), and it does only what the
///    engine's events say.
///
/// It reads no argument and none of its own environment variables, in any build: the engine starts it with none, and
/// what it needs comes over the control connection. A development build reads one thing from outside it, the engine's
/// own data folder (`PI2_HOME` in the engine's environment), and is otherwise the same.
public enum RemoteHelper {
	/// The exit code of a refusal at start: the engine logs it as pi² Remote stopping by itself.
	public static let refusedAtStart: Int32 = 78

	public static func main() -> Never {
		signal(SIGPIPE, SIG_IGN)
		let kind: BuildKind
		switch BuildKind.current() {
		case let .success(found): kind = found
		case let .failure(refusal): refuse(refusal)
		}
		let verified: Startup.Verified
		switch Startup.verify(kind: kind) {
		case let .success(found): verified = found
		case let .failure(refusal): refuse(refusal)
		}
		let start: JSONValue
		switch Startup.firstLine() {
		case let .success(found): start = found
		case let .failure(refusal): refuse(refusal)
		}
		Log.shared.open(folder: verified.folder.url)
		log("pi² Remote started: a \(kind) build, process \(getpid()), the engine's \(verified.engine)")

		let queue = DispatchQueue(label: "pi2-remote")
		let engine = EngineLink(io: SocketIO(descriptor: Startup.controlDescriptor, queue: queue))
		engine.onClose = { why in
			log("\(why); stopping")
			exit(0)
		}
		let remote: Remote
		do {
			let vault = try KeyVaults.forBuild(kind, folder: verified.folder.url)
			let keys = try vault.macKeys()
			remote = try Remote(kind: kind, keys: keys, vault: vault, engine: engine, queue: queue)
		} catch {
			log("the Mac's keys or pi² Remote's list of devices could not be read: \(error); stopping")
			exit(1)
		}
		queue.async {
			remote.begin(start)
			engine.start()
		}
		withExtendedLifetime(remote) { dispatchMain() }
	}

	private static func refuse(_ refusal: Refused) -> Never {
		log("not started: \(refusal)")
		exit(refusedAtStart)
	}
}
