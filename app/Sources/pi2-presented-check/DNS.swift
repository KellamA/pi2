// Whether `<link rel="dns-prefetch">`, `<link rel="preconnect">` or a clicked link makes WebKit look a name up, measured
// from the log of this program's own WebKit networking process (`log show`, after the pages were drawn): each name it looks up starts a resolver
// there (`nw_resolver`, or a connection's `resolver:start`), logged under the pid of the app it works for. The names are
// private in the log, so the check counts lookups by that process while the page is drawn, and the same while a plain
// web view draws the same kind of page, which shows that lookups are seen when nothing stops them. The names are under
// `.localhost`, which this Mac answers itself: nothing is asked of a DNS server, even by the plain view.

import AppKit
import Foundation
import TranscriptKit
import WebKit

/// The log of WebKit's networking processes, read once the pages were drawn.
struct ResolverLog {
    let lines: [Substring]

    /// A moment as the log writes it, which sorts as text.
    static func stamp(_ date: Date = Date()) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return format.string(from: date)
    }

    /// What the networking processes logged from `start` on; nil if `log show` could not be read.
    static func read(since start: Date) -> ResolverLog? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--start", String(stamp(start.addingTimeInterval(-1)).prefix(19)), "--predicate", "process == \"com.apple.WebKit.Networking\"", "--style", "compact"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return ResolverLog(lines: String(decoding: data, as: UTF8.self).split(separator: "\n"))
    }

    /// The networking processes working for this program: those that name its pid.
    var ours: Set<Substring> {
        let pid = getpid()
        var found: Set<Substring> = []
        for line in lines where line.contains("pid: \(pid),") || line.contains("parentPID=\(pid),") {
            if let process = Self.process(of: line) { found.insert(process) }
        }
        return found
    }

    /// Lookups of a name by this program's networking process between two moments.
    func lookups(from start: String, to end: String) -> [Substring] {
        let processes = ours
        return lines.filter { line in
            let when = line.prefix(23)
            return when >= start && when < end && (line.contains("nw_resolver initWithEndpoint") || line.contains("resolver:start"))
                && Self.process(of: line).map(processes.contains) == true
        }
    }

    private static func process(of line: Substring) -> Substring? {
        guard let start = line.range(of: "com.apple.WebKit.Networking[") else { return nil }
        return line[start.upperBound...].prefix { $0.isNumber }
    }
}

func prefetchPage(_ prefetched: String, _ preconnected: String, _ clicked: String) -> String {
    """
    <!doctype html><html><head><meta http-equiv="x-dns-prefetch-control" content="on">
    <link rel="dns-prefetch" href="//\(prefetched)/"><link rel="dns-prefetch" href="http://\(prefetched)/">
    <link rel="preconnect" href="http://\(preconnected)/">
    </head><body><a href="http://\(prefetched)/a">a link</a><a id="clicked" href="http://\(clicked)/">clicked</a>
    <script>window.results = {}; window.done = true; document.getElementById("clicked").click();</script></body></html>
    """
}

@MainActor
func dnsPrefetch() async {
    await group("DNS prefetching, preconnecting and a clicked link look no name up, measured from WebKit's own log") {
        let began = Date()
        let tag = UUID().uuidString.prefix(8).lowercased()
        let name = { (what: String) in "pi2-check-\(tag)-\(what).localhost" }

        let files = folder("dns", ["index.html": html(prefetchPage(name("page"), name("page-preconnect"), name("page-click")))])
        let pageStart = ResolverLog.stamp()
        let found = await PresentedPageDrawing.draw(page: files.manifest(), source: files) { view in
            _ = await results(view)
            try? await Task.sleep(for: .seconds(2))
        }
        check("it loaded", found.ok, found.reason ?? "")
        let pageEnd = ResolverLog.stamp()
        await control(prefetchPage(name("control"), name("control-preconnect"), name("control-click")), base: URL(string: "http://127.0.0.1:9/")!) { view in
            _ = await results(view)
            try? await Task.sleep(for: .seconds(2))
        }
        let controlEnd = ResolverLog.stamp()
        // What the log has not yet written down.
        try? await Task.sleep(for: .seconds(3))
        guard let log = ResolverLog.read(since: began) else {
            info("DNS prefetching could not be measured: /usr/bin/log show could not be read")
            return
        }
        let controlLookups = log.lookups(from: pageEnd, to: controlEnd)
        let pageLookups = log.lookups(from: pageStart, to: pageEnd)
        guard !log.ours.isEmpty, !controlLookups.isEmpty else {
            info("DNS prefetching could not be measured: WebKit's log showed no lookup, even for the plain web view (\(log.lines.count) lines)")
            return
        }
        info("the plain web view's page made \(controlLookups.count) lookups for the same kind of page")
        check("the page made none", pageLookups.isEmpty, pageLookups.prefix(3).map { String($0.prefix(240)) }.joined(separator: "\n      "))
    }
}
