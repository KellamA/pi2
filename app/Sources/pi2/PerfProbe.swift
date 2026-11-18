import Foundation

/// Measures how busy the app's main thread is, for working on its speed under load (#347): what each kind of event
/// from the engine costs to decode and take in, how late the main thread answers, and the steps of opening a
/// conversation and sending a message. Only a development build measures, and only while its data folder holds a
/// file named `perf.on`; it then writes a summary to `perf.log` there every ten seconds. docs/development.md says how
/// to use it with a throwaway copy.
@MainActor
enum PerfProbe {
    private struct Kind {
        var count = 0
        var bytes = 0
        var seconds: Double = 0
        var worst: Double = 0
    }

    /// One conversation being opened: when each step happened, in seconds since it was asked for.
    private struct Opening {
        let started: Double
        var steps: [String] = []
    }

    private static var home: URL?
    private(set) static var active = false
    private static var kinds: [String: Kind] = [:]
    private static var lags: [Double] = []
    private static var awake: Double = 0
    private static var wokeAt: Double?
    private static var windowStart: Double = 0
    private static var openings: [Int: Opening] = [:]
    private static var lines: [String] = []
    /// Requests on their way: the method and when it was sent, by request id.
    private static var asked: [Int: (method: String, at: Double)] = [:]
    /// Requests answered in this window, by method: how many, and their round trips.
    private static var trips: [String: [Double]] = [:]
    private static var observer: CFRunLoopObserver?
    private static var heartbeat: DispatchSourceTimer?

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Called once, with the data folder. Looks for `perf.on` every two seconds, so it can be turned on and off while
    /// the app runs.
    static func start(home: URL) {
        #if PI2_DEVELOPMENT
        self.home = home
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { check() }
        }
        #endif
    }

    private static func check() {
        guard let home else { return }
        let on = FileManager.default.fileExists(atPath: home.appendingPathComponent("perf.on").path)
        if on && !active { begin() }
        if !on && active { end() }
        if active && now() - windowStart >= 10 { flush() }
    }

    private static func begin() {
        active = true
        reset()
        write("perf: measuring (pid \(getpid()))")
        // Time the main thread spends awake, between the run loop waking and going back to sleep.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            MainActor.assumeIsolated {
                if activity == .afterWaiting {
                    wokeAt = now()
                } else if let woke = wokeAt {
                    awake += now() - woke
                    wokeAt = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        // How late the main thread answers: a block is sent to it every 50 ms from another queue.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler {
            let sent = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if active { lags.append(now() - sent) } }
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private static func end() {
        flush()
        write("perf: stopped")
        active = false
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        heartbeat?.cancel()
        heartbeat = nil
    }

    private static func reset() {
        kinds = [:]
        lags = []
        trips = [:]
        awake = 0
        windowStart = now()
    }

    /// One event or reply from the engine: its kind, its size, and the main thread's time decoding and taking it in.
    static func event(_ kind: String, bytes: Int, since start: Double) {
        guard active else { return }
        let took = now() - start
        var entry = kinds[kind] ?? Kind()
        entry.count += 1
        entry.bytes += bytes
        entry.seconds += took
        entry.worst = max(entry.worst, took)
        kinds[kind] = entry
    }

    /// A request sent to the engine.
    static func sent(_ id: Int, _ method: String) {
        guard active else { return }
        asked[id] = (method, now())
    }

    /// The answer to request `id` has been read; returns its method, for counting the reply under it.
    @discardableResult
    static func answered(_ id: Int) -> String? {
        guard active, let request = asked.removeValue(forKey: id) else { return nil }
        trips[request.method, default: []].append(now() - request.at)
        return request.method
    }

    /// A step of opening conversation `id`. "asked" starts it; "drawn" (the page has shown its entries) ends it.
    static func opening(_ id: Int, _ step: String) {
        guard active else { return }
        if step == "asked" {
            // The selection and the page each ask as the conversation comes on screen: the first one starts the clock.
            if let opening = openings[id], now() - opening.started < 5 { return }
            openings[id] = Opening(started: now())
            return
        }
        guard var opening = openings[id] else { return }
        let ms = Int(((now() - opening.started) * 1000).rounded())
        opening.steps.append("\(step) \(ms)ms")
        if step.hasPrefix("drawn") {
            write("open \(id): \(opening.steps.joined(separator: ", "))")
            openings[id] = nil
        } else {
            openings[id] = opening
        }
    }

    /// Something worth a line of its own, such as how long a message took to be accepted.
    static func note(_ text: String) {
        guard active else { return }
        write(text)
    }

    private static func flush() {
        let span = now() - windowStart
        guard span > 0 else { return }
        let sorted = lags.sorted()
        func percentile(_ p: Double) -> Int {
            sorted.isEmpty ? 0 : Int((sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000).rounded())
        }
        let late = sorted.filter { $0 > 0.1 }.count
        var text = String(format: "window %.0fs: main thread awake %.0f%%; answers in p50 %dms p95 %dms max %dms, %d of %d over 100ms\n",
                          span, awake / span * 100, percentile(0.5), percentile(0.95), percentile(1), late, sorted.count)
        let total = kinds.values.reduce(0) { $0 + $1.seconds }
        text += String(format: "  events: %.0fms on the main thread in all (%.0f%%)\n", total * 1000, total / span * 100)
        for (kind, entry) in kinds.sorted(by: { $0.value.seconds > $1.value.seconds }) {
            text += String(format: "  %-14@ %5.1f/s  avg %7d B  avg %6.2fms  worst %6.1fms  total %6.0fms\n",
                           kind as NSString, Double(entry.count) / span, entry.bytes / max(1, entry.count),
                           entry.seconds / Double(entry.count) * 1000, entry.worst * 1000, entry.seconds * 1000)
        }
        for (method, times) in trips.sorted(by: { $0.key < $1.key }) {
            text += String(format: "  request %-24@ %3d  avg %6.0fms  worst %6.0fms\n", method as NSString, times.count,
                           times.reduce(0, +) / Double(times.count) * 1000, (times.max() ?? 0) * 1000)
        }
        write(text.trimmingCharacters(in: .newlines))
        reset()
    }

    private static func write(_ text: String) {
        guard let home else { return }
        let url = home.appendingPathComponent("perf.log")
        let line = "\(Date().formatted(.iso8601)) \(text)\n"
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
        try? handle.close()
    }
}
