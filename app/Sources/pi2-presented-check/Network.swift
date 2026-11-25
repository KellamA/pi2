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

    // 127.0.0.1 in each spelling a URL parser takes, the names this Mac answers itself, and a user before the host.
    let spellings: [(String, String)] = [
        ("127.0.0.1", "http://127.0.0.1:\(port)/a"), ("https", "https://127.0.0.1:\(port)/b"), ("localhost", "http://localhost:\(port)/c"),
        ("a name under .localhost", "http://probe.localhost:\(port)/d"), ("decimal", "http://2130706433:\(port)/e"), ("short", "http://127.1:\(port)/f"),
        ("hexadecimal", "http://0x7f.0.0.1:\(port)/g"), ("octal", "http://0177.0.0.1:\(port)/h"), ("IPv4 inside IPv6", "http://[::ffff:127.0.0.1]:\(port)/i"),
        ("a user before it", "http://user@127.0.0.1:\(port)/j"), ("a user and password before localhost", "http://user:pw@localhost:\(port)/k"),
        ("0.0.0.0", "http://0.0.0.0:\(port)/l"), ("a trailing dot", "http://localhost.:\(port)/m"), ("upper case", "HTTP://LOCALHOST:\(port)/n"),
        ("a trailing dot after an address", "http://127.0.0.1.:\(port)/o"), ("percent-encoded", "http://%6cocalhost:\(port)/p"),
        ("full-width letters", "http://\u{FF4C}\u{FF4F}\u{FF43}\u{FF41}\u{FF4C}\u{FF48}\u{FF4F}\u{FF53}\u{FF54}:\(port)/q"),
        ("a name under .localhost with a dot", "http://probe.localhost.:\(port)/r"), ("IPv4 inside IPv6, written out", "http://[0:0:0:0:0:ffff:7f00:1]:\(port)/s"),
    ]
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
          try { await new Promise((ok, no) => { const w = new WebSocket("ws://127.0.0.1:\(port)/ws"); w.onopen = ok; w.onerror = () => no(new Error("error")); }); results.websocket = "open"; }
          catch (e) { results.websocket = "refused"; }
          window.done = true;
        })();
        </script></body></html>
        """)])

    await group("with the network allowed, a page still reaches nothing on this Mac, however 127.0.0.1 is written") {
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
        check("a WebSocket to it is refused", got["websocket"] == "refused", got["websocket"] ?? "")
        try? await Task.sleep(for: .seconds(1))
        close(window, view)
        let after = listener.counts
        check("no TCP connection reached 127.0.0.1", after.connections == before.connections, "paths \(after.paths.dropFirst(before.paths.count))")
    }

    let loads = folder("network-on-loads", ["index.html": html(loadsPage(net: net, udp: listener.udpPort))])
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
}
