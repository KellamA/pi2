
#if os(macOS)
import AppKit
import WebKit

/// Draws a presented page offscreen, for its snapshot and what the agent is told of it (docs/design/presenting.md,
/// "Its answer" and "Drawing a page: the engine asks the app"): in a `PresentedPageView` of its own, in a window that is
/// never shown, at the size asked for. The page is pictured once it has loaded and its document has been quiet for half a
/// second, or after ten seconds of changing, so that a script that draws the page is in the picture.
@MainActor
public enum PresentedPageDrawing {
    /// The longest a page may take to load before it is pictured as it is.
    static let longestLoad: Duration = .seconds(15)
    /// How long the document must not change before it is pictured, and the longest wait for that.
    static let quiet: Double = 500
    static let longestQuiet: Duration = .seconds(10)

    /// Draws `page` and says what it found. `kept`, if given, is handed the view while it is still in its window, after
    /// the findings are made and before it is closed: pi2-presented-check asks the page what it could and could not do.
    public static func draw(
        page: PresentedPage, source: any PresentedFiles, width: Int = 1280, height: Int = 800,
        processes: PresentedProcesses = .shared, kept: ((PresentedPageView) async -> Void)? = nil
    ) async -> PresentedPageFindings {
        var findings = PresentedPageFindings()
        // A place for the page's process first: without one, nothing is drawn.
        guard let place = processes.take() else {
            findings.reason = processes.refusal
            return findings
        }
        let ended = LoadEnd()
        let start = ContinuousClock.now
        let view: PresentedPageView
        do {
            view = try await PresentedPageView.make(page: page, source: source, mode: .drawing) { reason in ended.end(reason) }
        } catch {
            place.release()
            findings.reason = "the network's rules could not be made: \(error.localizedDescription)"
            return findings
        }
        let size = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: size.offsetBy(dx: -20000, dy: -20000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = size
        window.contentView = view
        findings = await drawn(view, findings: findings, size: size, ended: ended, start: start, kept: kept)
        // The page's process is ended before this returns, whatever its scripts do, and its place given back once it
        // has gone: a drawing that has returned has left no process behind.
        await place.end(view)
        window.contentView = nil
        window.close()
        return findings
    }

    /// What drawing the page in `view`, in its window, finds.
    private static func drawn(
        _ view: PresentedPageView, findings: PresentedPageFindings, size: NSRect, ended: LoadEnd, start: ContinuousClock.Instant,
        kept: ((PresentedPageView) async -> Void)?
    ) async -> PresentedPageFindings {
        var findings = findings

        let outcome = await ended.wait(longest: longestLoad)
        findings.loadMs = Int((ContinuousClock.now - start) / .milliseconds(1))
        switch outcome {
        case .loaded: findings.ok = true
        case .failed(let reason): findings.reason = reason
        case .timedOut: findings.reason = "it did not finish loading in \(longestLoad.components.seconds) seconds"
        }
        if findings.ok { await waitUntilQuiet(view) }

        let laidOut = await ask(view, """
            const root = document.documentElement;
            return { width: root?.scrollWidth ?? 0, height: root?.scrollHeight ?? 0, text: (document.body?.innerText ?? "").trim().length };
            """) as? [String: Any]
        findings.width = (laidOut?["width"] as? NSNumber)?.intValue ?? 0
        findings.height = (laidOut?["height"] as? NSNumber)?.intValue ?? 0
        let hasText = ((laidOut?["text"] as? NSNumber)?.intValue ?? 0) > 0

        let configuration = WKSnapshotConfiguration()
        configuration.rect = size
        if let image = await limited(seconds: 10, { try? await view.takeSnapshot(configuration: configuration) }),
           let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            findings.snapshot = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:])
            findings.blank = findings.ok && !hasText && isOneColour(picture)
        } else if findings.ok {
            findings.reason = "it loaded, but could not be pictured"
        }

        let record = view.record
        findings.console = record.consoleLines
        findings.blocked = record.blockedAddresses
        findings.blockedSeen = record.blockedSeen
        findings.notFound = record.notFoundPaths
        findings.answered = record.answeredRequests
        if let kept { await kept(view) }
        return findings
    }

    /// Until the document has not changed for `quiet` milliseconds, at most `longestQuiet`.
    private static func waitUntilQuiet(_ view: PresentedPageView) async {
        let until = ContinuousClock.now + longestQuiet
        _ = await ask(view, "await document.fonts?.ready; return 0;")
        while ContinuousClock.now < until {
            let since = await ask(view, "return performance.now() - (globalThis.lastChange ?? 0);") as? NSNumber
            if let since, since.doubleValue >= quiet { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Runs a script in the app's own world, which the page cannot reach. Nil if it fails or has not answered in five
    /// seconds: a page in the middle of being stopped may never answer, and drawing must end.
    private static func ask(_ view: PresentedPageView, _ body: String) async -> Any? {
        await limited(seconds: 5) { try? await view.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: PresentedPageView.world) }
    }

    /// What `work` gives, or nil if it has not given it in `seconds`.
    static func limited<T>(seconds: Double, _ work: @escaping @MainActor () async -> T?) async -> T? {
        let first = First<T>()
        return await withCheckedContinuation { continuation in
            first.continuation = continuation
            Task { @MainActor in first.give(await work()) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                first.give(nil)
            }
        }
    }

    /// Whether every pixel is the colour of the first, near enough: nothing but a background.
    static func isOneColour(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = context.data else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let first = (pixels[0], pixels[1], pixels[2], pixels[3])
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            if abs(Int(pixels[index]) - Int(first.0)) > 2 || abs(Int(pixels[index + 1]) - Int(first.1)) > 2
                || abs(Int(pixels[index + 2]) - Int(first.2)) > 2 || abs(Int(pixels[index + 3]) - Int(first.3)) > 2 {
                return false
            }
        }
        return true
    }
}

/// The first of an answer and its time running out.
@MainActor
private final class First<T> {
    var continuation: CheckedContinuation<T?, Never>?

    func give(_ value: sending T?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// The end of a page's first load, told once, waited for with a limit.
@MainActor
private final class LoadEnd {
    enum Outcome { case loaded, failed(String), timedOut }

    private var outcome: Outcome?
    private var waiting: CheckedContinuation<Void, Never>?

    func end(_ reason: String?) {
        guard outcome == nil else { return }
        outcome = reason.map { .failed($0) } ?? .loaded
        waiting?.resume()
        waiting = nil
    }

    func wait(longest: Duration) async -> Outcome {
        if outcome == nil {
            let limit = Task { @MainActor [weak self] in
                try? await Task.sleep(for: longest)
                self?.waiting?.resume()
                self?.waiting = nil
            }
            await withCheckedContinuation { waiting = $0 }
            limit.cancel()
        }
        return outcome ?? .timedOut
    }
}
#endif
