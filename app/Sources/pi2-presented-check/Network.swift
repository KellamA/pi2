// "Allow network for this page" (#946, piece 5): a live view made with `network: true`. The default view, made as before,
// must be exactly as closed as it was; a view with the network must still reach nothing on this Mac or the local network,
// and still put up nothing, open nothing, download nothing and leave its origin for nothing. Nothing here reaches beyond
// 127.0.0.1: what the network-on view may reach on the internet is not tried (the window's own check is by hand).

import AppKit
import TranscriptKit
import WebKit

/// The policy the page's own responses carry, read by the page from a response of its own origin.
@MainActor
func servedPolicy(_ view: WKWebView) async -> String {
    await js(view, "const r = await fetch('index.html'); return r.headers.get('content-security-policy') ?? 'none'") as? String ?? "no answer"
}

/// Whether the view's data store sends what WebKit connects to by itself to the dead end: one proxy, on 127.0.0.1.
@MainActor
func hasDeadEnd(_ view: WKWebView) -> Bool {
    view.configuration.websiteDataStore.proxyConfigurations.count == 1
}

@MainActor
func networkSwitch(listener: Listener, net: String) async {
    let port = listener.tcpPort
    let plain = folder("network-default", ["index.html": html("<!doctype html><p>Default</p>")])

    await group("the default view is exactly as closed as before: network off, the same policy, the dead-end proxy") {
        if let (window, view) = await live(plain) {
            check("made with make(.live): no network", !view.network)
            let policy = await servedPolicy(view)
            check("its responses carry the network-off policy, exactly", policy == PresentedPagePolicy.contentSecurityPolicy, policy)
            check("its data store has the dead-end proxy", hasDeadEnd(view))
            close(window, view)
        }
        if let (window, view) = await live(plain, network: false) {
            check("made with makeLive(network: false): no network", !view.network)
            check("the network-off policy", await servedPolicy(view) == PresentedPagePolicy.contentSecurityPolicy)
            check("the dead-end proxy", hasDeadEnd(view))
            close(window, view)
        }
        var drawn: (Bool, String, Bool)?
        _ = await PresentedPageDrawing.draw(page: plain.manifest(), source: plain) { view in
            drawn = (view.network, await servedPolicy(view), hasDeadEnd(view))
        }
        check("an offscreen view has no network, the same policy and the dead end", drawn?.0 == false && drawn?.1 == PresentedPagePolicy.contentSecurityPolicy && drawn?.2 == true, "\(String(describing: drawn))")

        // The live view as the window makes it by default, with every way of loading something.
        let loads = folder("network-default-loads", ["index.html": html(loadsPage(net: net, udp: listener.udpPort))])
        let before = listener.counts
        if let (window, view) = await live(loads, network: false, waits: false) {
            let got = await results(view)
            check("fetch is refused", got["fetch"]?.hasPrefix("refused") == true, got["fetch"] ?? "")
            try? await Task.sleep(for: .seconds(1))
            close(window, view)
        }
        let after = listener.counts
        check("a default live view reaches nothing on 127.0.0.1", after.connections == before.connections && after.datagrams == before.datagrams,
              "paths \(after.paths.dropFirst(before.paths.count))")
    }

    // 127.0.0.1 in each spelling a URL parser takes, the names this Mac answers itself, and a user before the host: over
    // https, which the network lets through, so that only the rule list for this Mac and the local network stands in the
    // way (a TLS attempt to the listener would still be a connection it counts). The second reader's 13 join the 19.
    let hostName = ProcessInfo.processInfo.hostName
    let bareHostName = hostName.hasSuffix(".local") ? String(hostName.dropLast(".local".count)) : hostName
    let written: [(String, String)] = [
        ("127.0.0.1", "127.0.0.1"), ("localhost", "localhost"), ("a name under .localhost", "probe.localhost"), ("decimal", "2130706433"),
        ("short", "127.1"), ("hexadecimal", "0x7f.0.0.1"), ("octal", "0177.0.0.1"), ("IPv4 inside IPv6", "[::ffff:127.0.0.1]"),
        ("a user before it", "user@127.0.0.1"), ("a user and password before localhost", "user:pw@localhost"), ("0.0.0.0", "0.0.0.0"),
        ("a trailing dot", "localhost."), ("upper case", "LOCALHOST"), ("a trailing dot after an address", "127.0.0.1."),
        ("percent-encoded", "%6cocalhost"), ("full-width letters", "\u{FF4C}\u{FF4F}\u{FF43}\u{FF41}\u{FF4C}\u{FF48}\u{FF4F}\u{FF53}\u{FF54}"),
        ("a name under .localhost with a dot", "probe.localhost."), ("IPv4 inside IPv6, written out", "[0:0:0:0:0:ffff:7f00:1]"),
        ("0", "0"), ("[::]", "[::]"), ("one hexadecimal number", "0x7f000001"), ("one octal number", "017700000001"),
        ("zero-padded", "127.000.000.001"), ("percent-encoded dots", "127%2e0%2e0%2e1"), ("ideographic full stops", "127\u{3002}0\u{3002}0\u{3002}1"),
        ("circled digits", "\u{2460}\u{2461}\u{2466}.\u{24EA}.\u{24EA}.\u{2460}"), ("[::ffff:7f00:1]", "[::ffff:7f00:1]"), ("LocalHost.", "LocalHost."),
        ("this Mac's host name", hostName), ("this Mac's host name with a dot", hostName + "."), ("this Mac's name alone", bareHostName),
        ("localhost.localdomain", "localhost.localdomain"),
    ]
    var spellings = written.map { ($0.0, "https://\($0.1):\(port)/\($0.0.filter(\.isLetter).prefix(12))") }
    spellings.append(("plain http", "http://127.0.0.1:\(port)/plain"))
    let probes = spellings.map { "[\(jsString($0.0)), \(jsString($0.1))]" }.joined(separator: ", ")
    let reach = folder("network-on-private", ["index.html": html("""
        <!doctype html><html><body>
        \(spellings.map { "<img src=\"\($0.1)-img.png\">" }.joined())
        <script>
        window.results = {};
        (async () => {
          for (const [name, address] of [\(probes)]) {
            try { const r = await Promise.race([fetch(address, { mode: "no-cors" }), new Promise((ok) => setTimeout(() => ok("no answer"), 3000))]); results[name] = String(r?.type ?? r); }
            catch (e) { results[name] = "refused " + e.name; }
          }
          for (const [name, address] of [["websocket", "wss://127.0.0.1:\(port)/wss"], ["plain websocket", "ws://localhost:\(port)/ws"]]) {
            try { await new Promise((ok, no) => { const w = new WebSocket(address); w.onopen = ok; w.onerror = () => no(new Error("error")); }); results[name] = "open"; }
            catch (e) { results[name] = "refused"; }
          }
          window.done = true;
        })();
        </script></body></html>
        """)])

    await group("with the network allowed, a page still reaches nothing on this Mac over https, however 127.0.0.1 is written") {
        let before = listener.counts
        guard let (window, view) = await live(reach, network: true) else { return }
        check("the view has the network", view.network)
        let policy = await servedPolicy(view)
        check("its responses carry the policy with the network", policy == PresentedPagePolicy.contentSecurityPolicyWithNetwork, policy)
        check("and no dead-end proxy", view.configuration.websiteDataStore.proxyConfigurations.isEmpty)
        let got = await results(view)
        for (name, _) in spellings {
            check("\(name): refused", got[name]?.hasPrefix("refused") == true, got[name] ?? "no answer")
        }
        check("a secure WebSocket to it is refused", got["websocket"] == "refused", got["websocket"] ?? "")
        check("a plain WebSocket is refused", got["plain websocket"] == "refused", got["plain websocket"] ?? "")
        try? await Task.sleep(for: .seconds(1))
        close(window, view)
        let after = listener.counts
        check("no TCP connection reached 127.0.0.1", after.connections == before.connections, "paths \(after.paths.dropFirst(before.paths.count))")
    }

    // Public names that point back at 127.0.0.1 (a wildcard DNS service, a name kept for it): the rule list cannot see
    // where a name goes, so with the network on only https and wss are let through, and plain http and ws to such a name
    // must make no connection. Whether the name resolves here depends on this Mac's DNS: the check says, and runs the
    // plain web view's control only when it does.
    let publicNameList = ["127.0.0.1.nip.io", "127-0-0-1.nip.io", "localtest.me"]
    let resolving = publicNameList.filter(resolvesToLoopback)
    let plainToNames = publicNameList.flatMap { name in [("http \(name)", "http://\(name):\(port)/plain-\(name)"), ("ws \(name)", "ws://\(name):\(port)/ws-\(name)")] }
    func publicNamesPage(_ attempts: [(String, String)]) -> Data {
        let list = attempts.map { "[\(jsString($0.0)), \(jsString($0.1))]" }.joined(separator: ", ")
        return html("""
            <!doctype html><html><body>
            \(attempts.filter { $0.1.hasPrefix("http") }.map { "<img src=\"\($0.1)-img.png\">" }.joined())
            <script>
            window.results = {};
            (async () => {
              for (const [name, address] of [\(list)]) {
                const timeout = new Promise((ok) => setTimeout(() => ok("no answer"), 4000));
                if (address.startsWith("ws")) {
                  try { results[name] = await Promise.race([new Promise((ok, no) => { const w = new WebSocket(address); w.onopen = () => ok("open"); w.onerror = () => no(new Error("error")); }), timeout]); }
                  catch (e) { results[name] = "refused"; }
                } else {
                  try { const r = await Promise.race([fetch(address), timeout]); results[name] = typeof r === "string" ? r : "read " + (await r.text()).slice(0, 40); }
                  catch (e) { results[name] = "refused " + e.name; }
                }
              }
              window.done = true;
            })();
            </script></body></html>
            """)
    }
    let publicNames = folder("network-on-public-names", ["index.html": publicNamesPage(plainToNames)])
    await group("with the network allowed, plain http and ws to a public name that points back at this Mac make no connection") {
        info("of \(publicNameList.joined(separator: ", ")), \(resolving.count) resolve to 127.0.0.1 from this Mac\(resolving.isEmpty ? ": the control cannot show they would reach it" : "")")
        if let name = resolving.first {
            let before = listener.counts
            await control("<!doctype html><script>fetch('http://\(name):\(port)/control').then(() => {}, () => {}); window.done = true;</script>", base: URL(string: "http://\(name):\(port)/")!) { _ in
                try? await Task.sleep(for: .seconds(3))
            }
            check("the control: a plain web view does reach the listener through \(name)", listener.counts.connections > before.connections)
        }
        let before = listener.counts
        guard let (window, view) = await live(publicNames, network: true, waits: false) else { return }
        let got = await results(view)
        for (name, _) in plainToNames {
            check("\(name): refused", got[name]?.hasPrefix("refused") == true, got[name] ?? "no answer")
        }
        try? await Task.sleep(for: .seconds(1))
        close(window, view)
        let after = listener.counts
        check("no connection reached the listener", after.connections == before.connections, "paths \(after.paths.dropFirst(before.paths.count))")
    }

    // Over https, which the network lets through, so that only the rules for this Mac stand in the way (`loadsPage` makes
    // its WebSocket wss from it too).
    let loads = folder("network-on-loads", ["index.html": html(loadsPage(net: net.replacingOccurrences(of: "http:", with: "https:"), udp: listener.udpPort))])
    await group("with the network allowed, every way of loading something still reaches nothing on 127.0.0.1, and WebRTC is not there") {
        let before = listener.counts
        guard let (window, view) = await live(loads, network: true, waits: false) else { return }
        let got = await results(view)
        check("WebRTC is not there", got["webrtc"] == "absent", got["webrtc"] ?? "")
        try? await Task.sleep(for: .seconds(1))
        close(window, view)
        let after = listener.counts
        check("no TCP connection reached 127.0.0.1", after.connections == before.connections, "paths \(after.paths.dropFirst(before.paths.count))")
        check("no UDP datagram reached 127.0.0.1", after.datagrams == before.datagrams, "\(after.datagrams - before.datagrams)")
    }

    let names = ["RTCPeerConnection", "Notification", "PaymentRequest", "ApplePaySession", "PublicKeyCredential", "webkitSpeechRecognition",
                 "navigator.mediaDevices", "navigator.geolocation", "navigator.clipboard", "navigator.credentials", "navigator.share",
                 "navigator.getUserMedia", "navigator.serviceWorker"]
    let asks = folder("network-on-asks", [
        "index.html": html("""
            <!doctype html><html><body><input id="file" type="file"><a id="save" href="file.bin" download>save</a>
            <script>
            window.results = {};
            const w = window;
            results.missing = \(jsString(names.joined(separator: " "))).split(" ").filter((n) => (n.startsWith("navigator.") ? typeof w.navigator[n.slice(10)] : typeof w[n]) !== "undefined").join(",");
            results.alert = String(alert("Approve this command?"));
            results.confirm = String(confirm("Allow?"));
            results.prompt = String(prompt("Your password"));
            results.open = String(window.open(\(jsString(net + "/opened"))));
            results.openBlank = String(window.open(""));
            // A file picker and a download are offered only on the person's click: the check's script counts as one.
            window.gesture = () => { document.getElementById("file").click(); document.getElementById("save").click(); return 0; };
            window.done = true;
            </script></body></html>
            """),
        "file.bin": Data([0, 1, 2, 3]),
    ])
    await group("with the network allowed, nothing asks for a permission, opens a window, downloads, or leaves the page") {
        guard let (window, view) = await live(asks, network: true) else { return }
        defer { close(window, view) }
        var stopped: [URL] = []
        view.onBlockedNavigation = { stopped.append($0) }
        let got = await results(view)
        check("what asks for a permission or puts up the system's sheets is not there", got["missing"] == "", got["missing"] ?? "")
        check("an alert, a confirmation and a prompt are answered at once", got["alert"] == "undefined" && got["confirm"] == "false" && got["prompt"] == "null", "\(got)")
        check("window.open gives nothing", got["open"] == "null" && got["openBlank"] == "null", "\(got)")
        let clicked = await js(view, "try { await document.documentElement.requestFullscreen(); return 'full screen'; } catch (e) { return 'refused'; }") as? String
        check("no full screen", clicked == "refused", clicked ?? "")
        _ = await js(view, "return window.gesture()")
        _ = await until("the file picker and the download are answered", {
            view.record.answeredRequests.contains("a file, not chosen") && view.record.answeredRequests.contains("a download, not made")
        })
        let before = listener.counts
        _ = await js(view, "location.href = \(jsString(net + "/away")); return 0")
        guard await until("the navigation away is stopped and said", { !stopped.isEmpty }) else { return }
        check("it names the address", stopped.first?.absoluteString == net + "/away", "\(stopped)")
        try? await Task.sleep(for: .seconds(1))
        check("and the page stays", view.url?.path == "/index.html", view.url?.absoluteString ?? "")
        check("nothing reached 127.0.0.1", listener.counts.connections == before.connections)
        let shown = NSApp.windows.filter(\.isVisible)
        check("no window or panel is on screen", shown.isEmpty, shown.map(\.className).joined(separator: ", "))
    }
    // What is left, measured and said rather than checked: https to such a name connects, and the certificate check for
    // the name is what then stops it. The listener speaks no TLS, so nothing is read.
    if let name = resolving.first {
        let secure = folder("network-on-public-https", ["index.html": publicNamesPage([("https", "https://\(name):\(port)/tls"), ("wss", "wss://\(name):\(port)/wss")])])
        await group("with the network allowed, https to a public name that points back here: what is left, measured") {
            let before = listener.counts
            guard let (window, view) = await live(secure, network: true, waits: false) else { return }
            let got = await results(view)
            // Its process ended, so that no retry of the handshake comes after the group.
            _ = await view.end()
            close(window, view)
            try? await Task.sleep(for: .seconds(2))
            let reached = listener.counts.connections - before.connections
            info("https and wss to \(name): \(reached) connection\(reached == 1 ? "" : "s") reached the listener; the page saw \(got["https"] ?? "nothing") and \(got["wss"] ?? "nothing")")
            check("nothing was read: the listener holds no certificate for the name", !(got["https"]?.hasPrefix("read") ?? false) && got["wss"] != "open", "\(got)")
        }
    }
}

/// Whether a name resolves to 127.0.0.1 from this Mac.
func resolvesToLoopback(_ name: String) -> Bool {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(name, nil, &hints, &list) == 0, let first = list else { return false }
    defer { freeaddrinfo(first) }
    var next: UnsafeMutablePointer<addrinfo>? = first
    while let entry = next {
        if let address = entry.pointee.ai_addr, entry.pointee.ai_family == AF_INET {
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if UInt32(bigEndian: ip) == 0x7F00_0001 { return true }
        }
        next = entry.pointee.ai_next
    }
    return false
}
