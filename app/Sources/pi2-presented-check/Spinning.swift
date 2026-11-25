
import AppKit
import TranscriptKit
import WebKit

/// Whether a process is still there.
func alive(_ pid: pid_t) -> Bool { Darwin.kill(pid, 0) == 0 || errno == EPERM }

/// A page whose script never yields, once it has loaded: a draw of it is given up, and its web content process must be
/// gone all the same once the draw has returned, or an agent presenting such pages in a loop adds a process spinning at
/// full speed for each (#1000's security read).
@MainActor
func spinningPage() async {
    let files = folder("spinning", ["index.html": html("<!doctype html><p>Spin</p><script>setTimeout(() => { for (;;) {} }, 300)</script>")])
    await group("a page whose script never stops: its process is gone once its drawing has returned") {
        var pid: pid_t?
        let found = await PresentedPageDrawing.draw(page: files.manifest(), source: files) { view in pid = process(of: view) }
        guard let pid else {
            check("WebKit names the page's process for this check", false, "no _webProcessIdentifier")
            return
        }
        info("the spinning page's draw: \(found.ok ? "ok" : found.reason ?? "not ok")")
        let gone = !alive(pid)
        check("its web content process is gone", gone, "process \(pid) still runs")
        if !gone { Darwin.kill(pid, SIGKILL) }
        check("and its place is given back", PresentedProcesses.shared.taken == 0 && PresentedProcesses.shared.stuck == 0,
              "\(PresentedProcesses.shared.taken) taken, \(PresentedProcesses.shared.stuck) stuck")
    }

    await group("no more pages have a process than there are places: a drawing with none is refused, with why") {
        let files = folder("places", ["index.html": html("<!doctype html><p>A place of its own</p>")])
        let processes = PresentedProcesses(most: 2)
        let first = processes.take(), second = processes.take()
        check("two places are taken", first != nil && second != nil && processes.take() == nil && processes.taken == 2)
        let refused = await PresentedPageDrawing.draw(page: files.manifest(), source: files, processes: processes)
        check("a drawing with no place is not drawn", !refused.ok && refused.snapshot == nil)
        check("and says why", refused.reason == processes.refusal && refused.reason?.contains("2 pages") == true, refused.reason ?? "no reason")
        first?.release()
        let drawn = await PresentedPageDrawing.draw(page: files.manifest(), source: files, processes: processes)
        check("with a place given back, it is drawn", drawn.snapshot != nil, drawn.reason ?? "")
        check("and gives its place back after", processes.taken == 1, "\(processes.taken) taken")
        second?.release()
    }
}

/// Only a number that names one process other than this one is ever signalled: a negative number signals a group of
/// processes, -1 every process of the person's, and this process's own would end pi² (#1000's second read).
@MainActor
func processNumbers() async {
    await group("a process number WebKit gives is signalled only if it names another single process") {
        for (name, number) in [("0", pid_t(0)), ("-1, every process", pid_t(-1)), ("a negative number, a group", pid_t(-4242)),
                               ("1, launchd", pid_t(1)), ("this process's own", getpid()), ("none", nil)] as [(String, pid_t?)] {
            check("refused: \(name)", PresentedPageView.signallable(number) == nil, "taken as \(String(describing: PresentedPageView.signallable(number)))")
        }
        check("another process's number is taken", PresentedPageView.signallable(getppid()) == getppid())
    }
}

/// A place held by a process that did not end is given back once the process has gone, and while it is held the
/// refusal says what helps: quitting pi², not closing a window (#1000's second read).
@MainActor
func stuckPlaces() async {
    await group("a place held by a process that did not end comes back once it has gone, and the refusal says to quit pi²") {
        let processes = PresentedProcesses(most: 2)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        guard (try? child.run()) != nil else {
            check("a process of the check's own starts", false)
            return
        }
        defer { if child.isRunning { child.terminate() } }
        processes.take()?.markStuck(child.processIdentifier)
        processes.take()?.markStuck(nil)
        check("both places are held, as stuck", processes.taken == 2 && processes.stuck == 2 && processes.take() == nil)
        check("the refusal says to quit pi² and open it again", processes.refusal.contains("quit pi² and open it again") && !processes.refusal.contains("close"), processes.refusal)
        child.terminate()
        child.waitUntilExit()
        let place = processes.take()
        check("once the process has gone, its place is given back", place != nil && processes.stuck == 1, "\(processes.taken) taken, \(processes.stuck) stuck")
        check("the one with no number stays held", processes.take() == nil && processes.taken == 2)
        check("with a window's place among them, closing one is said too", processes.refusal.contains("close a presentation's window") && processes.refusal.contains("quit pi²"), processes.refusal)
        place?.release()
    }
}

/// The level of a console line is the page's call, said before what it logged: a log line that begins "error: " is a
/// log line still (the engine counts as errors the lines that begin "error: ").
@MainActor
func consoleLevels() async {
    let files = folder("levels", ["index.html": html("<!doctype html><p>Levels</p><script>console.log('error: x'); console.error('really')</script>")])
    await group("a page's console.log(\"error: x\") arrives as log: error: x") {
        let found = await PresentedPageDrawing.draw(page: files.manifest(), source: files)
        check("as a log line", found.console.contains("log: error: x"), "\(found.console)")
        check("and console.error as an error", found.console.contains("error: really"), "\(found.console)")
        let sent = PresentedDrawAnswer.params(found, height: 800)["console"] as? [String] ?? []
        check("and so in what the engine is sent", sent.contains("log: error: x") && sent.contains("error: really"), "\(sent)")
    }
}
