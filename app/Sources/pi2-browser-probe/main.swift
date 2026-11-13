// Checks BrowserKit, the part of pi²'s browser that loads pages, reads them and acts in them.
//
//   pi2-browser-probe [--out <folder>] [--show]
//   pi2-browser-probe --engine <socket>
//
// It serves a handful of pages to itself on this Mac, drives them through BrowserKit the way the engine would, and
// says what held and what did not. It loads no real website. Its web views are never shown, it keeps no profile
// (cookies live only as long as the run), and it leaves the app's own browser profile alone. `--out` saves the
// screenshot it takes; `--show` prints each page as an agent would be given it.
//
// With `--engine` it runs no checks of its own. It stands in for the app on a running engine's socket instead, as that
// engine's browser, so the two halves can be tried together; `engine/test/browser.ts` does that. A line
// "open <conversation> <path>" on standard input puts one of the fixture pages in front of a conversation, as a
// person would in the Browser window (the engine itself refuses to open an address on this Mac, fixtures included).
// This is not part of the app and is not copied into it.

import AppKit
import BrowserKit
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
let out = take("--out").map { URL(fileURLWithPath: $0, isDirectory: true) }
let engineSocket = take("--engine")
let show = arguments.contains("--show")
setlinebuf(stdout)
if let out { try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }

// Web views need an application to belong to, though this one never puts a window on screen.
NSApplication.shared.setActivationPolicy(.accessory)

var failures = 0
func check(_ name: String, _ holds: Bool, _ detail: @autoclosure () -> String = "") {
    if holds {
        print("ok    \(name)")
    } else {
        failures += 1
        let more = detail()
        print("FAIL  \(name)" + (more.isEmpty ? "" : "\n" + more.split(separator: "\n", omittingEmptySubsequences: false).map { "      \($0)" }.joined(separator: "\n")))
    }
}

/// The number the newest view gave the element whose line holds `words`.
func element(_ words: String, in text: String) -> Int {
    for line in text.split(separator: "\n") where line.hasPrefix("[") && line.contains(words) {
        if let close = line.firstIndex(of: "]"), let number = Int(line[line.index(after: line.startIndex)..<close]) { return number }
    }
    return 0
}

func line(_ words: String, in text: String) -> String {
    text.split(separator: "\n").first { $0.hasPrefix("[") && $0.contains(words) }.map(String.init) ?? ""
}

// A second server stands in for something private on this Mac. Nothing may ever reach it.
let other = try FixtureServer { _ in .html("<!doctype html><title>Private</title><p>You should never see this.</p>") }
try await other.start()
let otherOrigin = other.origin
let server = try FixtureServer { request in Fixtures.respond(to: request, other: otherOrigin) }
try await server.start()
let site = server.origin

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pi2-browser-probe-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

// The fixture server is the one local address let through, and only on its own port.
let policy = BrowserPolicy(fixtureOrigins: ["127.0.0.1:\(server.port)"])
let browser = BrowserController(profile: .ephemeral, policy: policy, rulesFolder: scratch.appendingPathComponent("rules", isDirectory: true))

if let engineSocket {
    // Whoever started this stops it with a signal, or by stopping the engine; leave nothing behind then either.
    let leave: () -> Void = {
        try? FileManager.default.removeItem(at: scratch)
        exit(0)
    }
    signal(SIGTERM, SIG_IGN)
    let stopped = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    stopped.setEventHandler(handler: leave)
    stopped.resume()
    let link = EngineLink(socket: engineSocket, browser: browser)
    link.closed = leave
    try await link.start()
    print("ready \(site)")
    for try await line in FileHandle.standardInput.bytes.lines {
        let words = line.split(separator: " ")
        guard words.count == 3, words[0] == "open", let conversation = Int(words[1]) else { continue }
        _ = await browser.go(site + words[2], in: conversation)
        for _ in 0..<60 where browser.page(conversation)?.hasDocument != true || browser.page(conversation)?.isLoading != false {
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("opened \(conversation)")
    }
    try? FileManager.default.removeItem(at: scratch)
    exit(0)
}

var steps = 0
@MainActor
func ask(_ request: BrowserRequest) async -> BrowserReply {
    let reply = await browser.perform(request)
    steps += 1
    if show {
        print("--- \(steps): \(request.action)\(request.of.map { " of \($0)" } ?? "") → \(reply.ok ? "ok" : "refused")\(reply.summary.map { " [\($0)]" } ?? "")")
        print(reply.text)
    }
    return reply
}
@MainActor func open(_ path: String, in conversation: Int = 1) async -> BrowserReply { await ask(BrowserRequest(action: "open", url: path.contains("://") || path.contains(":") ? path : site + path, conversationId: conversation)) }
@MainActor func read(offset: Int? = nil, in conversation: Int = 1) async -> BrowserReply { await ask(BrowserRequest(action: "read", offset: offset, conversationId: conversation)) }
@MainActor func click(_ number: Int, expect: String? = nil) async -> BrowserReply { await ask(BrowserRequest(action: "click", element: number, expect: expect, conversationId: 1)) }
@MainActor func describe(_ action: String, _ number: Int, text: String? = nil, option: String? = nil, path: String? = nil, submit: Bool = false) async -> BrowserReply {
    await ask(BrowserRequest(action: "describe", of: action, element: number, text: text, submit: submit, option: option, path: path, conversationId: 1))
}

// ---- The rules about addresses, on their own

let strict = BrowserPolicy()
let neverOpened = [
    "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "about:blank", "ftp://example.com/x", "https://user:pw@example.com/",
    "http://localhost:3000/", "http://app.localhost/", "http://127.0.0.1/", "http://127.1/", "http://2130706433/", "http://0x7f.0.0.1/", "http://10.1.2.3/",
    "http://172.16.0.1/", "http://172.31.255.255/", "http://192.168.1.1/admin", "http://169.254.169.254/latest/", "http://0.0.0.0:8000/", "http://100.64.0.1/",
    "http://[::1]:8080/", "http://[fd12:3456::1]/", "http://[fe80::1]/", "http://[::ffff:192.168.0.1]/", "http://printer.local/", "http://router/",
]
let wronglyOpened = neverOpened.filter { URL(string: $0).map { strict.check($0) == .allowed } ?? false }
check("addresses on this Mac and the local network, and anything that is not http(s), are refused", wronglyOpened.isEmpty, "let through: \(wronglyOpened)")
let publicAddresses = ["https://example.com/jobs?q=1", "http://172.32.0.1/", "http://11.0.0.1/", "https://[2606:4700::1111]/", "https://local.example.com/"]
let wronglyRefused = publicAddresses.filter { URL(string: $0).map { strict.check($0) != .allowed } ?? true }
check("public addresses pass", wronglyRefused.isEmpty, "refused: \(wronglyRefused)")
check("a name that stands for this Mac is caught when it is looked up", BrowserPolicy.resolvesToPrivate("localhost"))
check("only the fixture server's own port is let through here", policy.check(URL(string: site + "/form")!) == .allowed && policy.check(URL(string: otherOrigin + "/")!) != .allowed)

// ---- Before any page

let early = await click(1)
check("with no page open, an action says so", !early.ok && early.text.contains("No page is open"), early.text)

// ---- Reading a page

var page = await open("/form")
check("a page opens and comes back as text", page.ok && page.text.contains("Page: Job application") && page.text.contains("Address: \(site)/form"), page.text)
check("its summary names the site", page.summary == "Opened 127.0.0.1", page.summary ?? "none")
let expected = [
    "link “Next page” → /next", "link “Show more”", "text field “Full name”, empty, required", "email field “Email”, holds “old@example.com”",
    "text area “Cover letter”, empty", "drop-down list “Country”, set to “Choose…”. Choices: Choose… | Canada | United States | United Kingdom",
    "checkbox “Remote only”, not checked", "radio button “Yes” in “Authorized to work?”, not chosen", "radio button “No” in “Authorized to work?”, not chosen",
    "file input “Attach your résumé”, no file chosen (takes .txt,.pdf)", "password field “Password” (the person fills this in themselves)",
    "text field “Controlled field”, empty", "text box “Notes”, empty", "button “Greet”", "button “Not yet”, disabled", "clickable “Plain box that reacts”",
    "button “Submit application”",
]
let missing = expected.filter { words in !page.text.split(separator: "\n").contains { $0.hasPrefix("[") && $0.hasSuffix(words) } }
check("links, buttons, fields, checkboxes, lists and file inputs are listed with their labels and values", missing.isEmpty, "missing: \(missing)\n\(page.text)")
check("a link that only runs a script is not shown as leading anywhere", line("“Show more”", in: page.text).hasSuffix("link “Show more”"))
check("a checkbox the page hides behind its label is listed by that label", line("“I agree to the terms”", in: page.text).hasSuffix("checkbox “I agree to the terms”, not checked"), page.text)
check(
    "an empty link, a one-dot frame and a pointer inside a button are not listed as things of their own",
    !page.text.contains("(no name)") && !page.text.contains("] frame") && !page.text.contains("clickable “Nested pointer”") && page.text.contains("button “Nested pointer”"),
    page.text
)
check("headings and text are readable, and each element is marked where it sits", page.text.contains("# Apply: Senior Engineer") && page.text.contains("[\(element("“Full name”", in: page.text))]"), page.text)
check("hidden text is left out", !page.text.contains("must not be read") && !page.text.contains("More details are now showing"))
check("a page with a password field says the person signs in", page.text.contains("ask the person to sign in themselves"))

// ---- Describing, for approval

let nameField = element("“Full name”", in: page.text)
let emailField = element("“Email”", in: page.text)
var said = await describe("click", element("“Next page”", in: page.text))
check("a plain link is described as a link, and as only navigating", said.ok && said.navigates && said.text == "Follow the link “Next page” to \(site)/next" && said.host == "127.0.0.1", said.text)
said = await describe("click", element("“Greet”", in: page.text))
check("a button is described by its name and the site, and is not only navigating", said.ok && !said.navigates && said.text == "Click “Greet” on 127.0.0.1", said.text)
said = await describe("click", element("“Show more”", in: page.text))
check("a link that runs a script counts as a button", said.ok && !said.navigates && said.text == "Click “Show more” on 127.0.0.1", said.text)
said = await describe("type", emailField, text: "ada@example.com", submit: true)
check("typing is described with the text and the field", said.text == "Type “ada@example.com” into the “Email” field on 127.0.0.1, then press Return", said.text)
said = await describe("click", element("“Remote only”", in: page.text))
check("a checkbox is described by what clicking would do", said.text == "Check “Remote only” on 127.0.0.1", said.text)
said = await describe("select", element("“Country”", in: page.text), option: "canada")
check("a choice is described as the page words it", said.text == "Choose “Canada” in “Country” on 127.0.0.1", said.text)
said = await describe("click", 999)
check("an element that is not there cannot be described", !said.ok && said.text.contains("no element 999"), said.text)
said = await describe("click", element("“Not yet”", in: page.text))
check("a disabled button is refused", !said.ok && said.text.contains("disabled"), said.text)

// ---- Typing

page = await ask(BrowserRequest(action: "type", element: nameField, text: "Ada Lovelace", conversationId: 1))
check("typing puts text into a field", page.ok && page.text.hasPrefix("Typed “Ada Lovelace” into “Full name”.") && line("“Full name”", in: page.text).contains("holds “Ada Lovelace”"), page.text)
check("text that did not change is not sent again", page.text.contains("the same as in your last view"), page.text)
page = await ask(BrowserRequest(action: "type", element: emailField, text: "ada@example.com", conversationId: 1))
check("typing replaces what a field held", line("“Email”", in: page.text).contains("holds “ada@example.com”"), line("“Email”", in: page.text))
page = await ask(BrowserRequest(action: "type", element: element("“Controlled field”", in: page.text), text: "hello", conversationId: 1))
check("a field controlled the way React does it notices the typing", page.text.contains("Mirror: hello"), page.text)
page = await ask(BrowserRequest(action: "type", element: element("“Notes”", in: page.text), text: "Available from March", conversationId: 1))
check("a text box the page draws itself takes typing", page.text.contains("Notes: Available from March"), page.text)
page = await ask(BrowserRequest(action: "type", element: element("“Cover letter”", in: page.text), text: "Dear team,\nI would like to apply.", conversationId: 1))
check("a text area takes several lines", line("“Cover letter”", in: page.text).contains("holds “Dear team, I would like to apply.”"), line("“Cover letter”", in: page.text))

// ---- Passwords and payment details

let passwordField = element("“Password”", in: page.text)
said = await describe("type", passwordField, text: "hunter2")
check("a password field is refused when described", !said.ok && said.text.contains("does not type passwords"), said.text)
page = await ask(BrowserRequest(action: "type", element: passwordField, text: "hunter2", conversationId: 1))
check("a password field is refused when typed into", !page.ok && page.text.contains("does not type passwords"), page.text)
page = await ask(BrowserRequest(action: "type", element: element("“Card number”", in: (await read()).text), text: "4242424242424242", conversationId: 1))
check("a payment card field is refused", !page.ok && page.text.contains("does not enter payment details"), page.text)
page = await read()
check("neither was touched", page.text.contains("password untouched") && line("“Card number”", in: page.text).contains("empty"), page.text)

// ---- Choosing, checking, clicking

page = await ask(BrowserRequest(action: "select", element: element("“Country”", in: page.text), option: "Canada", conversationId: 1))
check("a choice is picked in a drop-down list", page.ok && line("“Country”", in: page.text).contains("set to “Canada”"), page.text)
let wrongChoice = await ask(BrowserRequest(action: "select", element: element("“Country”", in: page.text), option: "Atlantis", conversationId: 1))
check("a choice that is not offered is refused, with what is", !wrongChoice.ok && wrongChoice.text.contains("United Kingdom"), wrongChoice.text)
let notAList = await ask(BrowserRequest(action: "select", element: element("“Greet”", in: page.text), option: "x", conversationId: 1))
check("select on something that is not a list says what to do instead", !notAList.ok && notAList.text.contains("not a drop-down list"), notAList.text)
page = await click(element("“Remote only”", in: page.text))
check("a checkbox is checked", page.text.hasPrefix("Checked “Remote only”.") && line("“Remote only”", in: page.text).hasSuffix(", checked"), page.text)
said = await describe("click", element("“Remote only”", in: page.text))
check("and is then described as unchecking", said.text == "Uncheck “Remote only” on 127.0.0.1", said.text)
page = await click(element("“I agree to the terms”", in: page.text))
check("a hidden checkbox is checked through its label", line("“I agree to the terms”", in: page.text).hasSuffix(", checked"), page.text)
page = await click(element("radio button “Yes”", in: page.text))
check("a radio button is chosen", line("radio button “Yes”", in: page.text).hasSuffix(", chosen") && line("radio button “No”", in: page.text).hasSuffix(", not chosen"), page.text)
page = await click(element("“Greet”", in: page.text))
check("a button that changes the page is clicked, and the page comes back changed", page.ok && page.text.contains("Hello, Ada Lovelace!"), page.text)
page = await click(element("“Show more”", in: page.text))
check("a link that runs a script is clicked as a button", page.text.contains("More details are now showing."), page.text)
page = await click(element("“Plain box that reacts”", in: page.text))
check("a plain box with a pointer is listed and hears the press", page.text.contains("The box heard a press."), page.text)
let greet = element("“Greet”", in: page.text)
let stale = await click(greet, expect: "Click “Something else” on 127.0.0.1")
check("an action that no longer matches what was approved is not done", !stale.ok && stale.text.contains("changed after this action was described"), stale.text)
let selectClick = await click(element("“Country”", in: page.text))
check("clicking a drop-down list says to use select", !selectClick.ok && selectClick.text.contains("Use select"), selectClick.text)

// ---- Uploading

let resume = scratch.appendingPathComponent("resume.txt")
try Data("Ada Lovelace, analyst and metaphysician.".utf8).write(to: resume)
let fileInput = element("file input", in: page.text)
said = await describe("upload", fileInput, path: resume.path)
check("an upload is described with the file and the input", said.ok && said.text.hasPrefix("Upload ") && said.text.hasSuffix("resume.txt to “Attach your résumé” on 127.0.0.1"), said.text)
page = await ask(BrowserRequest(action: "upload", element: fileInput, path: resume.path, conversationId: 1))
check("a file is chosen in a file input, even one the page hides", page.ok && page.text.hasPrefix("Chose resume.txt") && line("file input", in: page.text).contains("holds resume.txt"), page.text)
let noFile = await ask(BrowserRequest(action: "upload", element: fileInput, path: scratch.appendingPathComponent("missing.txt").path, conversationId: 1))
check("a file that is not there is refused", !noFile.ok, noFile.text)
let notAnInput = await ask(BrowserRequest(action: "upload", element: greet, path: resume.path, conversationId: 1))
check("upload on something that is not a file input is refused", !notAnInput.ok && notAnInput.text.contains("not a file input"), notAnInput.text)

// ---- Sending the form

page = await click(element("“Submit application”", in: page.text))
check(
    "the form is sent with what was typed, chosen and uploaded",
    page.text.contains("Page: Application received") && page.text.contains("name = Ada Lovelace") && page.text.contains("email = ada@example.com")
        && page.text.contains("country = ca") && page.text.contains("remote = yes") && page.text.contains("terms = agreed") && page.text.contains("authorized = yes")
        && page.text.contains("resume = file resume.txt (40 bytes: Ada Lovelace, analyst and metaphysician.)"),
    page.text
)
check("the password was never sent", page.text.contains("secret =") && !page.text.contains("hunter2"), page.text)

// ---- Links and going back

page = await open("/form")
page = await ask(BrowserRequest(action: "type", element: element("“Full name”", in: page.text), text: "Grace", submit: true, conversationId: 1))
check("Return in a field sends its form", page.text.contains("Page: Application received") && page.text.contains("name = Grace"), page.text)
page = await open("/form")
let nextLink = element("“Next page”", in: page.text)
page = await click(nextLink, expect: "Follow the link “Next page” to \(site)/next")
check("a plain link is followed", page.ok && page.text.hasPrefix("Followed the link “Next page”.") && page.text.contains("Address: \(site)/next") && page.text.contains("You followed the link"), page.text)
page = await ask(BrowserRequest(action: "back", conversationId: 1))
check("back returns to the page before", page.ok && page.text.hasPrefix("Went back.") && page.text.contains("Address: \(site)/form"), page.text)
// The person goes somewhere else by hand: the numbers the agent holds are for a page that is gone.
_ = await browser.go("\(site)/next", in: 1)
for _ in 0..<40 where browser.page(1)?.title != "Next page" { try? await Task.sleep(for: .milliseconds(100)) }
let old = await click(element("“Greet”", in: page.text))
check("a number from a page that has since been left does not work", !old.ok && old.text.contains("changed since your last view"), old.text)
page = await open("/form")
page = await click(element("“Opens elsewhere”", in: page.text))
check("a link meant for a new window opens in the same page", page.text.contains("Address: \(site)/next"), page.text)

// ---- A long page

page = await open("/long")
let heading = page.text.split(separator: "\n").first { $0.hasPrefix("Text, characters ") }.map(String.init) ?? ""
let total = heading.components(separatedBy: " of ").last.flatMap { Int($0.prefix { $0.isNumber }) } ?? 0
check("a long page comes in parts", page.text.contains("Text, characters 1 to ") && page.text.contains("read with offset") && total > 30000 && page.text.contains("Paragraph 1:") && !page.text.contains("Paragraph 400:"), String(page.text.prefix(600)))
check("only the elements of the part shown are listed", page.text.contains("link “Link after 50”") && !page.text.contains("“Last button”") && page.text.contains("more in other parts of the page"), String(page.text.prefix(600)))
let nextOffset = page.text.components(separatedBy: "read with offset ").dropFirst().first.flatMap { Int($0.prefix { $0.isNumber }) } ?? 0
let second = await read(offset: nextOffset)
let firstPart = page.text.components(separatedBy: "Paragraph ").count, secondPart = second.text.components(separatedBy: "Paragraph ").count
let lastOfFirst = page.text.components(separatedBy: "Paragraph ").last.flatMap { Int($0.prefix { $0.isNumber }) } ?? 0
check(
    "read with an offset shows the next part, with nothing lost between the two",
    second.ok && nextOffset > 6000 && firstPart > 50 && secondPart > 50 && second.text.contains("\nParagraph \(lastOfFirst + 1):") && !second.text.contains("Paragraph \(lastOfFirst):"),
    String(second.text.prefix(600))
)
let ending = await read(offset: total - 2000)
let lastButton = element("“Last button”", in: ending.text)
check("the end of the page lists what is there", lastButton > 0 && ending.text.contains("Paragraph 400:"), String(ending.text.prefix(600)))
page = await click(lastButton)
check("an element far down the page is clicked, and its part of the page comes back", page.ok && page.text.contains("The last button was pressed."), String(page.text.prefix(600)))
page = await ask(BrowserRequest(action: "scroll", dy: -2, conversationId: 1))
check("scrolling up from the end shows the text there", page.ok && page.text.hasPrefix("Scrolled up 2 pages.") && !page.text.contains("Paragraph 1:") && page.text.contains("Paragraph 380:"), String(page.text.prefix(600)))
page = await open("/long")
page = await ask(BrowserRequest(action: "scroll", dy: -1, conversationId: 1))
check("scrolling up at the top says so", page.ok && page.text.hasPrefix("The page did not scroll: this is its top."), String(page.text.prefix(200)))
page = await ask(BrowserRequest(action: "scroll", dy: 5, conversationId: 1))
check("scrolling down moves to the text there", page.ok && page.text.hasPrefix("Scrolled down 5 pages.") && !page.text.contains("Paragraph 1:") && page.text.contains("Text, characters "), String(page.text.prefix(600)))

// ---- What is never loaded

let before = other.requests.count
for address in ["\(otherOrigin)/secret", "http://localhost:\(server.port)/form", "http://192.168.1.1/", "file:///etc/hosts", "javascript:alert(1)", "data:text/html,<p>hi"] {
    let refused = await open(address)
    check("\(address.prefix(40)) is not opened", !refused.ok, refused.text)
}
let redirected = await open("/redirect-private")
check("a redirect to a private address is not followed", !redirected.ok && redirected.text.contains("was not opened"), redirected.text)
page = await open("/embeds")
try? await Task.sleep(for: .milliseconds(600))
page = await read()
check("a frame from the same site is read in place, and its button can be used", page.text.contains("Text inside the frame.") && element("“Inner button”", in: page.text) > 0, page.text)
check("a frame from elsewhere is listed with its address", line("frame “Other site”", in: page.text).contains("\(otherOrigin)/frame"), page.text)
check("a page's own fetch of a private address is refused", page.text.contains("fetch: refused"), page.text)
let frameClick = await click(element("frame “Other site”", in: page.text))
check("opening a frame that points at a private address is refused", !frameClick.ok && frameClick.text.contains("was not opened"), frameClick.text)
page = await click(element("“Inner button”", in: page.text))
check("a button inside a same-site frame is clicked", page.text.contains("Pressed inside"), page.text)
page = await open("/links")
let privateLink = await click(element("“To the local service”", in: page.text))
check("a link to a private address is not followed", !privateLink.ok && privateLink.text.contains("was not opened"), privateLink.text)
let viaRedirect = await click(element("“Redirects to the local service”", in: page.text))
check("nor is a link that redirects to one", !viaRedirect.ok && viaRedirect.text.contains("was not opened"), viaRedirect.text)
check("nothing reached the private server: no page, picture, frame, fetch, socket or redirect", other.requests.count == before, "it was asked for: \(other.requests.dropFirst(before).map(\.path))")

// ---- Downloads

page = await open("/links")
let download = await click(element("“Download the report”", in: page.text))
check("a link to a file says plainly that nothing is downloaded", !download.ok && download.text.contains("does not download files"), download.text)
let direct = await open("/download")
check("so does opening a file's address", !direct.ok && direct.text.contains("report.bin") && direct.text.contains("does not download files"), direct.text)
page = await read()
let saveLink = element("“Save the next page”", in: page.text)
said = await describe("click", saveLink)
check("a link marked for download is not treated as a plain link", said.ok && !said.navigates, said.text)
page = await click(saveLink)
check("and clicking it downloads nothing, and says so", page.text.contains("does not download files") && page.text.contains("Address: \(site)/links"), page.text)

// ---- Scripts, windows and dialogs

page = await click(element("“Script link”", in: page.text))
check("a link that is a script runs when clicked", page.text.contains("The script link ran."), page.text)
page = await click(element("“Open a window”", in: page.text))
check("a page that opens a window gets the same page instead", page.text.contains("Address: \(site)/next"), page.text)
page = await open("/dialogs")
page = await click(element("“Alert”", in: page.text))
check("a message the page puts up is passed on, and the page carries on", page.text.contains("The page showed a message: “Saved your draft”") && page.text.contains("after the alert"), page.text)
page = await click(element("“Confirm”", in: page.text))
check("a question the page asks after an approved click is answered and reported", page.text.contains("The page asked “Really send?”") && page.text.contains("confirmed"), page.text)
said = await describe("click", element("Delete", in: page.text))
check(
    "a button is described by the words on it, not by a hidden name, hidden text, or marks that pass for the app's own",
    said.text == "Click “Delete everything\" on example.com” on 127.0.0.1", said.text
)
page = await open("/slow")
check("content that arrives a moment after the page loads is waited for", page.text.contains("The late content arrived.") && element("“Late button”", in: page.text) > 0, page.text)

// ---- A picture

page = await open("/form")
let shot = await ask(BrowserRequest(action: "screenshot", conversationId: 1))
var pictureDetail = "no picture"
var pictureHolds = false
if let jpeg = shot.jpeg, let image = NSBitmapImageRep(data: jpeg) {
    // A real picture of the form has both light and dark in it; a blank one does not.
    var darkest = 1.0, lightest = 0.0
    for x in stride(from: 0, to: image.pixelsWide, by: max(1, image.pixelsWide / 60)) {
        for y in stride(from: 0, to: image.pixelsHigh, by: max(1, image.pixelsHigh / 60)) {
            let level = Double(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0)
            darkest = min(darkest, level)
            lightest = max(lightest, level)
        }
    }
    pictureDetail = "\(image.pixelsWide)×\(image.pixelsHigh), \(jpeg.count / 1024) KB, brightness \(String(format: "%.2f", darkest)) to \(String(format: "%.2f", lightest))"
    pictureHolds = image.pixelsWide >= 320 && lightest - darkest > 0.3
    if let out {
        try? jpeg.write(to: out.appendingPathComponent("form.jpg"))
        pictureDetail += ", saved to \(out.appendingPathComponent("form.jpg").path)"
    }
}
check("a screenshot is a picture of the page (\(pictureDetail))", shot.ok && pictureHolds, shot.text)

// ---- One page per conversation, one profile for all

_ = await open("/set-cookie", in: 1)
let elsewhere = await open("/cookie", in: 2)
check("conversations share the browser's cookies", elsewhere.text.contains("probe=remembered"), elsewhere.text)
let first = await read(in: 1)
check("but each has its own page", first.text.contains("Cookie set.") && browser.pages.count == 2, first.text)
let agent = server.requests.last?.headers["user-agent"] ?? ""
check("sites are told this is Safari", agent.contains("Safari/") && agent.contains("Version/") && agent.contains("Macintosh"), agent)

// ---- What the person does in the window

let typedLocal = await browser.go("localhost:1234", in: 3)
check("the address field refuses private addresses too", typedLocal?.contains("off limits") == true, typedLocal ?? "allowed")
_ = await browser.go("\(site)/next", in: 3)
for _ in 0..<40 where browser.page(3)?.title != "Next page" { try? await Task.sleep(for: .milliseconds(100)) }
check("the address field opens a page, and the window is told its title and address", browser.page(3)?.title == "Next page" && browser.page(3)?.address?.path == "/next", browser.page(3)?.title ?? "no page")
browser.close(3)
check("a page can be closed", browser.page(3) == nil && browser.pages.count == 2)

// The Browser window shows a page by taking its web view in, and gives it back when it shows another or closes.
// This pane is in no window, so nothing appears; what is checked is that the views go where they should.
let pane = BrowserPaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
browser.show(1, in: pane)
let shown = browser.page(1)?.webView
check("a page is put into the window's pane and fills it", shown?.superview === pane && shown?.frame.size == pane.bounds.size)
pane.setFrameSize(NSSize(width: 700, height: 500))
check("and follows the pane's size", shown?.frame.size == NSSize(width: 700, height: 500), "\(shown?.frame.size ?? .zero)")
browser.show(2, in: pane)
check("showing another page puts the first back where agents work it", shown?.superview !== pane && shown?.window != nil && browser.page(2)?.webView.superview === pane && pane.subviews.count == 1)
browser.show(nil, in: pane)
check("closing the window gives the page back", pane.subviews.isEmpty && browser.page(2)?.webView.window != nil)
let afterShowing = await read(in: 1)
check("a page that was shown and put back still works", afterShowing.ok && afterShowing.text.contains("Cookie set."), afterShowing.text)
browser.keepOnly([1])
check("the page of a conversation that is gone is closed", browser.page(2) == nil && browser.page(1) != nil)
for id in 10..<22 { _ = await browser.openPage(id) }
check("pages not used for longest are closed when there are many", browser.pages.count <= 8 && browser.page(21) != nil, "\(browser.pages.count) pages")
for id in 10..<22 { browser.close(id) }
if browser.page(1) == nil { _ = await open("/next") }

// ---- How a page that is not on screen is run (for information)

let state = await open("/state")
try? await Task.sleep(for: .milliseconds(700))
var running = await read()
let one = element("“One”", in: running.text), two = element("“Two”", in: running.text)
_ = await ask(BrowserRequest(action: "type", element: one, text: "a", conversationId: 1))
running = await ask(BrowserRequest(action: "type", element: two, text: "b", conversationId: 1))
let facts = running.text.split(separator: "\n").filter { $0.hasPrefix("visibility:") || $0.hasPrefix("frame:") || $0.hasPrefix("timer:") || $0.hasPrefix("seen:") || $0.hasPrefix("focus:") }
print("info  a page that is not on screen: \(facts.joined(separator: "; "))")
check("a page that is not on screen still runs its timers", state.ok && running.text.contains("timer: ") && !running.text.contains("timer: no"), running.text)

check("in the whole run, the private server was never asked for anything", other.requests.isEmpty, "it was asked for: \(other.requests.map(\.path))")

server.stop()
other.stop()
try? FileManager.default.removeItem(at: scratch)
print(failures == 0 ? "PASS  \(steps) actions against local pages" : "FAILED  \(failures) check\(failures == 1 ? "" : "s") did not hold")
exit(failures == 0 ? 0 : 1)
