
import Foundation

/// One file of a presented page's copy (docs/design/presenting.md, "A page an agent wrote is untrusted"): its path in
/// the copy, normalised (`index.html`, `css/site.css`), its size in bytes and its type. A page is drawn from these files
/// alone: any other path is a 404.
public struct PresentedFile: Sendable, Hashable {
    public let path: String
    public let size: Int
    public let mimeType: String

    public init(path: String, size: Int, mimeType: String) {
        self.path = path
        self.size = size
        self.mimeType = mimeType
    }
}

/// A presented page: the manifest of its copy, and the HTML file in it that is loaded first.
public struct PresentedPage: Sendable {
    public let entry: String
    public let files: [PresentedFile]

    public init(entry: String, files: [PresentedFile]) {
        self.entry = entry
        self.files = files
    }
}

/// Where a page's files come from: in the app, the engine's `presented.file` for a copy it made; in pi2-presented-check,
/// a folder. Asked only for a file of the manifest, by its entry. What it answers is served only if it is exactly as
/// long as the manifest says.
public protocol PresentedFiles: Sendable {
    func bytes(of file: PresentedFile) async throws -> Data
}

/// What drawing a page offscreen found, for the agent's answer (`present.drawn` in the design).
public struct PresentedPageFindings: Sendable {
    /// Whether the page loaded at all; `reason` says why not.
    public var ok = false
    public var reason: String?
    /// From asking for the page to WebKit's saying it had loaded.
    public var loadMs = 0
    /// Nothing but its background was drawn, and its body has no text.
    public var blank = false
    /// The page's own size as laid out, in points: taller than the view when it scrolls.
    public var width = 0
    public var height = 0
    /// Its console's lines and its script errors, at most 50 of 500 characters.
    public var console: [String] = []
    /// Addresses it tried to reach and was refused, the network being off: at most 20.
    public var blocked: [String] = []
    /// Of those, the ones the app saw refused itself; the rest are the page's own report, which it can make up.
    public var blockedSeen: [String] = []
    /// Paths it asked for that are not in the copy: at most 20.
    public var notFound: [String] = []
    /// What it asked of the person and was answered without anything shown: an alert, a window, a file, a camera.
    public var answered: [String] = []
    /// The view as drawn, a PNG.
    public var snapshot: Data?

    public init() {}

    static let consoleLines = 50
    static let lineLength = 500
    static let addresses = 20
}

/// The rules a presented page is drawn under, shared by the live view and the offscreen one, on the Mac and the phone.
public enum PresentedPagePolicy {
    /// The scheme a page is loaded from: `pi2-presented://<origin>/<path>`.
    public static let scheme = "pi2-presented"

    /// The longest path the scheme handler looks up, in bytes as asked for; anything longer is a 404 at once.
    static let longestPath = 1024

    /// What every response of the scheme handler carries. Scripts and styles of the copy run, inline ones too (a mockup
    /// is often one file); nothing is fetched but from the scheme itself; no form goes anywhere; no `<base>` moves its
    /// addresses. The content rule list holds the same for every load, and for what this cannot name.
    public static let contentSecurityPolicy =
        "default-src pi2-presented: data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src pi2-presented:; form-action 'none'; base-uri 'none'"

    /// Whether "Allow network for this page" exists at all: the one switch for all of it (#946). False, and no view is
    /// made with the network whatever it is asked (`PresentedPageView.makeLive`), the window shows "Network off" with no
    /// way to change it, and the engine's record of the person's choice is not read.
    public static let networkCanBeAllowed = true

    /// The same with the person's "Allow network for this page" (a live view made with `network: true`): the page may also
    /// load and connect over https and secure WebSockets, and nothing else: no plain http or ws, so that a service on this
    /// Mac or the local network reached through a public name that points at it must also pass a certificate check for
    /// that name. Forms still go nowhere and `<base>` still moves nothing, and the network rule list below still refuses
    /// this Mac and the local network as written.
    public static let contentSecurityPolicyWithNetwork =
        "default-src pi2-presented: data: blob: https: 'unsafe-inline' 'unsafe-eval'; connect-src pi2-presented: https: wss:; form-action 'none'; base-uri 'none'"

    /// The content rule list: every load is blocked but those of the scheme itself and of what is in the page already
    /// (`data:`, `blob:`, an empty frame's `about:`). A load of another presentation's origin goes to this view's own
    /// scheme handler, which serves its own origin alone. WebKit asks this list too before it looks up a name for
    /// `<link rel="dns-prefetch">` or opens a connection for `<link rel="preconnect">`.
    static let contentRules = """
        [
          {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^pi2-presented:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}}
        ]
        """

    /// The hosts that are this Mac or the local network as an address is written, as pi²'s browser blocks them
    /// (BrowserKit's `BrowserPolicy.contentRules`, which TranscriptKit, shared with the phone, does not depend on):
    /// loopback, the private, shared and link-local ranges, and names only a local network answers.
    static let privateHosts = [
        "localhost", "[^/:]*\\.localhost", "[^/:]*\\.local", "[^/:]*\\.internal", "[^/:]*\\.lan", "[^/:]*\\.home\\.arpa", "[^/:]*\\.localdomain", "[^/:.]+",
        "0\\.[0-9.]+", "10\\.[0-9.]+", "127\\.[0-9.]+", "169\\.254\\.[0-9.]+", "192\\.168\\.[0-9.]+",
        "172\\.1[6-9]\\.[0-9.]+", "172\\.2[0-9]\\.[0-9.]+", "172\\.3[01]\\.[0-9.]+",
        "100\\.6[4-9]\\.[0-9.]+", "100\\.[7-9][0-9]\\.[0-9.]+", "100\\.1[01][0-9]\\.[0-9.]+", "100\\.12[0-7]\\.[0-9.]+",
        "22[4-9]\\.[0-9.]+", "2[3-5][0-9]\\.[0-9.]+",
        // IPv6: anything that begins with `::` (unspecified, loopback, an IPv4 address carried inside), unique local,
        // link-local, multicast, and the IPv4 translation prefix.
        "\\[::[0-9a-f:.]*\\]", "\\[f[cd][0-9a-f]*:[0-9a-f:.]*\\]", "\\[fe[89ab][0-9a-f]*:[0-9a-f:.]*\\]", "\\[ff[0-9a-f]*:[0-9a-f:.]*\\]",
        "\\[64:ff9b::[0-9a-f:.]*\\]", "\\[64:ff9b:1:[0-9a-f:.]*\\]", "\\[fe[c-f][0-9a-f]*:[0-9a-f:.]*\\]",
        // A user or password before the host hides the host from the patterns above: refused whatever it is.
        "[^/?#]*@[^/]*",
    ]

    /// The rule list of a live view whose page the person allowed the network: every load is still blocked but those of
    /// the scheme itself, what is in the page already, and https and secure WebSockets (never plain http or ws); and of
    /// those, every one to this Mac or the local network as written is blocked again. A public name that resolves to
    /// such an address is not seen here: https's certificate check for that name is what stands in its way. What the page could not do before (a `file:` address, another scheme, an
    /// app's own scheme) it still cannot.
    static let contentRulesWithNetwork: String = {
        var rules: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        for allowed in ["^pi2-presented:", "^data:", "^blob:", "^about:", "^https://", "^wss://"] {
            rules.append(["trigger": ["url-filter": allowed], "action": ["type": "ignore-previous-rules"]])
        }
        // The pattern language has no "or", so each range and scheme is its own rule; after the ones above, so that they
        // block again. An http address as WebKit gives it always has a port's colon or a slash after its host, and a name
        // may end in a dot (`localhost.` is localhost).
        for scheme in ["https", "wss"] {
            for host in privateHosts {
                rules.append(["trigger": ["url-filter": "^\(scheme)://\(host)\\.?[:/]"], "action": ["type": "block"]])
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[{\"trigger\": {\"url-filter\": \".*\"}, \"action\": {\"type\": \"block\"}}]".utf8)
        return String(decoding: data, as: UTF8.self)
    }()

    /// A new origin for one page as it is loaded: a name of letters and digits that nothing else has, so that two
    /// presentations, or two versions of one, never share an origin or what it stores.
    public static func newOrigin() -> String {
        "p" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The manifest path an address asks for, if it is one the scheme handler may look up: this view's own scheme and
    /// origin, no user, password or port, a path no longer than `longestPath`, each of its parts decoded on its own and
    /// none of them empty, `.`, `..`, or holding a slash, a backslash or a NUL once decoded. The query and fragment are
    /// ignored. Nil for anything else, which is a 404; a path that passes is still served only if the manifest has it.
    public static func manifestPath(of url: URL, origin: String) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host(percentEncoded: true)?.lowercased() == origin,
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let raw = url.path(percentEncoded: true)
        guard raw.utf8.count <= longestPath, raw.hasPrefix("/") else { return nil }
        var parts: [String] = []
        for encoded in raw.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard let part = String(encoded).removingPercentEncoding, !part.isEmpty, part != ".", part != "..",
                  !part.contains("/"), !part.contains("\\"), !part.contains("\0") else { return nil }
            parts.append(part)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// The address of a path of the copy at an origin, each part encoded.
    public static func address(of path: String, origin: String) -> URL? {
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;?#"))) ?? "" }
        return URL(string: "\(scheme)://\(origin)/" + encoded.joined(separator: "/"))
    }

    /// Taken away in every frame, before the page's own scripts: what the content rule list and the policy cannot stop
    /// (WebRTC reaches the network by itself), and what would put up something of the system's or ask for a permission
    /// (macOS asks for the camera or the microphone before the web view's delegate is asked, so a denial there comes too
    /// late). A frame the page makes empty (`about:blank`) gets this too, as WebKit injects it there.
    static let takenAway = """
        (() => {
          const gone = ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "RTCSessionDescription",
            "RTCIceCandidate", "RTCRtpSender", "RTCRtpReceiver", "RTCRtpTransceiver", "RTCDtlsTransport", "RTCIceTransport",
            "RTCSctpTransport", "RTCCertificate", "RTCDTMFSender", "RTCRtpScriptTransform", "MediaStreamTrackProcessor",
            "SpeechRecognition", "webkitSpeechRecognition", "Notification", "PaymentRequest", "ApplePaySession",
            "PublicKeyCredential", "IdentityCredential", "DigitalCredential", "showOpenFilePicker", "showSaveFilePicker",
            "showDirectoryPicker", "EyeDropper"];
          for (const name of gone) { try { delete globalThis[name]; } catch {} }
          for (const name of ["mediaDevices", "geolocation", "clipboard", "credentials", "share", "canShare", "getUserMedia",
            "webkitGetUserMedia", "requestMIDIAccess", "requestMediaKeySystemAccess", "serviceWorker"]) {
            try { delete Navigator.prototype[name]; } catch {}
          }
          try { Object.defineProperty(window, "print", { value: () => {}, configurable: false, writable: false }); } catch {}

          // A link to http or https that is followed connects to its server ahead (WebKit's preconnect on a click), before
          // the navigation delegate is asked and without the rule list: the data store's proxy takes that for any host but
          // this Mac's own addresses, which no proxy is used for. So such a link is followed by a script's navigation
          // instead, which connects to nothing ahead, and which the navigation delegate refuses and says.
          const outbound = (node) => {
            // Up through shadow roots too: a click inside one still follows the link around it.
            for (let at = node; at; at = at.parentNode ?? at.host) {
              if ((at.localName === "a" || at.localName === "area") && at.hasAttribute?.("href")) {
                return /^https?:$/i.test(at.protocol ?? "") ? at : null;
              }
            }
            return null;
          };
          const follow = (link) => {
            const target = (link.target || link.ownerDocument?.querySelector("base[target]")?.target || "_self").toLowerCase();
            const from = link.ownerDocument?.defaultView ?? window;
            if (target === "_self") from.location.href = link.href;
            else if (target === "_parent") from.parent.location.href = link.href;
            else if (target === "_top") from.top.location.href = link.href;
            else from.open(link.href, target);
          };
          const intercept = (event) => {
            const link = outbound(event.composedPath?.()[0] ?? event.target);
            if (!link) return;
            event.preventDefault();
            if (event.type === "click") follow(link);
          };
          addEventListener("click", intercept, true);
          addEventListener("auxclick", intercept, true);
          // A link not in the document is clicked with no window to hear it.
          const click = HTMLElement.prototype.click;
          HTMLElement.prototype.click = function () {
            const link = this.isConnected ? null : outbound(this);
            return link ? follow(link) : click.call(this);
          };
          // A click a script sends may not be cancelable, and a link not in the document has no window to hear it.
          const dispatch = EventTarget.prototype.dispatchEvent;
          EventTarget.prototype.dispatchEvent = function (event) {
            const link = event?.type === "click" || event?.type === "auxclick" ? outbound(this) : null;
            if (!link) return dispatch.call(this, event);
            if (event.type === "click") follow(link);
            return false;
          };
        })();
        """

    /// For drawing offscreen alone, in the page's main frame: its console's lines, its script errors and what the policy
    /// refused, posted as strings to `pi2log`. The page could post anything there too: it only ever adds to the agent's
    /// answer, which is the page's own untrusted text already.
    static let consoleScript = """
        (() => {
          const log = window.webkit?.messageHandlers?.pi2log;
          if (!log) return;
          const post = (line) => { try { log.postMessage(String(line).slice(0, 500)); } catch {} };
          const text = (value) => {
            if (typeof value === "string") return value;
            if (value instanceof Error) return `${value.name}: ${value.message}`;
            try { return JSON.stringify(value) ?? String(value); } catch { return String(value); }
          };
          for (const level of ["log", "info", "warn", "error", "debug"]) {
            const original = console[level];
            console[level] = function (...values) {
              post(`console ${level}: ${values.map(text).join(" ")}`);
              return original.apply(this, values);
            };
          }
          addEventListener("error", (event) => {
            if (!(event instanceof ErrorEvent)) return;
            const where = event.filename ? ` at ${event.filename.replace(/^pi2-presented:\\/\\/[^/]*\\//, "")}:${event.lineno}` : "";
            post(`console error: ${event.message}${where}`);
          });
          addEventListener("unhandledrejection", (event) => post(`console error: unhandled rejection: ${text(event.reason)}`));
          addEventListener("securitypolicyviolation", (event) => post(`blocked ${event.blockedURI}`), true);
        })();
        """

    /// In a world of the app's own, which the page cannot reach: when the page's document last changed, for waiting
    /// until it has been quiet before it is pictured.
    static let quietScript = """
        (() => {
          globalThis.lastChange = performance.now();
          new MutationObserver(() => { globalThis.lastChange = performance.now(); })
            .observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
        })();
        """
}
