// Checks TranscriptKit's PresentedPageView, the sandboxed view an agent's page is drawn in (#964,
// docs/design/presenting.md, "A page an agent wrote is untrusted"), against hostile pages it writes into a temporary
// folder: one for each claim of "For the security read when it is built", each proving it by what the page could and
// could not do. The view is fed from the folder by a stand-in for the engine's `presented.file` (Folder.swift).
//
// - The scheme handler serves the manifest alone: `..`, `%2e%2e`, an encoded slash, a symbolic link in the folder (to a
//   file outside it, or to a folder above it) and a very long path are 404s, and a file outside the folder is never read.
// - No `file:` address loads, by any way a page has to ask.
// - Another presentation's origin cannot be reached, and stores nothing in common.
// - The network is off: a listener of its own on 127.0.0.1, TCP and UDP, receives nothing from any way a page has to
//   reach it (fetch, XHR, `<img>`, CSS `url()`, `@import`, fonts, scripts, frames, media, workers, `import()`, a
//   WebSocket, `EventSource`, `sendBeacon`, preconnect, preload, prefetch, a ping, `<base>`, WebRTC, a form, a meta
//   refresh, a link, a script's navigation, `window.open`), while the same page in a plain web view does reach it.
// - DNS prefetching sends no query: measured from mDNSResponder's own log (`log stream`), against a plain web view that
//   does, with names under `.localhost`, which this Mac answers itself.
// - Nothing a page does puts up a panel or a window: alerts, confirmations, prompts, new windows, a file picker and
//   printing are answered at once, with the person's click too; what would ask for a permission or put up the
//   system's own sheets is not there to call, in any frame. It never calls the camera, the microphone or the location
//   itself, so that a page that could would not put a prompt on this Mac's screen during the check.
// - The live view has no message handler; the offscreen one's takes strings from its own main frame alone.
// - A page draws, with its own files, scripts, inline styles and storage; a blank one is said to be blank; a page whose
//   process ends is drawn again once.
//
//   cd app && swift build --product pi2-presented-check && .build/debug/pi2-presented-check [--pictures <folder>] [--only <words>]
//
// Every window is offscreen and never shown. Exits 1 if anything failed.

import AppKit
import TranscriptKit
import WebKit

setlinebuf(stdout)

nonisolated(unsafe) var failures = 0
func check(_ name: String, _ holds: Bool, _ detail: @autoclosure () -> String = "") {
    if holds { return }
    failures += 1
    let more = detail()
    print("FAIL  \(name)" + (more.isEmpty ? "" : "\n      " + more))
}

func info(_ text: String) { print("info  \(text)") }

/// `--only <words>`: only the groups whose names hold them, for working on one claim.
let only = CommandLine.arguments.firstIndex(of: "--only").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }

@MainActor
func group(_ name: String, _ body: () async -> Void) async {
    if let only, !name.contains(only) { return }
    let before = failures
    await body()
    print(failures == before ? "ok    \(name)" : "FAIL  \(name): \(failures - before) failed")
}

/// Waits for something, for as long as it takes on a loaded Mac; the limit only stops a hang.
@MainActor
func until(_ what: String, limit: Double = 120, _ holds: () async -> Bool) async -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < limit {
        if await holds() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    check(what, false, "not after \(Int(limit)) seconds")
    return false
}

/// Runs a script in the page's own world. WebKit counts it as the person's click (a user gesture). Nil if it fails, or
/// has not answered in ten seconds: a page in the middle of being stopped may never answer.
@MainActor
func js(_ view: WKWebView, _ body: String) async -> Any? {
    let answer = Answer()
    return await withCheckedContinuation { continuation in
        answer.continuation = continuation
        Task { @MainActor in answer.give(try? await view.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            answer.give(nil)
        }
    }
}

/// The first of a script's answer and its time running out.
@MainActor
final class Answer {
    var continuation: CheckedContinuation<Any?, Never>?

    func give(_ value: sending Any?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// What the page put in `window.results`, once it says it is done.
@MainActor
func results(_ view: WKWebView) async -> [String: String] {
    guard await until("the page says it is done", { await js(view, "return window.done === true") as? Bool == true }) else { return [:] }
    let text = await js(view, "return JSON.stringify(window.results ?? {})") as? String ?? "{}"
    return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String]) ?? [:]
}

/// The page's web content process, through a WebKit call that is not public.
@MainActor
func process(of view: WKWebView) -> pid_t? {
    guard view.responds(to: NSSelectorFromString("_webProcessIdentifier")),
          let pid = (view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
    return pid
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi2-presented-check-\(UUID().uuidString)", isDirectory: true)
/// What a page must never read: a file beside the pages' folders, outside every copy.
let secretMarker = "SECRET-OUTSIDE-\(UUID().uuidString.prefix(8))"
let secret = root.appendingPathComponent("secret.txt")

/// Writes a page's folder: its files, and symbolic links (name, target as written).
func folder(_ name: String, _ files: [String: Data], links: [(String, String)] = []) -> FolderFiles {
    let url = root.appendingPathComponent("pages/\(name)", isDirectory: true)
    for (path, data) in files {
        let file = url.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: file)
    }
    for (link, target) in links {
        try! FileManager.default.createSymbolicLink(atPath: url.appendingPathComponent(link).path, withDestinationPath: target)
    }
    return FolderFiles(folder: url)
}

func html(_ text: String) -> Data { Data(text.utf8) }

/// A small picture, drawn here.
func png(width: Int = 64, height: Int = 64) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.33, green: 0.36, blue: 0.91, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

/// A plain web view, with nothing of PresentedPageView's: the control that shows a probe does reach what it aims at
/// when nothing stops it. It keeps nothing on disk and has no delegate, so a page in it asks nothing either.
@MainActor
func control(_ page: String, base: URL, then: (WKWebView) async -> Void) async {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    window.contentView = view
    view.loadHTMLString(page, baseURL: base)
    await then(view)
    view.stopLoading()
    window.contentView = nil
    window.close()
}

/// A live view, as the window will hold it, in a window that is never shown, once its page has loaded.
@MainActor
func live(_ files: FolderFiles, page: PresentedPage? = nil, network: Bool? = nil, waits: Bool = true) async -> (NSWindow, PresentedPageView)? {
    // Without `network`, the view is made as every view was before the switch: `make`, which has none.
    let made: PresentedPageView? = if let network {
        try? await PresentedPageView.makeLive(page: page ?? files.manifest(), source: files, network: network)
    } else {
        try? await PresentedPageView.make(page: page ?? files.manifest(), source: files, mode: .live)
    }
    guard let view = made else {
        check("a live view is made", false)
        return nil
    }
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    view.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    window.contentView = view
    // A page that loads what it may not can stay loading; its own `done` says when it has finished instead.
    if !waits { return (window, view) }
    // The empty document before the page is complete too: the page is loaded once it is the one at its address.
    let entry = view.entryAddress?.absoluteString ?? ""
    guard await until("the live page loads", { await js(view, "return document.readyState + ' ' + location.href") as? String == "complete " + entry }) else { return nil }
    return (window, view)
}

@MainActor
func close(_ window: NSWindow, _ view: PresentedPageView) {
    view.close()
    window.contentView = nil
    window.close()
}

@MainActor
func run(pictures: URL?) async {
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try! Data(secretMarker.utf8).write(to: secret)
    let listener: Listener
    do {
        listener = try Listener()
        try await listener.start()
    } catch {
        check("a listener starts on 127.0.0.1", false, "\(error)")
        return
    }
    defer { listener.stop() }
    let net = listener.origin

    await paths()
    await drawsItsOwnPage(pictures: pictures)
    await blankPage()
    await outsideTheManifest()
    await noFileAddress()
    await otherOrigin()
    await networkLoads(listener: listener, net: net)
    await navigations(listener: listener, net: net)
    await dnsPrefetch()
    await panels(listener: listener, net: net)
    await messageHandlers()
    await processEnds()
    await networkSwitch(listener: listener, net: net)
    await spinningPage()

    await group("no window or panel came on screen through the whole check") {
        let shown = NSApp.windows.filter(\.isVisible)
        check("no window is visible", shown.isEmpty, shown.map { "\($0.className) “\($0.title)”" }.joined(separator: ", "))
        check("no colour panel was made", !NSColorPanel.sharedColorPanelExists)
    }
}

let app = NSApplication.shared
// No Dock icon, no menu bar, and never made active: the person's focus stays where it is.
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let arguments = CommandLine.arguments
    let pictures = arguments.firstIndex(of: "--pictures").flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1], isDirectory: true) : nil }
    if let pictures { try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true) }
    await run(pictures: pictures)
    try? FileManager.default.removeItem(at: root)
    print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
    exit(failures == 0 ? 0 : 1)
}
app.run()
