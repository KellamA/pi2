
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
