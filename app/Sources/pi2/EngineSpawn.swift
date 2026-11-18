import Darwin
import Foundation

/// Starts the engine as its own responsible process, so that macOS does not judge it and the commands its agents run
/// by the app's privacy permissions (#263).
///
/// macOS checks a permission such as Accessibility against a process's *responsible* process. A process the app starts
/// in the usual way has the app as its responsible process, and so does everything it starts in turn: an agent's shell
/// command would have all of the app's permissions, and with Accessibility it could drive any app, around computer
/// use's list of apps and its approvals. Started this way, the engine is responsible for itself, as it is when launchd
/// starts it for the login item: the Node inside a release build is traced back to pi² for Screen Recording, and has no
/// Accessibility of its own. See "Whose macOS permissions commands have" in docs/architecture.md.
///
/// Otherwise the process is started as Foundation's `Process` starts one: in a process group of its own, with every
/// signal at its default and none blocked, and with none of the app's file descriptors but the three it is given. It
/// is still the app's child, so nothing that finds or stops the engine changes.
enum EngineSpawn {
    enum Ending: Sendable {
        case exited(Int32)
        case signal(Int32)
    }

    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// libSystem's `responsibility_spawnattrs_setdisclaim`, which Terminal and other apps that start programs for
    /// someone else use. It is not in the public headers, so it is looked up: nil if this macOS does not have it.
    private static var disclaim: Disclaim? {
        // RTLD_DEFAULT, which Swift does not import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(symbol, to: Disclaim.self)
    }

    /// Whether processes started here can be made responsible for themselves. If not, they are started anyway.
    static var canDisclaim: Bool { disclaim != nil }

    /// Starts `executable` with `arguments` and `environment`, its input from /dev/null and its output and errors to
    /// `output` (or /dev/null), and returns its process id. `ended` is called, on a thread of its own, once it ends.
    /// Throws a POSIX error if it could not be started.
    @discardableResult
    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        output: FileHandle? = nil,
        ended: (@Sendable (Ending) -> Void)? = nil
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setpgroup(&attributes, 0)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        if let disclaim { _ = disclaim(&attributes, 1) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        for target in [STDOUT_FILENO, STDERR_FILENO] {
            if let output {
                let descriptor = output.fileDescriptor
                // dup2 onto itself would leave the descriptor marked close-on-exec, which CLOEXEC_DEFAULT then closes.
                if descriptor == target {
                    posix_spawn_file_actions_addinherit_np(&actions, target)
                } else {
                    posix_spawn_file_actions_adddup2(&actions, descriptor, target)
                }
            } else {
                posix_spawn_file_actions_addopen(&actions, target, "/dev/null", O_WRONLY, 0)
            }
        }

        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv + [nil], envp + [nil])
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }

        // Wait for it, so it is not left a zombie that still answers `kill(pid, 0)`, which is how the app tells
        // whether the engine is running.
        let started = pid
        Thread {
            var status: Int32 = 0
            while waitpid(started, &status, 0) == -1, errno == EINTR {}
            let signal = status & 0x7f
            ended?(signal == 0 ? .exited((status >> 8) & 0xff) : .signal(signal))
        }.start()
        return started
    }
}
