
import Foundation
import WebKit

/// Serves `pi2-presented://<origin>/<path>` to one view, from the page's manifest alone: a path the manifest has, at
/// this view's origin, is fetched from its `PresentedFiles` and served with the policy; anything else is a 404, and
/// nothing is ever read from a folder by an address. Each view has its own handler, so another presentation's origin is
/// a 404 here too.
@MainActor
final class PresentedSchemeHandler: NSObject, WKURLSchemeHandler {
    let origin: String
    private let files: [String: PresentedFile]
    private let source: any PresentedFiles
    /// Tasks WebKit has stopped: answering one after that raises an exception.
    private var stopped: Set<ObjectIdentifier> = []
    /// A path asked for that was not served, as asked.
    var onNotFound: (String) -> Void = { _ in }
    /// The Content-Security-Policy every response carries: the network-off one unless the view was made with the network.
    let policy: String

    init(page: PresentedPage, source: any PresentedFiles, origin: String, policy: String = PresentedPagePolicy.contentSecurityPolicy) {
        self.origin = origin
        self.policy = policy
        self.files = Dictionary(page.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        self.source = source
    }

    /// Whether the manifest has a path.
    func has(_ path: String) -> Bool { files[path] != nil }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        stopped.remove(id)
        guard let url = task.request.url else { return notFound(task, "(no address)") }
        guard let path = PresentedPagePolicy.manifestPath(of: url, origin: origin), let file = files[path] else {
            return notFound(task, shown(url))
        }
        Task { @MainActor in
            let data = try? await source.bytes(of: file)
            guard !stopped.contains(id) else { return }
            guard let data, data.count == file.size else { return notFound(task, path) }
            respond(task, url: url, status: 200, type: file.mimeType, body: data)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private func notFound(_ task: any WKURLSchemeTask, _ what: String) {
        onNotFound(what)
        let url = task.request.url ?? URL(string: "\(PresentedPagePolicy.scheme)://\(origin)/")!
        respond(task, url: url, status: 404, type: "text/plain", body: Data("Not in the page's files.".utf8))
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, status: Int, type: String, body: Data) {
        var contentType = type
        if type.hasPrefix("text/") || type == "application/javascript" || type == "application/json" || type == "image/svg+xml" {
            contentType += "; charset=utf-8"
        }
        let headers = [
            "Content-Type": contentType,
            "Content-Length": String(body.count),
            "Content-Security-Policy": policy,
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-store",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    /// An address as the findings name it: the path as asked for when it is at this origin, cut short when long.
    private func shown(_ url: URL) -> String {
        let own = url.host(percentEncoded: true)?.lowercased() == origin
        let text = own ? String(url.path(percentEncoded: true).dropFirst()) : url.absoluteString
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }
}
