// The claims, each with the hostile page that tries it.

import AppKit
import TranscriptKit
import WebKit

/// The scheme handler's reading of an address, without a web view.
@MainActor
func paths() async {
    await group("the scheme handler looks up only a plain path of its own origin") {
        let origin = PresentedPagePolicy.newOrigin()
        func path(_ text: String) -> String? { URL(string: text).flatMap { PresentedPagePolicy.manifestPath(of: $0, origin: origin) } }
        check("a file at the origin", path("pi2-presented://\(origin)/index.html") == "index.html")
        check("in a folder, with a query and a fragment ignored", path("pi2-presented://\(origin)/css/site.css?v=2#x") == "css/site.css")
        check("a name with a space, encoded", path("pi2-presented://\(origin)/my%20page.html") == "my page.html")
        let refused = [
            "pi2-presented://\(origin)/../secret.txt", "pi2-presented://\(origin)/a/../../secret.txt",
            "pi2-presented://\(origin)/%2e%2e/secret.txt", "pi2-presented://\(origin)/%2E%2E/secret.txt",
            "pi2-presented://\(origin)/.%2e/secret.txt", "pi2-presented://\(origin)/..%2fsecret.txt",
            "pi2-presented://\(origin)/%2e%2e%2f%2e%2e%2fsecret.txt", "pi2-presented://\(origin)/a%2fb.txt",
            "pi2-presented://\(origin)/a%5c..%5csecret.txt", "pi2-presented://\(origin)/inside.txt%00.html",
            "pi2-presented://\(origin)/./index.html", "pi2-presented://\(origin)//index.html", "pi2-presented://\(origin)/",
            "pi2-presented://\(origin)/" + String(repeating: "a", count: 5000),
            "pi2-presented://\(origin)/" + String(repeating: "a/", count: 600) + "index.html",
            "pi2-presented://pother/index.html", "pi2-presented://\(origin):80/index.html",
            "pi2-presented://user@\(origin)/index.html", "file:///etc/hosts", "http://\(origin)/index.html",
            "pi2-presented:index.html", "pi2-presented:///index.html",
        ]
        for text in refused {
            check("refused: \(text.prefix(80))", path(text) == nil, "looked up \(path(text) ?? "")")
        }
        check("every origin is new", PresentedPagePolicy.newOrigin() != PresentedPagePolicy.newOrigin())
    }
}

/// A page of its own draws: its stylesheet, script, picture, inline style and script, storage; its console and a
/// missing file are reported; it is not blank.
@MainActor
func drawsItsOwnPage(pictures: URL?) async {
    let files = folder("own", [
        "index.html": html("""
            <!doctype html><html><head><meta charset="utf-8"><title>Sign-in</title>
            <link rel="stylesheet" href="css/site.css"><link rel="stylesheet" href="missing.css">
            <style>.inline { color: rgb(4, 5, 6); }</style></head>
            <body><h1 class="inline">Sign in</h1><img id="logo" src="img/logo.png"><img id="data" src="data:image/png;base64,\(png(width: 8, height: 8).base64EncodedString())">
            <p style="margin-top: 1900px">The end of a long page.</p>
            <a id="next" href="page2.html">Next</a>
            <script>window.inline = true;</script><script src="js/app.js"></script></body></html>
            """),
        "css/site.css": html("body { background: rgb(1, 2, 3); color: white; font: 16px system-ui; }"),
        "js/app.js": html("console.log('hello from app.js', { step: 1 });\nlocalStorage.setItem('kept', 'yes');\nsetTimeout(() => { null.missing; }, 0);\n"),
        "img/logo.png": png(),
        "page2.html": html("<!doctype html><title>Page two</title><p>Page two</p>"),
    ])
    let page = files.manifest()
    await group("a page draws with its own files, scripts and styles, and its findings say what it did") {
        check("the manifest has its files", Set(page.files.map(\.path)) == ["index.html", "css/site.css", "js/app.js", "img/logo.png", "page2.html"], "\(page.files.map(\.path))")
        var seen: [String: Any] = [:]
        let found = await PresentedPageDrawing.draw(page: page, source: files) { view in
            seen = await js(view, """
                return { background: getComputedStyle(document.body).backgroundColor, inline: getComputedStyle(document.querySelector('.inline')).color,
                  script: window.inline === true, logo: document.getElementById('logo').naturalWidth, data: document.getElementById('data').naturalWidth,
                  storage: localStorage.getItem('kept'), secure: window.isSecureContext, origin: location.protocol + '//' + location.host };
                """) as? [String: Any] ?? [:]
        }
        check("it loaded", found.ok, found.reason ?? "")
        check("in a reasonable time", found.loadMs > 0 && found.loadMs < 15000, "\(found.loadMs) ms")
        check("its stylesheet applies", seen["background"] as? String == "rgb(1, 2, 3)", "\(seen)")
        check("its inline style applies", seen["inline"] as? String == "rgb(4, 5, 6)", "\(seen)")
        check("its inline script ran", seen["script"] as? Bool == true)
        check("its picture loaded", (seen["logo"] as? Int) == 64, "\(seen)")
        check("a data: picture loaded", (seen["data"] as? Int) == 8, "\(seen)")
        check("its storage works", seen["storage"] as? String == "yes", "\(seen)")
        check("it is at its own pi2-presented origin", (seen["origin"] as? String)?.hasPrefix("pi2-presented://p") == true, "\(seen)")
        info("a page is \(seen["secure"] as? Bool == true ? "" : "not ")a secure context (window.isSecureContext)")
        check("it is not blank", !found.blank)
        check("drawn 1280 wide and taller than the view", found.width == 1280 && found.height > 1900, "\(found.width)×\(found.height)")
        check("its console's line is reported", found.console.contains { $0.hasPrefix("log: hello from app.js {\"step\":1}") }, "\(found.console)")
        check("its script error is reported, with where", found.console.contains { $0.hasPrefix("error: TypeError") && $0.contains("at js/app.js:3") }, "\(found.console)")
        check("the file it could not find is reported", found.notFound == ["missing.css"], "\(found.notFound)")
        check("nothing was blocked", found.blocked.isEmpty, "\(found.blocked)")
        check("it is pictured, a PNG", found.snapshot?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)
        if let pictures, let snapshot = found.snapshot {
            try? snapshot.write(to: pictures.appendingPathComponent("own-page.png"))
            info("pictured own-page.png")
        }
    }
}

@MainActor
func blankPage() async {
    await group("a page that draws nothing is said to be blank") {
        let files = folder("blank", ["index.html": html("<!doctype html><body style=\"background: #f4f4f4\"><div></div><script>document.title = 'x';</script></body>")])
        let found = await PresentedPageDrawing.draw(page: files.manifest(), source: files)
        check("it loaded", found.ok, found.reason ?? "")
        check("it is blank", found.blank)
        let missing = await PresentedPageDrawing.draw(page: PresentedPage(entry: "nothing.html", files: files.manifest().files), source: files)
        check("an entry not in the copy is not drawn as a page", !missing.ok || missing.blank, "ok \(missing.ok), blank \(missing.blank)")
        check("and is reported as not found", missing.notFound.contains("nothing.html"), "\(missing.notFound)")
    }
}

/// Fetches each address, and says what came back: the status, and whether the secret was in it.
func fetchAll(_ attempts: [(String, String)]) -> String {
    let list = attempts.map { "[\(jsString($0.0)), \(jsString($0.1))]" }.joined(separator: ", ")
    return """
        <script>
        window.results = {};
        (async () => {
          for (const [name, address] of [\(list)]) {
            try {
              const response = await fetch(address);
              const text = await response.text();
              results[name] = response.status + (text.includes(\(jsString(secretMarker))) ? " SECRET" : "") + (text.includes("INSIDE-OK") ? " inside" : "");
            } catch (error) { results[name] = "refused " + error.name; }
          }
          window.done = true;
        })();
        </script>
        """
}

func jsString(_ text: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast().description
}

@MainActor
func outsideTheManifest() async {
    let attempts: [(String, String)] = [
        ("inside", "inside.txt"), ("in a folder", "sub/inner.txt"),
        ("..", "../secret.txt"), ("../..", "../../secret.txt"), ("../../.. from a folder", "sub/../../../secret.txt"),
        ("%2e%2e", "%2e%2e/%2e%2e/secret.txt"), ("%2E%2E", "%2E%2E/%2E%2E/secret.txt"), (".%2e", ".%2e/.%2e/secret.txt"),
        ("..%2f", "..%2f..%2fsecret.txt"), ("%2e%2e%2f", "%2e%2e%2f%2e%2e%2fsecret.txt"), ("backslashes", "..\\..\\secret.txt"),
        ("%5c", "..%5c..%5csecret.txt"), ("a link to the secret", "link.txt"), ("a link by its full path", "abslink.txt"),
        ("a link to the folder above", "dirlink/secret.txt"), ("through the link back in", "dirlink/pages/paths/inside.txt"),
        ("a NUL", "inside.txt%00"), ("the secret's own path", secret.path),
        ("a very long path", String(repeating: "a", count: 100_000)), ("a very deep path", String(repeating: "sub/", count: 2000) + "inner.txt"),
    ]
    let files = folder("paths", [
        "index.html": html("<!doctype html><p>Paths</p>" + fetchAll(attempts)),
        "inside.txt": html("INSIDE-OK"),
        "sub/inner.txt": html("INSIDE-OK"),
    ], links: [("link.txt", "../../secret.txt"), ("abslink.txt", secret.path), ("dirlink", "../..")])
    let page = files.manifest()

    await group("the copy's manifest leaves out symbolic links, and its reader follows none") {
        check("the manifest has the files alone", Set(page.files.map(\.path)) == ["index.html", "inside.txt", "sub/inner.txt"], "\(page.files.map(\.path))")
        let size = secretMarker.utf8.count
        for path in ["link.txt", "abslink.txt", "dirlink/secret.txt", "../secret.txt", "sub/../../../secret.txt"] {
            let read = try? await files.bytes(of: PresentedFile(path: path, size: size, mimeType: "text/plain"))
            check("the reader refuses \(path)", read == nil)
        }
    }

    await group("a page cannot be served a path outside its manifest: .., %2e%2e, a symbolic link, a very long path") {
        let found = await PresentedPageDrawing.draw(page: page, source: files) { view in
            let got = await results(view)
            check("it read its own files", got["inside"] == "200 inside" && got["in a folder"] == "200 inside", "\(got)")
            for (name, _) in attempts.dropFirst(2) {
                let result = got[name] ?? "no answer"
                check("\(name): no secret, and nothing served", !result.contains("SECRET") && !result.hasPrefix("200"), result)
            }
        }
        check("it loaded", found.ok, found.reason ?? "")
        check("what it asked for is reported as not found", found.notFound.contains("link.txt") && found.notFound.contains("secret.txt"), "\(found.notFound)")
    }

    await group("a manifest that names a link, or a file whose size has changed, is still not served") {
        // As if the engine had listed them: the reader refuses the links, and the handler a file of another size.
        var listed = page.files.filter { $0.path != "inside.txt" }
        listed.append(PresentedFile(path: "inside.txt", size: 3, mimeType: "text/plain"))
        for path in ["link.txt", "abslink.txt", "dirlink/secret.txt"] {
            listed.append(PresentedFile(path: path, size: secretMarker.utf8.count, mimeType: "text/plain"))
        }
        let forced = PresentedPage(entry: "index.html", files: listed)
        let found = await PresentedPageDrawing.draw(page: forced, source: files) { view in
            let got = await results(view)
            for name in ["a link to the secret", "a link by its full path", "a link to the folder above", "inside"] {
                let result = got[name] ?? "no answer"
                check("\(name): not served", result.hasPrefix("404"), result)
            }
        }
        check("it loaded", found.ok, found.reason ?? "")
    }
}

@MainActor
func noFileAddress() async {
    let file = secret.absoluteString
    let files = folder("file", ["index.html": html("""
        <!doctype html><html><head><link rel="stylesheet" href="\(file)"><script src="\(file)"></script></head><body>
        <img id="img" src="\(file)"><iframe id="frame" src="\(file)"></iframe><object data="\(file)"></object>
        <script>
        window.results = {};
        (async () => {
          try { results.fetch = await (await fetch(\(jsString(file)))).text(); } catch (e) { results.fetch = "refused " + e.name; }
          results.xhr = await new Promise((done) => { try { const x = new XMLHttpRequest(); x.open("GET", \(jsString(file))); x.onload = () => done(x.responseText); x.onerror = () => done("refused"); x.send(); } catch (e) { done("refused " + e.name); } });
          await new Promise((r) => setTimeout(r, 300));
          results.img = String(document.getElementById("img").naturalWidth);
          try { results.frame = document.getElementById("frame").contentDocument?.documentElement?.outerHTML ?? "unreadable"; } catch (e) { results.frame = "refused " + e.name; }
          results.open = String(window.open(\(jsString(file))));
          window.done = true;
          location.href = \(jsString(file));
        })();
        </script></body></html>
        """)])
    await group("a page cannot load a file: address, by any way it has") {
        var url: URL?
        let found = await PresentedPageDrawing.draw(page: files.manifest(), source: files) { view in
            let got = await results(view)
            for (name, result) in got { check("\(name): nothing of the file", !result.contains(secretMarker), result) }
            check("the picture did not load", got["img"] == "0", "\(got)")
            try? await Task.sleep(for: .seconds(1))
            url = view.url
        }
        check("it loaded", found.ok, found.reason ?? "")
        check("it stayed on its own page", url?.scheme == PresentedPagePolicy.scheme, url?.absoluteString ?? "none")
        // The policy names a file: address by its scheme alone.
        check("a file: address is reported as blocked", found.blocked.contains { $0.hasPrefix("file") }, "\(found.blocked)")
    }
}

@MainActor
func otherOrigin() async {
    let first = folder("origin-a", [
        "index.html": html("<!doctype html><p>A</p><script>localStorage.setItem('a', 'from A'); sessionStorage.setItem('a', 'from A'); document.cookie = 'a=1';</script>"),
        "a-only.txt": html("A-FILE"),
    ])
    await group("a page cannot reach another presentation's origin, and shares nothing with it") {
        guard let (window, a) = await live(first) else { return }
        defer { close(window, a) }
        let other = "pi2-presented://\(a.origin)"
        let second = folder("origin-b", ["index.html": html("""
            <!doctype html><p>B</p><iframe id="frame" src="\(other)/index.html"></iframe>
            <script>
            window.results = {};
            (async () => {
              for (const [name, address] of [["their file", "\(other)/a-only.txt"], ["their page", "\(other)/index.html"], ["their file at this origin", "a-only.txt"]]) {
                try { const r = await fetch(address); const t = await r.text(); results[name] = r.status + (t.includes("A-FILE") || t.includes("<p>A") ? " THEIRS" : ""); }
                catch (e) { results[name] = "refused " + e.name; }
              }
              results.storage = String(localStorage.getItem("a")) + " " + String(sessionStorage.getItem("a")) + " " + document.cookie;
              await new Promise((r) => setTimeout(r, 300));
              try { results.frame = document.getElementById("frame").contentDocument?.body?.innerHTML ?? "none"; } catch (e) { results.frame = "refused " + e.name; }
              window.done = true;
            })();
            </script>
            """)])
        check("the first stored what it stores", await js(a, "return localStorage.getItem('a')") as? String == "from A")
        let found = await PresentedPageDrawing.draw(page: second.manifest(), source: second) { view in
            check("the second has another origin", view.origin != a.origin)
            let got = await results(view)
            for (name, result) in got { check("\(name): nothing of the other", !result.contains("THEIRS") && !result.contains("from A") && !result.contains("a=1") && !result.contains("<p>A"), result) }
            check("its storage has nothing", got["storage"] == "null null ", got["storage"] ?? "")
        }
        check("it loaded", found.ok, found.reason ?? "")
        check("the other's addresses are reported", found.notFound.contains { $0.contains(a.origin) } || found.blocked.contains { $0.contains(a.origin) }, "\(found.notFound) \(found.blocked)")
    }
}

/// Every way a page has to load something, aimed at `net`; the WebRTC one at the UDP port.
func loadsPage(net: String, udp: Int) -> String {
    """
    <!doctype html><html><head>
    <link rel="stylesheet" href="\(net)/link-stylesheet.css"><link rel="preconnect" href="\(net)/"><link rel="prefetch" href="\(net)/prefetch">
    <link rel="preload" href="\(net)/preload.js" as="script"><link rel="icon" href="\(net)/icon.png"><link rel="modulepreload" href="\(net)/modulepreload.js">
    <style>
    @import url("\(net)/import.css");
    @font-face { font-family: Probe; src: url("\(net)/font.woff2"); }
    body { background-image: url("\(net)/css-background.png"); font-family: Probe, system-ui; }
    .set { background-image: image-set("\(net)/image-set.png" 1x); }
    </style>
    <script src="\(net)/script.js"></script>
    </head><body>
    <p class="set">Probe text</p>
    <img src="\(net)/img.png"><img srcset="\(net)/srcset.png 1x"><picture><source srcset="\(net)/source.png"><img></picture>
    <iframe src="\(net)/iframe.html"></iframe>
    <video src="\(net)/video.mp4" preload="auto" poster="\(net)/poster.png"></video><audio src="\(net)/audio.mp3" preload="auto"></audio>
    <object data="\(net)/object.html"></object><embed src="\(net)/embed.html">
    <svg width="10" height="10"><image href="\(net)/svg-image.png" width="10" height="10"/></svg>
    <input type="image" src="\(net)/input-image.png">
    <a id="ping" href="#here" ping="\(net)/ping">ping</a>
    <script>
    const net = \(jsString(net));
    window.results = {};
    const attempt = async (name, run) => {
      try { results[name] = String(await Promise.race([run(), new Promise((r) => setTimeout(() => r("no answer"), 3000))])); }
      catch (e) { results[name] = "refused " + (e?.name ?? e); }
    };
    (async () => {
      await attempt("fetch", () => fetch(net + "/fetch").then((r) => r.status));
      await attempt("fetch no-cors", () => fetch(net + "/fetch-no-cors", { mode: "no-cors" }).then((r) => r.type));
      await attempt("xhr", () => new Promise((ok, no) => { const x = new XMLHttpRequest(); x.open("GET", net + "/xhr"); x.onload = () => ok(x.status); x.onerror = () => no(new Error("error")); x.send(); }));
      await attempt("websocket", () => new Promise((ok, no) => { const w = new WebSocket(net.replace("http", "ws") + "/websocket"); w.onopen = () => ok("open"); w.onerror = () => no(new Error("error")); }));
      await attempt("eventsource", () => new Promise((ok, no) => { const e = new EventSource(net + "/eventsource"); e.onopen = () => ok("open"); e.onerror = () => { e.close(); no(new Error("error")); }; }));
      await attempt("beacon", () => navigator.sendBeacon(net + "/beacon", "x"));
      await attempt("image", () => new Promise((ok, no) => { const i = new Image(); i.onload = () => ok("loaded"); i.onerror = () => no(new Error("error")); i.src = net + "/new-image.png"; }));
      await attempt("worker", () => { new Worker(net + "/worker.js"); return "made"; });
      await attempt("shared worker", () => { new SharedWorker(net + "/shared-worker.js"); return "made"; });
      await attempt("import", () => import(net + "/module.js"));
      await attempt("https", () => fetch(net.replace("http:", "https:") + "/https").then((r) => r.status));
      await attempt("css paint", () => { document.body.style.cursor = `url("${net}/cursor.png"), auto`; return "set"; });
      await attempt("base", () => { const b = document.createElement("base"); b.href = net + "/"; document.head.append(b); const i = new Image(); i.src = "base-relative.png"; return "set"; });
      await attempt("webrtc", async () => {
        if (typeof RTCPeerConnection === "undefined") return "absent";
        const pc = new RTCPeerConnection({ iceServers: [{ urls: "stun:127.0.0.1:\(udp)" }, { urls: "turn:127.0.0.1:\(udp)?transport=udp", username: "u", credential: "c" }] });
        pc.createDataChannel("probe");
        await pc.setLocalDescription(await pc.createOffer());
        await new Promise((r) => setTimeout(r, 2000));
        return "gathered " + pc.iceGatheringState;
      });
      document.getElementById("ping").click();
      await new Promise((r) => setTimeout(r, 500));
      window.done = true;
    })();
    </script></body></html>
    """
}

@MainActor
func networkLoads(listener: Listener, net: String) async {
    let files = folder("network", ["index.html": html(loadsPage(net: net, udp: listener.udpPort))])
    await group("with the network off, a page reaches nothing on 127.0.0.1 by any way it has to load something") {
        let before = listener.counts
        let found = await PresentedPageDrawing.draw(page: files.manifest(), source: files) { view in
            let got = await results(view)
            check("WebRTC is not there", got["webrtc"] == "absent", got["webrtc"] ?? "")
            check("fetch is refused", got["fetch"]?.hasPrefix("refused") == true, got["fetch"] ?? "")
            check("a WebSocket is refused", got["websocket"]?.hasPrefix("refused") == true, got["websocket"] ?? "")
            // Whatever the page saw, what reached the listener is what counts; time for the slowest to try.
            try? await Task.sleep(for: .seconds(1))
        }
        check("it loaded", found.ok, found.reason ?? "")
        let after = listener.counts
        check("no TCP connection reached 127.0.0.1", after.connections == before.connections, "paths \(after.paths.dropFirst(before.paths.count))")
        check("no UDP datagram reached 127.0.0.1", after.datagrams == before.datagrams, "\(after.datagrams - before.datagrams)")
        check("what it tried is reported as blocked", found.blocked.contains { $0.hasPrefix(net) }, "\(found.blocked)")
        info("blocked, as the agent is told: \(found.blocked.count) addresses, such as \(found.blocked.prefix(3).joined(separator: ", "))")
    }

    await group("the same page in a plain web view does reach 127.0.0.1: the probes work") {
        let before = listener.counts
        await control(loadsPage(net: net, udp: listener.udpPort), base: URL(string: net + "/")!) { view in
            _ = await results(view)
            try? await Task.sleep(for: .seconds(1))
        }
        let after = listener.counts
        let reached = Set(after.paths.dropFirst(before.paths.count))
        check("most ways reached it", reached.count >= 10, "\(reached.sorted())")
        for way in ["/fetch", "/xhr", "/img.png", "/css-background.png", "/import.css", "/script.js", "/eventsource", "/beacon", "/websocket"] {
            check("\(way) reached it", reached.contains(way), "\(reached.sorted())")
        }
        info("the plain view reached it by \(reached.count) paths, and sent \(after.datagrams - before.datagrams) UDP datagrams (WebRTC's STUN)")
        if after.datagrams == before.datagrams {
            info("WebRTC did not reach the UDP listener even in the plain view, so that claim rests on RTCPeerConnection being taken away, which is checked in every kind of frame")
        }
    }
}

@MainActor
func navigations(listener: Listener, net: String) async {
    // Each on a page of its own: a navigation begun while the page loads can stop the rest of it.
    let ways: [(String, String)] = [
        ("a meta refresh", "<meta http-equiv=\"refresh\" content=\"0; url=\(net)/refresh\">"),
        ("a form posted", "<form id=f method=post action=\"\(net)/form\"><input name=n value=v></form><script>f.submit()</script>"),
        ("a form submitted", "<form id=f action=\"\(net)/form-get\"></form><script>f.requestSubmit()</script>"),
        ("a link", "<a id=a href=\"\(net)/link\">x</a><script>a.click()</script>"),
        ("a link to a new window", "<a id=a href=\"\(net)/blank\" target=_blank>x</a><script>a.click()</script>"),
        ("a link to download", "<a id=a href=\"\(net)/download\" download>x</a><script>a.click()</script>"),
        ("a link not in the page", "<script>const a = document.createElement('a'); a.href = \"\(net)/detached\"; a.click()</script>"),
        ("a click sent to a link not in the page", "<script>const a = document.createElement('a'); a.href = \"\(net)/detached2\"; const s = document.createElement('span'); a.append(s); s.dispatchEvent(new MouseEvent('click', { bubbles: true }))</script>"),
        ("an image map's area", "<map name=m><area id=r shape=rect coords=0,0,10,10 href=\"\(net)/area\"></map><img usemap=#m><script>r.click()</script>"),
        ("an SVG link", "<svg><a id=s href=\"\(net)/svg\"><text>x</text></a></svg><script>s.dispatchEvent(new MouseEvent('click', { bubbles: true }))</script>"),
        ("a link in an empty frame, to the top", "<script>const f = document.createElement('iframe'); document.body.append(f); const a = f.contentDocument.createElement('a'); a.href = \"\(net)/iframe\"; a.target = '_top'; a.click()</script>"),
        ("window.open", "<script>window.open(\"\(net)/open\")</script>"),
        ("location.href", "<script>location.href = \"\(net)/location\"</script>"),
        ("location.replace", "<script>location.replace(\"\(net)/replace\")</script>"),
        ("top.location", "<script>top.location = \"\(net)/top\"</script>"),
    ]
    await group("a page cannot leave its origin, nor connect ahead: a form, a meta refresh, links of every kind, a script, window.open") {
        for (index, (name, body)) in ways.enumerated() {
            let files = folder("navigation-\(index)", ["index.html": html("<!doctype html><html><head></head><body>\(body)</body></html>")])
            let before = listener.counts
            var url: URL?
            let found = await PresentedPageDrawing.draw(page: files.manifest(), source: files) { view in
                // Time for what the page began to reach the listener, had it been let through.
                try? await Task.sleep(for: .seconds(2))
                url = view.url
            }
            let after = listener.counts
            check("\(name): it loaded", found.ok || found.reason?.contains("did not finish") == true, found.reason ?? "")
            check("\(name): nothing reached 127.0.0.1, not even a connection ahead", after.connections == before.connections, "paths \(after.paths.dropFirst(before.paths.count))")
            check("\(name): it is still its own page", url?.scheme == PresentedPagePolicy.scheme && url?.path == "/index.html", url?.absoluteString ?? "none")
        }
    }

    let several = folder("several", [
        "index.html": html("<!doctype html><a href=\"page2.html\">Next</a>"),
        "page2.html": html("<!doctype html><p>Two</p>"),
    ])
    await group("a link within the page's own origin is followed; one away from it is stopped and said") {
        guard let (window, view) = await live(several) else { return }
        defer { close(window, view) }
        var stopped: [URL] = []
        view.onBlockedNavigation = { stopped.append($0) }
        _ = await js(view, "location.href = 'page2.html'; return 0")
        guard await until("it goes to its second page", { view.url?.path == "/page2.html" }) else { return }
        _ = await until("which loads", { await js(view, "return document.body?.textContent") as? String == "Two" })
        _ = await js(view, "location.href = \(jsString(net + "/away")); return 0")
        guard await until("the link away is said", { !stopped.isEmpty }) else { return }
        check("it names the address", stopped.first?.absoluteString == net + "/away", "\(stopped)")
        check("and the page stays", view.url?.path == "/page2.html", view.url?.absoluteString ?? "")
    }
}

@MainActor
func panels(listener: Listener, net: String) async {
    let names = ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "webkitSpeechRecognition", "SpeechRecognition",
                 "Notification", "PaymentRequest", "ApplePaySession", "PublicKeyCredential", "navigator.mediaDevices",
                 "navigator.geolocation", "navigator.clipboard", "navigator.credentials", "navigator.share", "navigator.getUserMedia",
                 "navigator.webkitGetUserMedia", "navigator.serviceWorker"]
    let probe = "(w) => Object.fromEntries(\(jsString(names.joined(separator: " "))).split(' ').map((n) => [n, n.startsWith('navigator.') ? typeof w.navigator[n.slice(10)] : typeof w[n]]))"
    let files = folder("panels", [
        "index.html": html("""
            <!doctype html><html><body><input id="file" type="file"><iframe id="same" src="frame.html"></iframe>
            <iframe id="srcdoc" srcdoc="<p>srcdoc</p>"></iframe>
            <script>
            window.results = {};
            const probe = \(probe);
            results.alert = String(alert("Approve this command?"));
            results.confirm = String(confirm("Allow?"));
            results.prompt = String(prompt("Your password"));
            results.open = String(window.open(\(jsString(net + "/opened"))));
            results.openBlank = String(window.open(""));
            results.print = String(window.print());
            document.getElementById("file").click();
            window.gesture = async () => {
              const r = { active: String(navigator.userActivation?.isActive) };
              r.alert = String(alert("again")); r.confirm = String(confirm("again")); r.prompt = String(prompt("again"));
              r.open = String(window.open("about:blank")); r.openNet = String(window.open(\(jsString(net + "/opened-on-click")), "_blank"));
              document.getElementById("file").click();
              r.print = String(window.print());
              try { await document.documentElement.requestFullscreen(); r.fullscreen = "full screen"; } catch (e) { r.fullscreen = "refused " + e.name; }
              try { await document.documentElement.webkitRequestFullscreen?.(); } catch {}
              r.fullscreenElement = String(document.fullscreenElement ?? document.webkitFullscreenElement ?? null);
              return JSON.stringify(r);
            };
            window.frames_ = async () => {
              const out = { main: probe(window) };
              const blank = document.createElement("iframe"); document.body.append(blank);
              out.blank = probe(blank.contentWindow);
              const nested = blank.contentDocument.createElement("iframe"); blank.contentDocument.body.append(nested);
              out.nested = probe(nested.contentWindow);
              await new Promise((r) => setTimeout(r, 300));
              out.same = probe(document.getElementById("same").contentWindow);
              out.srcdoc = probe(document.getElementById("srcdoc").contentWindow);
              const written = window.open ? null : null;
              const doc = document.createElement("iframe"); doc.src = "about:blank"; document.body.append(doc);
              doc.contentDocument.open(); doc.contentDocument.write("<p>written</p>"); doc.contentDocument.close();
              out.written = probe(doc.contentWindow);
              return JSON.stringify(out);
            };
            window.done = true;
            </script></body></html>
            """),
        "frame.html": html("<!doctype html><p>frame</p>"),
    ])
    await group("nothing a page does puts up a panel or a window, with the person's click too") {
        let found = await PresentedPageDrawing.draw(page: files.manifest(), source: files) { view in
            let got = await results(view)
            check("an alert returns at once", got["alert"] == "undefined", "\(got)")
            check("a confirmation is answered no", got["confirm"] == "false", "\(got)")
            check("a prompt is answered with nothing", got["prompt"] == "null", "\(got)")
            check("window.open gives nothing", got["open"] == "null" && got["openBlank"] == "null", "\(got)")
            let clicked = (await js(view, "return await window.gesture()") as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] } ?? [:]
            info("the check's scripts count as the person's click: navigator.userActivation.isActive is \(clicked["active"] ?? "?")")
            check("on a click too: alert, confirm, prompt", clicked["alert"] == "undefined" && clicked["confirm"] == "false" && clicked["prompt"] == "null", "\(clicked)")
            check("on a click too: no window", clicked["open"] == "null" && clicked["openNet"] == "null", "\(clicked)")
            check("no full screen", clicked["fullscreen"]?.hasPrefix("refused") == true && clicked["fullscreenElement"] == "null", "\(clicked)")
            check("a file picker was answered with no file, without a panel", view.record.answeredRequests.contains("a file, not chosen"), "\(view.record.answeredRequests)")
            check("a window asked for on a click was refused", view.record.answeredRequests.contains("a new window, not opened"), "\(view.record.answeredRequests)")
            let shown = NSApp.windows.filter(\.isVisible)
            check("no window or panel is on screen", shown.isEmpty, shown.map { "\($0.className)" }.joined(separator: ", "))
            check("no print panel", !NSApp.windows.contains { $0 is NSPanel && $0.className.contains("Print") })
        }
        check("it loaded", found.ok, found.reason ?? "")
        for asked in ["an alert, not shown", "a confirmation, answered no", "a prompt, answered with nothing"] {
            check("the findings say: \(asked)", found.answered.contains(asked), "\(found.answered)")
        }
    }

    await group("what would ask for a permission or put up the system's own sheets is not there, in any kind of frame") {
        let found = await PresentedPageDrawing.draw(page: files.manifest(), source: files) { view in
            _ = await results(view)
            let text = await js(view, "return await window.frames_()") as? String ?? "{}"
            let frames = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: [String: String]]) ?? [:]
            check("every kind of frame was probed", Set(frames.keys) == ["main", "blank", "nested", "same", "srcdoc", "written"], text)
            for (frame, found) in frames.sorted(by: { $0.key < $1.key }) {
                let there = found.filter { $0.value != "undefined" }.keys.sorted()
                check("\(frame) frame: none of them", there.isEmpty, "there: \(there.joined(separator: ", "))")
            }
        }
        check("it loaded", found.ok, found.reason ?? "")
    }
}

@MainActor
func messageHandlers() async {
    let files = folder("handlers", [
        "index.html": html("""
            <!doctype html><iframe id="frame" src="frame.html"></iframe>
            <script>
            const log = window.webkit?.messageHandlers?.pi2log;
            if (log) { log.postMessage({ not: "a string" }); log.postMessage(42); log.postMessage("console log: posted directly"); }
            setTimeout(() => { window.done = true; }, 500);
            </script>
            """),
        "frame.html": html("<!doctype html><script>window.webkit?.messageHandlers?.pi2log?.postMessage('console log: from a frame');</script>"),
    ])
    await group("the live view has no message handler; the offscreen one takes strings from its main frame alone") {
        if let (window, view) = await live(files) {
            let handlers = await js(view, "return typeof window.webkit === 'undefined' ? 'none' : String(Object.getOwnPropertyNames(window.webkit.messageHandlers)) + ' ' + typeof window.webkit.messageHandlers.pi2log + ' ' + typeof window.webkit.messageHandlers.pi2")
            check("window.webkit.messageHandlers is empty", handlers as? String == "none" || handlers as? String == " undefined undefined", "\(handlers ?? "nil")")
            close(window, view)
        }
        let found = await PresentedPageDrawing.draw(page: files.manifest(), source: files) { view in
            _ = await results(view)
        }
        check("a string from the main frame is a console line", found.console == ["log: posted directly"], "\(found.console)")

        let chatty = folder("chatty", ["index.html": html("""
            <!doctype html><script>
            for (let i = 0; i < 80; i++) console.log("line " + i + " " + "x".repeat(900));
            for (let i = 0; i < 40; i++) new Image().src = "http://127.0.0.1:9/" + i + ".png";
            window.results = {}; window.done = true;
            </script>
            """)])
        let capped = await PresentedPageDrawing.draw(page: chatty.manifest(), source: chatty) { view in _ = await results(view) }
        check("at most 50 console lines", capped.console.count == 50, "\(capped.console.count)")
        check("of at most 500 characters", capped.console.allSatisfy { $0.count <= 500 }, "\(capped.console.map(\.count).max() ?? 0)")
        check("at most 20 blocked addresses", capped.blocked.count == 20, "\(capped.blocked.count)")
    }
}

@MainActor
func processEnds() async {
    let files = folder("process", ["index.html": html("<!doctype html><p>Alive</p>")])
    await group("a page whose process ends is drawn again once; a second time is said") {
        guard let (window, view) = await live(files) else { return }
        defer { close(window, view) }
        var ended = 0
        view.onProcessEnded = { ended += 1 }
        guard let first = process(of: view) else {
            check("WebKit names the page's process for this check", false, "no _webProcessIdentifier")
            return
        }
        Darwin.kill(first, SIGKILL)
        guard await until("it is loaded again", { view.reloads == 1 && process(of: view).map { $0 != first } == true }) else { return }
        guard await until("and shows its page", { await js(view, "return document.body?.textContent") as? String == "Alive" }) else { return }
        check("it was not said to have ended", ended == 0)
        guard let second = process(of: view) else { return }
        Darwin.kill(second, SIGKILL)
        guard await until("the second end is said", { ended == 1 }) else { return }
        check("and it is not loaded a third time", view.reloads == 1)
    }
}
