import WebKit

/// Sending the page what changed (docs/transcript.md, "Messages between the app and the page").
@MainActor
public enum TranscriptMessages {
    /// Waits for the page's next animation frame, and a turn after it. A window nobody can see has no animation frames,
    /// and the page then draws on a timer of its own, so this does not wait longer than that.
    public static let nextFrame = "await new Promise((done) => { requestAnimationFrame(() => setTimeout(done, 0)); setTimeout(done, 200); });"

    public static func send(_ json: String, to view: WKWebView?, then done: (@MainActor () -> Void)? = nil) {
        // The JSON goes in as an argument and is parsed by the page, so nothing in it is ever run as script.
        guard let done else {
            view?.callAsyncJavaScript("window.pi2.receive(message)", arguments: ["message": json], in: nil, in: .page, completionHandler: nil)
            return
        }
        // The page draws in its next animation frame: wait for that, and a turn after it.
        view?.callAsyncJavaScript("window.pi2.receive(message); " + Self.nextFrame, arguments: ["message": json], in: nil, in: .page) { _ in
            MainActor.assumeIsolated { done() }
        }
    }
}
