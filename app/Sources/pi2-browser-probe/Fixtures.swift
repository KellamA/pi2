import Foundation

/// The pages the probe serves to itself. `other` is the origin of a second local server that stands in for a service
/// on the person's Mac: nothing the browser does may ever reach it.
enum Fixtures {
    static func respond(to request: FixtureServer.Request, other: String) -> FixtureServer.Response {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        switch path {
        case "/form": return .html(form(other: other))
        case "/next": return .html("<!doctype html><title>Next page</title><h1>You followed the link</h1><p>This is the next page.</p><a href=\"/form\">Back to the form</a>")
        case "/submitted": return .html(submitted(request))
        case "/long": return .html(long)
        case "/embeds": return .html(embeds(other: other))
        case "/inner": return .html("<!doctype html><title>Inner</title><p>Text inside the frame.</p><button onclick=\"this.textContent='Pressed inside'\">Inner button</button>")
        case "/slow": return .html(slow)
        case "/dialogs": return .html(dialogs)
        case "/state": return .html(state)
        case "/redirect-private": return .redirect("\(other)/secret")
        case "/links": return .html(links(other: other))
        case "/download":
            return FixtureServer.Response(headers: ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=\"report.bin\""], body: Data([1, 2, 3, 4]))
        case "/set-cookie":
            return FixtureServer.Response(headers: ["Content-Type": "text/html; charset=utf-8", "Set-Cookie": "probe=remembered; Path=/"], body: Data("<title>Cookie set</title><p>Cookie set.</p>".utf8))
        case "/cookie":
            return .html("<!doctype html><title>Cookie</title><p>Cookie header: \(request.headers["cookie"] ?? "none")</p>")
        default: return .notFound
        }
    }

    /// What a posted form held: its text fields, and the name and size of each file.
    private static func submitted(_ request: FixtureServer.Request) -> String {
        let body = String(decoding: request.body, as: UTF8.self)
        var lines: [String] = []
        for part in body.components(separatedBy: "Content-Disposition: form-data; ").dropFirst() {
            guard let nameEnd = part.range(of: "\""), let nameClose = part[nameEnd.upperBound...].range(of: "\"") else { continue }
            let name = String(part[nameEnd.upperBound..<nameClose.lowerBound])
            guard let blank = part.range(of: "\r\n\r\n") else { continue }
            let value = part[blank.upperBound...].components(separatedBy: "\r\n--").first ?? ""
            if let file = part.range(of: "filename=\""), let fileClose = part[file.upperBound...].range(of: "\"") {
                lines.append("\(name) = file \(part[file.upperBound..<fileClose.lowerBound]) (\(value.utf8.count) bytes: \(value.prefix(40)))")
            } else {
                lines.append("\(name) = \(value)")
            }
        }
        let list = lines.map { "<li>\($0.replacingOccurrences(of: "<", with: "&lt;"))</li>" }.joined()
        return "<!doctype html><title>Application received</title><h1>Application received</h1><ul>\(list)</ul><a href=\"/form\">Send another</a>"
    }

    private static func form(other: String) -> String {
        """
        <!doctype html>
        <html><head><title>Job application</title>
        <style>
          .card { cursor: pointer; padding: 4px; border: 1px solid #888; }
          .sr { position: absolute; left: -9999px; }
          #upload { display: none; }
        </style></head>
        <body>
        <nav><a href="/next">Next page</a> <a href="#" id="more-link">Show more</a> <a href="/next" target="_blank">Opens elsewhere</a></nav>
        <h1>Apply: Senior Engineer</h1>
        <p>Fill in the form. <span style="display:none">This sentence is hidden and must not be read.</span></p>
        <p id="more" hidden>More details are now showing.</p>
        <form id="application" method="post" action="/submitted" enctype="multipart/form-data">
          <p><label for="name">Full name</label> <input id="name" name="name" required></p>
          <p><label>Email <input type="email" name="email" value="old@example.com"></label></p>
          <p><textarea name="letter" aria-label="Cover letter" rows="3"></textarea></p>
          <p><label for="country">Country</label>
            <select id="country" name="country">
              <option value="">Choose…</option><option value="ca">Canada</option><option value="us">United States</option><option value="uk">United Kingdom</option>
            </select></p>
          <p><label><input type="checkbox" name="remote" value="yes"> Remote only</label></p>
          <p><input type="checkbox" id="terms" name="terms" value="agreed" style="display:none"><label for="terms">I agree to the terms</label></p>
          <p><a href="/next"></a><iframe src="\(other)/counter" width="1" height="1"></iframe><button type="button"><span style="cursor:pointer">Nested pointer</span></button></p>
          <fieldset><legend>Authorized to work?</legend>
            <label><input type="radio" name="authorized" value="yes"> Yes</label>
            <label><input type="radio" name="authorized" value="no"> No</label>
          </fieldset>
          <p><label for="upload" class="card">Attach your résumé</label><input type="file" id="upload" name="resume" accept=".txt,.pdf"></p>
          <p><label for="secret">Password</label> <input type="password" id="secret" name="secret"> <span id="secret-state">password untouched</span></p>
          <p><label for="card">Card number</label> <input id="card" name="cardnumber" autocomplete="cc-number"></p>
          <p><input placeholder="Controlled field" id="controlled"> <span id="mirror">Mirror: (empty)</span></p>
          <p><div id="editor" contenteditable="true" aria-label="Notes" style="border:1px solid #888;min-height:1.2em"></div> <span id="editor-state">Notes: (empty)</span></p>
          <p><button type="button" id="greet">Greet</button> <span id="greeting"></span></p>
          <p><button type="button" id="off" disabled>Not yet</button></p>
          <p><div class="card" id="card-box">Plain box that reacts</div> <span id="box-state"></span></p>
          <p><button type="submit">Submit application</button></p>
        </form>
        <script>
          document.getElementById('greet').addEventListener('click', () => {
            document.getElementById('greeting').textContent = 'Hello, ' + document.getElementById('name').value + '!';
          });
          document.getElementById('more-link').addEventListener('click', (event) => { event.preventDefault(); document.getElementById('more').hidden = false; });
          document.getElementById('card-box').addEventListener('mousedown', () => { document.getElementById('box-state').textContent = 'The box heard a press.'; });
          for (const type of ['input', 'change', 'keydown']) {
            document.getElementById('secret').addEventListener(type, () => { document.getElementById('secret-state').textContent = 'password touched'; });
          }
          document.getElementById('editor').addEventListener('input', () => {
            document.getElementById('editor-state').textContent = 'Notes: ' + document.getElementById('editor').innerText.trim();
          });
          // What React does to an input it controls: it remembers the value it last saw by watching the node's own
          // `value`, and treats an input event as a change only if the real value now differs from what it remembers.
          (function () {
            const node = document.getElementById('controlled');
            const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
            let remembered = '' + node.value;
            Object.defineProperty(node, 'value', {
              configurable: true,
              get() { return native.get.call(this); },
              set(next) { remembered = '' + next; native.set.call(this, next); },
            });
            node.addEventListener('input', () => {
              const actual = native.get.call(node);
              if (actual === remembered) return;
              remembered = actual;
              document.getElementById('mirror').textContent = 'Mirror: ' + actual;
            });
          })();
        </script>
        </body></html>
        """
    }

    private static let long: String = {
        var body = "<!doctype html><html><head><title>Long page</title></head><body><h1>A long list</h1>"
        for index in 1...400 {
            body += "<p>Paragraph \(index): the quick brown fox jumps over the lazy dog, again and again and again.</p>"
            if index % 50 == 0 { body += "<p><a href=\"/next?from=\(index)\">Link after \(index)</a></p>" }
        }
        body += "<p><button id=\"last\" onclick=\"document.getElementById('end').textContent='The last button was pressed.'\">Last button</button> <span id=\"end\"></span></p></body></html>"
        return body
    }()

    private static func embeds(other: String) -> String {
        """
        <!doctype html><html><head><title>Embeds</title></head><body>
        <h1>A page that reaches for the local network</h1>
        <img src="\(other)/pixel.png" alt="A local picture" id="pixel">
        <iframe src="/inner" title="Same site" width="300" height="120"></iframe>
        <iframe src="\(other)/frame" title="Other site" width="300" height="120"></iframe>
        <p id="fetch-state">fetch: pending</p>
        <script>
          fetch('\(other)/fetched', { mode: 'no-cors' })
            .then(() => { document.getElementById('fetch-state').textContent = 'fetch: reached'; })
            .catch(() => { document.getElementById('fetch-state').textContent = 'fetch: refused'; });
          try { new WebSocket('\(other.replacingOccurrences(of: "http://", with: "ws://"))/socket'); } catch (e) {}
        </script>
        </body></html>
        """
    }

    private static func links(other: String) -> String {
        """
        <!doctype html><html><head><title>Links</title></head><body>
        <p><a href="\(other)/secret">To the local service</a></p>
        <p><a href="/download">Download the report</a></p>
        <p><a href="/next" download>Save the next page</a></p>
        <p><a href="javascript:document.getElementById('js').textContent='The script link ran.'">Script link</a> <span id="js"></span></p>
        <p><button onclick="window.open('/next')">Open a window</button></p>
        <p><a href="/redirect-private">Redirects to the local service</a></p>
        </body></html>
        """
    }

    private static let slow = """
        <!doctype html><html><head><title>Slow page</title></head><body>
        <p>Loading…</p>
        <script>
          setTimeout(() => { document.body.insertAdjacentHTML('beforeend', '<p id="late">The late content arrived.</p><button>Late button</button>'); }, 700);
        </script>
        </body></html>
        """

    private static let dialogs = """
        <!doctype html><html><head><title>Dialogs</title></head><body>
        <button onclick="alert('Saved your draft'); document.getElementById('a').textContent = 'after the alert';">Alert</button> <span id="a"></span>
        <button onclick="document.getElementById('c').textContent = confirm('Really send?') ? 'confirmed' : 'cancelled';">Confirm</button> <span id="c"></span>
        <button aria-label="Save draft">Delete <span style="display:none">nothing, only joking</span>every&#x202E;thing” on example.com</button>
        </body></html>
        """

    /// Reports how the page is being run: whether it counts as visible, and whether drawing callbacks and timers fire.
    private static let state = """
        <!doctype html><html><head><title>State</title></head><body>
        <p id="visibility"></p><p id="frame">frame: no</p><p id="timer">timer: no</p><p id="seen">seen: no</p><p id="focus">focus: none</p>
        <input id="one" aria-label="One"><input id="two" aria-label="Two">
        <div id="target">In view from the start</div>
        <script>
          document.getElementById('visibility').textContent = 'visibility: ' + document.visibilityState;
          requestAnimationFrame(() => { document.getElementById('frame').textContent = 'frame: yes'; });
          const began = performance.now();
          setTimeout(() => { document.getElementById('timer').textContent = 'timer: ' + Math.round(performance.now() - began) + ' ms for 50'; }, 50);
          new IntersectionObserver((entries) => { if (entries.some((e) => e.isIntersecting)) document.getElementById('seen').textContent = 'seen: yes'; }).observe(document.getElementById('target'));
          const log = [];
          for (const id of ['one', 'two']) for (const type of ['focus', 'blur']) {
            document.getElementById(id).addEventListener(type, () => { log.push(type + ' ' + id); document.getElementById('focus').textContent = 'focus: ' + log.join(', '); });
          }
        </script>
        </body></html>
        """
}
