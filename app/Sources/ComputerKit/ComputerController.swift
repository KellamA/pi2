import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Sees and works other apps' windows for an agent, one action at a time.
///
/// Every action answers with the window as it is afterwards: a numbered list of its controls and, when wanted and
/// permitted, a picture. Acting on a control by number goes through the accessibility API, which is exact and does not
/// need the app in front; a point in the picture is the fallback, delivered as a click to that app alone.
public actor ComputerController {
    /// One conversation's latest look at one app: what its control numbers and picture positions refer to.
    private struct View {
        let pid: pid_t
        let app: AXUIElement
        let frame: CGRect
        /// Picture pixels per screen point; 1 when no picture was taken.
        let scale: CGFloat
        let windowID: CGWindowID?
        let window: AXUIElement?
        let statusWindow: AXUIElement?
        let statusWindowID: CGWindowID?
        let controls: [Control]
    }

    private var views: [String: View] = [:]
    private let ownBundleID: String?

    /// `ownBundleID` is refused as a target, so an agent cannot work the app that approves its actions.
    public init(ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.ownBundleID = ownBundleID
    }

    /// Whether macOS lets this process read and work other apps' controls. Silent: never shows the system prompt.
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    /// Whether macOS lets this process take pictures of other apps' windows. Silent as well.
    public static var screenRecordingGranted: Bool { WindowCapture.permitted }

    private static let needsAccessibility =
        "pi² does not have Accessibility permission, which it needs to read and work other apps. The person can grant it in this agent's settings in pi², under Computer use (System Settings › Privacy & Security › Accessibility), then reopen pi²; an update of pi² can cost it the permission until it is given again. Until then, tell them that is what is missing."

    public func forget(conversationId: Int) {
        views = views.filter { !$0.key.hasPrefix("\(conversationId)|") }
    }

    // MARK: - Entry point

    public func perform(_ request: ComputerRequest) async -> ComputerReply {
        if request.action == "list_apps" { return listApps(request.apps, testCopies: request.testCopies, anyApp: request.anyApp) }
        guard let bundleID = request.app, !bundleID.isEmpty else { return .failure("\(request.action) needs `app`, a bundle ID from list_apps.") }
        let acting = request.action == "describe" ? (request.of ?? "") : request.action
        if ComputerPolicy.same(bundleID, ownBundleID) || ComputerPolicy.isNever(bundleID) { return .failure("\(bundleID) cannot be used by an agent.") }
        if ComputerPolicy.isViewOnly(bundleID, anyApp: request.anyApp), !["screenshot", "open_app"].contains(acting), !(request.testCopies && isTestCopy(bundleID)) {
            if request.testCopies, TestCopy.hasTestCopyID(bundleID) {
                return .failure("\(Self.name(of: bundleID)) can only be looked at, not controlled: it is not running as a throwaway test copy of a development build, as scripts/test-copy starts one.")
            }
            return .failure("\(Self.name(of: bundleID)) can only be looked at, not controlled.")
        }
        if request.action == "describe" { return ComputerReply(ok: true, text: describe(request, bundleID: bundleID)) }
        if request.action == "open_app" { return await open(request, bundleID: bundleID) }
        guard Self.accessibilityGranted else { return .failure(Self.needsAccessibility) }
        guard let running = Self.running(bundleID) else {
            return .failure("\(Self.name(of: bundleID)) is not running. Use open_app to start it.")
        }
        switch request.action {
        case "screenshot":
            return await look(request, running: running, bundleID: bundleID, did: nil, summary: "Looked at \(Self.name(of: bundleID))")
        case "click": return await click(request, running: running, bundleID: bundleID)
        case "type": return await type(request, running: running, bundleID: bundleID)
        case "key": return await key(request, running: running, bundleID: bundleID)
        case "scroll": return await scroll(request, running: running, bundleID: bundleID)
        case "menu": return await menu(request, running: running, bundleID: bundleID)
        case "context_menu": return await contextMenu(request, running: running, bundleID: bundleID)
        default: return .failure("Unknown action “\(request.action)”.")
        }
    }

    // MARK: - Apps

    private static func running(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    /// Whether `bundleID` is running, and only as a throwaway test copy (`TestCopy`): every instance under that id, since
    /// an action goes to whichever macOS lists first. Never this app itself.
    private func isTestCopy(_ bundleID: String) -> Bool {
        guard !ComputerPolicy.same(bundleID, ownBundleID) else { return false }
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        return !instances.isEmpty && instances.allSatisfy { app in app.bundleURL.map { TestCopy.isThrowaway(bundleURL: $0, bundleID: bundleID) } ?? false }
    }

    public static func name(of bundleID: String) -> String {
        if let name = running(bundleID)?.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    private func listApps(_ apps: [String], testCopies: Bool, anyApp: Bool) -> ComputerReply {
        // Allow everything: any app may be used by its bundle id, and the person's list is only a start.
        let any = "You may use any app on this Mac by its bundle ID, except terminals, script editors, password managers and pi² itself; System Settings can only be looked at."
        var apps = apps
        if testCopies {
            // The test copies running now, which the agent may use without their being listed.
            for app in NSWorkspace.shared.runningApplications {
                guard let id = app.bundleIdentifier, TestCopy.hasTestCopyID(id), !apps.contains(where: { ComputerPolicy.same($0, id) }), isTestCopy(id) else { continue }
                apps.append(id)
            }
        }
        if anyApp, apps.isEmpty { return ComputerReply(ok: true, text: any, summary: "Listed apps") }
        guard !apps.isEmpty else {
            if testCopies {
                return ComputerReply(ok: true, text: "No apps listed, and no test copy of pi² is running. Start one with scripts/test-copy start test-<number>.", summary: "Listed apps")
            }
            return ComputerReply(ok: true, text: "No apps yet. The person chooses them in this agent's settings in pi², under Computer use.", summary: "Listed apps")
        }
        let lines = apps.map { bundleID -> String in
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            let state = Self.running(bundleID) != nil ? "running" : installed ? "not running" : "not installed"
            let copy = testCopies && isTestCopy(bundleID)
            let limit = copy ? ", a test copy of pi²" : ComputerPolicy.isViewOnly(bundleID, anyApp: anyApp) ? ", look only" : ""
            return "\(bundleID) — \(Self.name(of: bundleID)) (\(state)\(limit))"
        }
        let heading = anyApp ? "\(any) The apps the person listed:" : "Apps you may use:"
        return ComputerReply(ok: true, text: heading + "\n" + lines.joined(separator: "\n"), summary: "Listed apps")
    }

    private func open(_ request: ComputerRequest, bundleID: String) async -> ComputerReply {
        let name = Self.name(of: bundleID)
        var did = "\(name) was already open."
        if let running = Self.running(bundleID) {
            // Running with nothing to see: bring a minimized window back, or ask the app for a new one.
            if Self.accessibilityGranted {
                let app = AXUIElementCreateApplication(running.processIdentifier)
                let windows = Self.windowCandidates(of: app)
                if let first = Self.minimizedWindow(in: windows) {
                    AX.set(first, kAXMinimizedAttribute, kCFBooleanFalse)
                    did = "Brought \(name)'s window back."
                } else if windows.isEmpty, !Self.hasParkedWindow(running, bundleID: bundleID),
                          StatusItems.read(of: app, pid: running.processIdentifier).isEmpty {
                    await Self.launch(bundleID)
                    did = "Asked \(name) for a window."
                }
            }
        } else {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return .failure("\(bundleID) is not installed on this Mac.") }
            guard await Self.launch(bundleID) else { return .failure("\(name) could not be started.") }
            did = "Started \(name)."
            // Give it a moment to put up a window.
            for _ in 0..<24 {
                try? await Task.sleep(for: .milliseconds(250))
                if let running = Self.running(bundleID), running.isFinishedLaunching {
                    if !Self.accessibilityGranted || Self.hasParkedWindow(running, bundleID: bundleID) { break }
                    let app = AXUIElementCreateApplication(running.processIdentifier)
                    if !Self.windowCandidates(of: app).isEmpty || !StatusItems.read(of: app, pid: running.processIdentifier).isEmpty { break }
                }
            }
        }
        guard Self.accessibilityGranted, let running = Self.running(bundleID) else {
            return ComputerReply(ok: true, text: did, summary: "Opened \(name)")
        }
        try? await Task.sleep(for: .milliseconds(300))
        return await look(request, running: running, bundleID: bundleID, did: did, summary: "Opened \(name)")
    }

    /// Start the app, or reopen it, without bringing it in front of what the person is doing.
    @discardableResult
    private static func launch(_ bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil
    }

    // MARK: - Looking

    private func key(_ request: ComputerRequest, _ bundleID: String) -> String { "\(request.conversationId)|\(bundleID)" }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        (AX.value(window, kAXMinimizedAttribute) as? Bool) == true
    }

    /// The window `open_app` would restore. An unrecognized AX role or a missing attribute is not evidence that
    /// a window is minimized.
    private static func minimizedWindow(in windows: [AXUIElement]) -> AXUIElement? {
        guard let first = windows.first, windows.allSatisfy(isMinimized) else { return nil }
        return first
    }

    private static func isWindow(_ element: AXUIElement) -> Bool {
        ["AXWindow", "AXPopover", "AXDialog", "AXSheet"].contains(AX.role(element))
    }

    private static func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<30 {
            guard let candidate = current else { break }
            if isWindow(candidate) { return candidate }
            if let window = AX.element(candidate, kAXWindowAttribute) { return window }
            current = AX.parent(candidate)
        }
        return nil
    }

    private static func windowCandidates(of app: AXUIElement, includeStatusWindows: Bool = false) -> [AXUIElement] {
        let declared = [AX.element(app, kAXFocusedWindowAttribute),
                        AX.element(app, kAXFocusedUIElementAttribute).flatMap(enclosingWindow),
                        AX.element(app, kAXMainWindowAttribute)].compactMap { $0 }
        var candidates = declared + AX.children(app, kAXWindowsAttribute) + AX.children(app).filter(isWindow)
        if includeStatusWindows, let extras = AX.element(app, kAXExtrasMenuBarAttribute) {
            candidates += AX.children(extras).prefix(40).flatMap { AX.children($0).filter(isWindow) }
        }
        var unique: [AXUIElement] = []
        for candidate in candidates where !unique.contains(candidate) { unique.append(candidate) }
        return unique
    }

    private static func isParkedCopy(_ running: NSRunningApplication, bundleID: String) -> Bool {
        running.bundleURL.map { TestCopy.isThrowaway(bundleURL: $0, bundleID: bundleID) } ?? false
    }

    /// What came of asking a parked test copy to join its main window to the app's accessibility list (#579): a
    /// window that was never front is absent from that list, wherever it is parked, so the tool asks the copy to
    /// raise it once within its own level — nothing a person can see — and then reads it like any app's window.
    package enum ExposedCopy: Equatable {
        /// The copy answered that its window is in the list now (or already was).
        case listed
        /// The copy's build predates the request: it answered with the unknown command.
        case oldBuild
        /// No answer within the wait: the copy may be busy, or its window is not shown.
        case busy
        /// The copy answered that it did not raise its window, in `why`: its own words, kept for the answer given.
        case failed(String)
    }

    /// Ask the copy running under `bundleID`, already verified a throwaway test copy, to expose its parked window
    /// through the control folder its data folder holds — the same one `scripts/test-copy` drives. `pid` is the
    /// copy's own process, which it checks before answering. The copy's poll answers within a second or two.
    private static func exposeParkedCopy(_ running: NSRunningApplication, bundleID: String) async -> ExposedCopy {
        guard let folder = TestCopy.controlFolder(bundleID: bundleID) else {
            return .failed("its bundle id does not name a test copy's data folder")
        }
        return await exposeParkedCopy(pid: running.processIdentifier, folder: folder)
    }

    /// The request itself, for a check with a stand-in folder: writes `request.json` naming the copy's pid, then
    /// waits for `response.json` and takes the copy's word for whether its window is in the list now.
    package static func exposeParkedCopy(pid: pid_t, folder: URL) async -> ExposedCopy {
        guard let home = try? folder.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              home.isDirectory == true, home.isSymbolicLink == false else {
            return .failed("its data folder is missing or a symbolic link")
        }
        if let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard values.isDirectory == true, values.isSymbolicLink == false else {
                return .failed("its control folder is not a folder or is a symbolic link")
            }
        } else {
            // A copy makes this folder as it starts (#579); one from a build before that may not have it, and then it
            // could answer nothing at all. Make it as scripts/test-copy's own driver does, so an older copy still says
            // that its build predates the request.
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                           attributes: [.posixPermissions: 0o700])) != nil else {
                return .failed("its control folder is missing and could not be made")
            }
        }
        let dir = folder.appendingPathComponent("request-expose-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let request = try JSONSerialization.data(withJSONObject: ["pid": Int(pid), "command": "expose"])
            try request.write(to: dir.appendingPathComponent("request.json"), options: .atomic)
        } catch { return .busy }
        defer { try? FileManager.default.removeItem(at: dir) }
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("response.json")),
                  let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { continue }
            if let error = answer["error"] {
                return error.contains("unknown test-copy window command") ? .oldBuild : .failed(error)
            }
            return .listed
        }
        return .busy
    }

    /// What to tell the agent when a parked copy's window is in the window server but not in the app's accessibility
    /// list, after the copy was asked to raise it (#579): one cause at a time, each with what still works, and never a
    /// failure claimed where the copy did what it was asked.
    package static func unreadableParkedCopy(_ exposed: ExposedCopy?) -> String {
        switch exposed {
        case .oldBuild:
            return "The copy's window is parked out of the way, so its controls are not readable, and this copy's build predates the request that raises it: rebuild the app and run scripts/test-copy reopen <suffix>, then take another screenshot. A click at a point in a picture is still sent to the window."
        case .busy:
            return "The copy's window is parked out of the way, and the copy did not answer the request to raise it — it may be busy, or its window is not shown. Take another screenshot in a moment. A click at a point in a picture is still sent to the window."
        case .listed:
            return "The copy raised its parked window, but pi² still cannot read its controls. A click at a point in a picture is still sent to the window, and what the copy holds can be read through its engine (scripts/test-copy call)."
        case .failed(let why):
            return "The copy's window is parked out of the way and the copy did not raise it: \(why). A click at a point in a picture is still sent to the window, and what the copy holds can be read through its engine (scripts/test-copy call)."
        case nil:
            return "The copy's window is parked out of the way, so its controls are not readable. A click at a point in a picture is still sent to the window, and what the copy holds can be read through its engine (scripts/test-copy call)."
        }
    }

    /// What to tell the agent after a click was sent to a window whose controls could not be read: an empty
    /// fingerprint (no listed controls, before or after) says nothing, so it must not claim the click changed
    /// nothing (#579). `atPoint` distinguishes a click at bare coordinates from one on a listed control. Nil when
    /// the click verifiably changed something.
    package static func clickOutcome(before: String, after: String, atPoint: Bool) -> String? {
        if before.isEmpty && after.isEmpty {
            return " pi² cannot read this window's controls, so it cannot say whether the click changed anything: check what the picture shows now, or the app's state another way."
        }
        if before != after { return nil }
        return atPoint
            ? " Nothing in the window appears to have changed: this app may ignore clicks at a point while it is in the background. Use a listed control, the menu, or keys instead."
            : " It answers to no accessibility press, so it was sent a click, and nothing in the window appears to have changed: this app may ignore clicks while it is in the background. Try the menu, or keys."
    }

    private static func hasParkedWindow(_ running: NSRunningApplication, bundleID: String) -> Bool {
        guard isParkedCopy(running, bundleID: bundleID) else { return false }
        let pid = running.processIdentifier
        return ServerWindow.parkedCopy(in: ServerWindow.all(of: pid), pid: pid) != nil
    }

    /// The menus open in the app now, such as a context menu: macOS lists one among the app's own children while it is
    /// open, and keeps the focus in it. Not the menu bar, and not a pop-up button's menu, which is read with its window.
    static func openMenus(of app: AXUIElement) -> [AXUIElement] {
        let menus = AX.children(app).filter { AX.role($0) == "AXMenu" }
        if !menus.isEmpty { return menus }
        var current = AX.element(app, kAXFocusedUIElementAttribute)
        for _ in 0..<4 {
            guard let element = current else { break }
            let role = AX.role(element)
            if role == "AXMenuBar" || role == "AXWindow" || role == "AXApplication" { break }
            if role == "AXMenu" {
                // A menu of the menu bar's is the `menu` action's, not one this lists.
                var outer = AX.parent(element)
                for _ in 0..<6 {
                    guard let parent = outer else { break }
                    if AX.role(parent) == "AXMenuBar" { return [] }
                    outer = AX.parent(parent)
                }
                return [element]
            }
            current = AX.parent(element)
        }
        return []
    }

    /// Read the front window and answer with it. `did` is what just happened, said first.
    private func look(_ request: ComputerRequest, running: NSRunningApplication, bundleID: String, did: String?, summary: String,
                      beforeStatusPress: (windows: [AXUIElement], visibleIDs: Set<CGWindowID>)? = nil) async -> ComputerReply {
        let name = running.localizedName ?? Self.name(of: bundleID)
        let pid = running.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        let prefix = did.map { $0 + "\n\n" } ?? ""
        let previous = view(request, bundleID, running: running)
        let parkedCopy = Self.isParkedCopy(running, bundleID: bundleID)
        let server = ServerWindow.all(of: pid)
        var minimized = false
        func search() -> (ordered: [AXUIElement], accessible: (AXUIElement, CGRect)?) {
            let candidates = Self.windowCandidates(of: app, includeStatusWindows: beforeStatusPress != nil || previous?.statusWindow != nil || previous?.statusWindowID != nil)
            let ordered = WindowChoice.order(candidates, beforePress: beforeStatusPress?.windows, preferred: previous?.statusWindow)
            minimized = Self.minimizedWindow(in: candidates) != nil
            let parked = parkedCopy && !minimized ? ServerWindow.parkedCopy(in: server, pid: pid) : nil
            let accessible = WindowChoice.first(in: ordered, minimized: Self.isMinimized) { candidate in
                guard let frame = AX.frame(candidate) else { return nil }
                // A stale AXFocusedWindow can still have a frame after Settings closes. In a parked copy,
                // prefer evidence from the window server over an AX frame that does not belong to a current window.
                if parked != nil, !["AXPopover", "AXDialog", "AXSheet"].contains(AX.role(candidate)),
                   ServerWindow.matching(frame, in: server, pid: pid) == nil { return nil }
                return frame
            }
            return (ordered, accessible)
        }
        var found = search()
        var exposed: ExposedCopy?
        if found.accessible == nil, parkedCopy {
            // A window that has never been front is never in a parked copy's accessibility list, wherever it is
            // parked (#579). Ask the copy to raise it once within its own level — nothing a person can see — and
            // search again; its answer is kept for the words that say why if it still could not be read.
            exposed = await Self.exposeParkedCopy(running, bundleID: bundleID)
            if exposed == .listed { found = search() }
        }
        let accessible = found.accessible
        let parked = parkedCopy && !minimized ? ServerWindow.parkedCopy(in: server, pid: pid) : nil
        let menus = Self.openMenus(of: app)
        let popup = menus.isEmpty ? ServerWindow.statusPopup(in: server, pid: pid, before: beforeStatusPress?.visibleIDs, preferred: previous?.statusWindowID) : nil
        let newAXWindow = accessible.map { current in
            beforeStatusPress.map { !$0.windows.contains(current.0) } ?? (current.0 == previous?.statusWindow)
        } ?? false
        let fallback = !newAXWindow && popup != nil ? popup : accessible == nil ? parked : nil
        let frame = fallback?.frame ?? accessible?.1 ?? .zero
        let matched = fallback ?? accessible.flatMap { ServerWindow.matching($0.1, in: server, pid: pid) }
        // AX can omit a parked window or popup from the application's list but still answer a hit at its position.
        var window = fallback == nil ? accessible?.0 : nil
        if window == nil, let fallback {
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            if let recovered = AX.hitTest(app, centre).flatMap(Self.enclosingWindow), let rect = AX.frame(recovered),
               ServerWindow.matching(rect, in: server, pid: pid)?.id == fallback.id { window = recovered }
        }
        let statusWindow = newAXWindow ? window : nil
        let statusWindowID = newAXWindow ? matched?.id : popup?.id
        var reader = WindowReader(windowFrame: frame)
        // An open menu is read first, so its items come first and are never the ones cut off.
        for menu in menus { reader.read(menu) }
        let menuItems = reader.controls.count
        if let window { reader.read(window) }
        reader.controls += StatusItems.read(of: app, pid: pid)

        var shot: WindowCapture.Shot?
        var lines: [String] = []
        if frame.isEmpty {
            lines.append(minimized ? "\(name)'s window is minimized. Use open_app to bring it back." : "\(name) has no open window.")
        } else {
            let title = (window.flatMap { AX.string(AX.value($0, kAXTitleAttribute)) } ?? matched?.title).map { " — window “\($0.clipped(80))”" } ?? ""
            if request.image, WindowCapture.permitted {
                if let target = await WindowCapture.window(pid: pid, frame: frame, id: matched?.id) {
                    shot = await WindowCapture.capture(target, frame: frame)
                }
            }
            if let shot {
                lines.append("\(name)\(title), \(Int((frame.width * shot.scale).rounded()))×\(Int((frame.height * shot.scale).rounded())) pixels.")
            } else {
                lines.append("\(name)\(title).")
                if request.image {
                    lines.append(WindowCapture.permitted ? "No picture: the window could not be captured this time."
                                 : "No picture: pi² has no Screen Recording permission (the person can grant it in this agent's settings).")
                }
            }
            if window == nil {
                if parked != nil {
                    // The window is there (the window server found it) but not in the app's accessibility list:
                    // a parked copy's window is only joined to that list by an ordering event, which the copy was
                    // asked for (#579). Say which cause it was and what still works, rather than blaming the app.
                    lines.append(Self.unreadableParkedCopy(exposed))
                } else {
                    lines.append("The window is open, but the app did not expose it through Accessibility.")
                }
            }
        }
        let scale = shot?.scale ?? 1
        views[key(request, bundleID)] = View(pid: pid, app: app, frame: frame, scale: scale, windowID: shot?.windowID ?? matched?.id,
                                             window: window, statusWindow: statusWindow, statusWindowID: statusWindowID, controls: reader.controls)
        if !menus.isEmpty {
            lines.append(menuItems == 0
                ? "A menu is open, but its items could not be read. Press escape to close it."
                : "A menu is open: its items are [1] to [\(menuItems)] below, and the picture does not show it. Click one to choose it, or press escape to close the menu.")
        }
        if reader.controls.isEmpty {
            lines.append(frame.isEmpty ? "Use open_app, or its menu, to open a window."
                         : shot == nil ? "No controls could be read from this window." : "No controls could be read from this window. Use x and y in the picture, or the menu.")
        } else {
            lines.append("Controls (these numbers are for this view only):")
            for (index, control) in reader.controls.enumerated() {
                var line = "[\(index + 1)] \(control.kind)"
                if let label = control.label { line += " “\(label.clipped(70))”" }
                if let value = control.value, value != control.label { line += ", value “\(value.clipped(80))”" }
                if control.statusItem {
                    line += " (in the macOS menu bar, not in the picture)"
                } else if !frame.isEmpty {
                    let x = Int(((control.frame.midX - frame.minX) * scale).rounded()), y = Int(((control.frame.midY - frame.minY) * scale).rounded())
                    line += " (\(x),\(y))"
                }
                if control.focused { line += " focused" }
                if control.selected { line += " selected" }
                if !control.enabled { line += " disabled" }
                lines.append(line)
            }
            if reader.truncated { lines.append("(There are more controls than listed. Scroll, or act by x and y.)") }
        }
        // Without a picture the window's text is the only way to read it.
        if shot == nil {
            var seen = Set<String>()
            let text = reader.text.filter { seen.insert($0).inserted }.joined(separator: "\n")
            if !text.isEmpty { lines.append("Text in the window:\n" + (text.count > 3000 ? String(text.prefix(3000)) + "…" : text)) }
        }
        return ComputerReply(ok: did != nil || !frame.isEmpty || !reader.controls.isEmpty, text: prefix + lines.joined(separator: "\n"), summary: summary, jpeg: shot?.jpeg)
    }

    // MARK: - Acting

    private func view(_ request: ComputerRequest, _ bundleID: String, running: NSRunningApplication) -> View? {
        guard let view = views[key(request, bundleID)], view.pid == running.processIdentifier else { return nil }
        return view
    }

    private static let lookFirst = "Take a screenshot of the app first: control numbers and positions come from it."

    private func control(_ number: Int, in view: View) -> Result<Control, ComputerReply> {
        guard number >= 1, number <= view.controls.count else {
            return .failure(.failure("There is no control \(number) in the latest view; it has \(view.controls.count). Take a screenshot to see the current ones."))
        }
        let control = view.controls[number - 1]
        // The window may have changed since the look; a control that is gone no longer answers.
        guard control.statusItem || AX.value(control.element, kAXRoleAttribute) != nil else {
            return .failure(.failure("Control \(number) is no longer there; the window has changed. Take a screenshot to see it as it is now."))
        }
        return .success(control)
    }

    private func screenPoint(_ request: ComputerRequest, in view: View) -> Result<CGPoint, ComputerReply> {
        guard let x = request.x, let y = request.y else { return .failure(.failure("Give `element`, or both `x` and `y`.")) }
        guard !view.frame.isEmpty else { return .failure(.failure("There is no window for that point. Use a numbered menu bar item if one is listed.")) }
        let point = CGPoint(x: view.frame.minX + x / view.scale, y: view.frame.minY + y / view.scale)
        guard view.frame.contains(point) else {
            let width = Int((view.frame.width * view.scale).rounded()), height = Int((view.frame.height * view.scale).rounded())
            return .failure(.failure("(\(Int(x)), \(Int(y))) is outside the window, which is \(width)×\(height) pixels in the latest view."))
        }
        return .success(point)
    }

    /// How the thing at a point can be worked without a real mouse click.
    private enum Reach {
        case press(AXUIElement)
        case select(AXUIElement)
        case focus(AXUIElement)
    }

    private static let pressable: [String: String] = [
        "AXButton": "button", "AXCheckBox": "checkbox", "AXRadioButton": "radio button", "AXLink": "link", "AXMenuItem": "menu item",
        "AXPopUpButton": "pop-up menu", "AXMenuButton": "menu button", "AXDisclosureTriangle": "disclosure arrow",
    ]

    /// What is at a point: its kind and name for describing it, and how to work it. The thing directly under a point is
    /// often the text inside a button or a row, so the control itself is looked for a few levels up.
    private static func identify(element: AXUIElement) -> (kind: String, label: String?, reach: Reach?, secure: Bool) {
        var current: AXUIElement? = element
        var ownLabel: String?
        var ownKind = ""
        var secure = false
        for level in 0..<5 {
            guard let candidate = current else { break }
            let got = AX.values(candidate, [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute])
            let role = (got[0] as? String) ?? ""
            let label = AX.string(got[2]) ?? AX.string(got[3]) ?? (role == "AXStaticText" ? AX.string(got[4]) : nil)
            if level == 0 {
                ownLabel = label
                ownKind = role == "AXStaticText" ? "text" : role.replacingOccurrences(of: "AX", with: "").lowercased()
                secure = (got[1] as? String) == "AXSecureTextField"
            }
            if role == "AXWindow" || role == "AXApplication" { break }
            if let kind = pressable[role], AX.actions(candidate).contains(kAXPressAction) { return (kind, label ?? ownLabel, .press(candidate), secure) }
            if role == "AXRow", AX.settable(candidate, kAXSelectedAttribute) { return ("row", label ?? ownLabel, .select(candidate), secure) }
            if level == 0, role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
                return ((got[1] as? String) == "AXSecureTextField" ? "password field" : "text field", label, .focus(candidate), secure)
            }
            current = AX.parent(candidate)
        }
        return (ownKind, ownLabel, nil, secure)
    }

    /// A cheap fingerprint of the window, to notice when an action changed nothing.
    private func signature(_ request: ComputerRequest, _ bundleID: String) -> String {
        guard let view = views[key(request, bundleID)] else { return "" }
        return view.controls.map { "\($0.kind)|\($0.label ?? "")|\($0.value ?? "")|\($0.selected)|\($0.focused)|\(Int($0.frame.midY))" }.joined(separator: "\n")
    }

    private func click(_ request: ComputerRequest, running: NSRunningApplication, bundleID: String) async -> ComputerReply {
        guard let view = view(request, bundleID, running: running) else { return .failure(Self.lookFirst) }
        let name = running.localizedName ?? bundleID
        let count = max(1, min(request.count ?? 1, 2))
        var did: String
        var what: String
        if let number = request.element {
            let control: Control
            switch self.control(number, in: view) {
            case .success(let found): control = found
            case .failure(let reply): return reply
            }
            if control.statusItem {
                guard count == 1 else { return .failure("Use a single click on a menu bar item.") }
                return await clickStatusItem(control, request: request, view: view, running: running, bundleID: bundleID)
            }
            guard control.enabled else { return .failure("Control \(number), \(control.phrase), is disabled, so clicking it would do nothing.") }
            what = control.label.map { "“\($0.clipped(40))”" } ?? control.kind
            let centre = CGPoint(x: control.frame.midX, y: control.frame.midY)
            if count == 2 {
                Input.click(pid: view.pid, at: centre, windowID: view.windowID, count: 2)
                did = "Double-clicked \(control.phrase)."
            } else if control.role == "AXRow", AX.settable(control.element, kAXSelectedAttribute), AX.set(control.element, kAXSelectedAttribute, kCFBooleanTrue) {
                did = "Selected \(control.phrase)."
            } else if control.isText {
                if !AX.set(control.element, kAXFocusedAttribute, kCFBooleanTrue) { Input.click(pid: view.pid, at: centre, windowID: view.windowID, count: 1) }
                did = "Put the cursor in \(control.phrase)."
            } else if Reaching.pressable(AXNode(control.element)), AX.perform(control.element, kAXPressAction) {
                did = "Clicked \(control.phrase)."
            } else {
                // It answers to no press, so it gets a real click, which an app in the background may ignore: say so
                // when nothing changed, as for a click at a point.
                let before = signature(request, bundleID)
                Input.click(pid: view.pid, at: centre, windowID: view.windowID, count: 1)
                did = "Clicked \(control.phrase)."
                try? await Task.sleep(for: .milliseconds(450))
                var reply = await look(request, running: running, bundleID: bundleID, did: did, summary: "Clicked \(what) in \(name)")
                if reply.ok, let note = Self.clickOutcome(before: before, after: signature(request, bundleID), atPoint: false) {
                    reply.text = did + note + reply.text.dropFirst(did.count)
                }
                return reply
            }
        } else {
            let point: CGPoint
            switch screenPoint(request, in: view) {
            case .success(let found): point = found
            case .failure(let reply): return reply
            }
            let found = AX.hitTest(view.app, point).map(Self.identify(element:))
            let named = found.map { thing in thing.label.map { "the “\($0.clipped(60))” \(thing.kind)" } ?? "the \(thing.kind)" } ?? "that point"
            what = found?.label.map { "“\($0.clipped(40))”" } ?? "(\(Int(request.x ?? 0)), \(Int(request.y ?? 0)))"
            var reached = false
            if count == 1, let reach = found?.reach {
                switch reach {
                case .press(let element):
                    reached = AX.perform(element, kAXPressAction)
                    did = "Clicked \(named) at that point."
                case .select(let element):
                    reached = AX.set(element, kAXSelectedAttribute, kCFBooleanTrue)
                    did = "Selected \(named) at that point."
                case .focus(let element):
                    reached = AX.set(element, kAXFocusedAttribute, kCFBooleanTrue)
                    did = "Put the cursor in \(named)."
                }
            } else {
                did = ""
            }
            if !reached {
                // Nothing there answers to accessibility, so send the app a real click. Some apps only take those
                // while they are in front; whether this one did shows in whether the window changed.
                let before = signature(request, bundleID)
                Input.click(pid: view.pid, at: point, windowID: view.windowID, count: count)
                try? await Task.sleep(for: .milliseconds(450))
                did = "\(count == 2 ? "Double-clicked" : "Clicked") at (\(Int(request.x ?? 0)), \(Int(request.y ?? 0)))."
                var reply = await look(request, running: running, bundleID: bundleID, did: did, summary: "\(count == 2 ? "Double-clicked" : "Clicked") \(what) in \(name)")
                if reply.ok, let note = Self.clickOutcome(before: before, after: signature(request, bundleID), atPoint: true) {
                    reply.text = did + note + "\n\n" + reply.text.dropFirst(did.count).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return reply
            }
        }
        try? await Task.sleep(for: .milliseconds(450))
        return await look(request, running: running, bundleID: bundleID, did: did, summary: "\(count == 2 ? "Double-clicked" : "Clicked") \(what) in \(name)")
    }

    private func clickStatusItem(_ control: Control, request: ComputerRequest, view: View, running: NSRunningApplication, bundleID: String) async -> ComputerReply {
        guard let item = StatusItems.read(of: view.app, pid: view.pid).first(where: { $0.element == control.element && $0.label == control.label }) else {
            return .failure("That menu bar item changed. Take a screenshot to see the current items.")
        }
        guard item.enabled else { return .failure("\(item.phrase) is disabled.") }
        let before = (windows: Self.windowCandidates(of: view.app, includeStatusWindows: true),
                      visibleIDs: Set(ServerWindow.all(of: view.pid).filter(\.onScreen).map(\.id)))
        let action = StatusItems.action(in: AX.actions(item.element))
        AXUIElementSetMessagingTimeout(item.element, 1)
        guard AX.perform(item.element, action) else { return .failure("\(item.phrase) did not answer a click through Accessibility.") }
        // The panel can open without becoming AXMainWindow. Give it time to appear among the app's windows.
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(150))
            let newWindows = Self.windowCandidates(of: view.app, includeStatusWindows: true).filter { !before.windows.contains($0) }
            if WindowChoice.first(in: newWindows, minimized: Self.isMinimized, frame: AX.frame) != nil || !Self.openMenus(of: view.app).isEmpty { break }
        }
        return await look(request, running: running, bundleID: bundleID, did: "Clicked \(item.phrase).", summary: "Clicked a menu bar item in \(running.localizedName ?? bundleID)", beforeStatusPress: before)
    }

    /// Opens the context menu of a listed control, or of what is at a point: through accessibility (`AXShowMenu`), which
    /// works with the app in the background, and with a secondary click where nothing near answers to that, or nothing
    /// opened. The menu's items are then listed first, as controls, by `look`.
    private func contextMenu(_ request: ComputerRequest, running: NSRunningApplication, bundleID: String) async -> ComputerReply {
        guard let view = view(request, bundleID, running: running) else { return .failure(Self.lookFirst) }
        let name = running.localizedName ?? bundleID
        let element: AXUIElement?
        let point: CGPoint
        let phrase: String
        let what: String
        if let number = request.element {
            let control: Control
            switch self.control(number, in: view) {
            case .success(let found): control = found
            case .failure(let reply): return reply
            }
            guard !control.statusItem else { return .failure("Use click, not context_menu, to open a menu bar item.") }
            element = control.element
            point = CGPoint(x: control.frame.midX, y: control.frame.midY)
            phrase = control.phrase
            what = control.label.map { "“\($0.clipped(40))”" } ?? control.kind
        } else {
            switch screenPoint(request, in: view) {
            case .success(let found): point = found
            case .failure(let reply): return reply
            }
            element = AX.hitTest(view.app, point)
            phrase = "what is at (\(Int(request.x ?? 0)), \(Int(request.y ?? 0)))"
            what = "(\(Int(request.x ?? 0)), \(Int(request.y ?? 0)))"
        }
        let summary = "Opened the menu of \(what) in \(name)"
        if !Self.openMenus(of: view.app).isEmpty {
            return await look(request, running: running, bundleID: bundleID, did: "A menu is already open; choose from it, or press escape to close it first.", summary: summary)
        }
        var opened = false
        if let target = element.flatMap({ Reaching.menuTarget(of: AXNode($0))?.element }) {
            // An app shows the menu inside its answer and answers only once the menu has closed, so do not wait for it.
            AXUIElementSetMessagingTimeout(target, 1)
            if AX.perform(target, Reaching.showMenu) { opened = await menuOpens(view.app) }
        }
        if !opened {
            Input.rightClick(pid: view.pid, at: point, windowID: view.windowID)
            opened = await menuOpens(view.app)
        }
        let did = opened
            ? "Opened the context menu of \(phrase)."
            : "Asked for the context menu of \(phrase), and no menu opened: it may have none, or this app may show it only while it is in front."
        return await look(request, running: running, bundleID: bundleID, did: did, summary: summary)
    }

    /// Whether a menu opens in the app within a second and a half.
    private func menuOpens(_ app: AXUIElement) async -> Bool {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(150))
            if !Self.openMenus(of: app).isEmpty { return true }
        }
        return false
    }

    private func type(_ request: ComputerRequest, running: NSRunningApplication, bundleID: String) async -> ComputerReply {
        guard let text = request.text, !text.isEmpty else { return .failure("type needs `text`.") }
        let name = running.localizedName ?? bundleID
        let pid = running.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        var target: AXUIElement?
        var phrase = "the focused field"
        if let number = request.element {
            guard let view = view(request, bundleID, running: running) else { return .failure(Self.lookFirst) }
            let control: Control
            switch self.control(number, in: view) {
            case .success(let found): control = found
            case .failure(let reply): return reply
            }
            guard control.isText else { return .failure("Control \(number) is \(control.phrase), not somewhere to type. Pick a text field, or leave `element` out to type where the cursor is.") }
            guard control.enabled else { return .failure("Control \(number), \(control.phrase), is disabled.") }
            if !AX.set(control.element, kAXFocusedAttribute, kCFBooleanTrue) {
                Input.click(pid: pid, at: CGPoint(x: control.frame.midX, y: control.frame.midY), windowID: view.windowID, count: 1)
            }
            try? await Task.sleep(for: .milliseconds(120))
            target = control.element
            phrase = control.phrase
        } else {
            target = AX.element(app, kAXFocusedUIElementAttribute)
        }
        if let target, (AX.value(target, kAXSubroleAttribute) as? String) == "AXSecureTextField" {
            return .failure("That is a password field. pi² does not type passwords; ask the person to enter it themselves.")
        }
        // Inserting through accessibility puts the text at the cursor and cannot go to the wrong app. Keys are the fallback.
        if let target, AX.settable(target, kAXSelectedTextAttribute), AX.set(target, kAXSelectedTextAttribute, text as CFString) {
            // done
        } else {
            Input.type(pid: pid, text: text)
        }
        try? await Task.sleep(for: .milliseconds(300))
        return await look(request, running: running, bundleID: bundleID, did: "Typed “\(text.clipped(80))” into \(phrase).", summary: "Typed “\(text.clipped(30))” in \(name)")
    }

    private func key(_ request: ComputerRequest, running: NSRunningApplication, bundleID: String) async -> ComputerReply {
        guard let text = request.text, let combo = Input.parse(text) else {
            return .failure("“\(request.text ?? "")” is not a key pi² knows. Examples: return, tab, escape, delete, up, cmd+s, shift+cmd+z. To enter text, use type.")
        }
        let name = running.localizedName ?? bundleID
        // Escape with a menu open closes the menu, through accessibility, which reaches it in the background.
        if combo.key == Input.escape, combo.flags.isEmpty, let menu = Self.openMenus(of: AXUIElementCreateApplication(running.processIdentifier)).first,
           AX.perform(menu, kAXCancelAction) {
            try? await Task.sleep(for: .milliseconds(300))
            return await look(request, running: running, bundleID: bundleID, did: "Pressed \(combo.display): closed the menu.", summary: "Closed a menu in \(name)")
        }
        Input.press(pid: running.processIdentifier, combo)
        try? await Task.sleep(for: .milliseconds(450))
        return await look(request, running: running, bundleID: bundleID, did: "Pressed \(combo.display).", summary: "Pressed \(combo.display) in \(name)")
    }

    private func scroll(_ request: ComputerRequest, running: NSRunningApplication, bundleID: String) async -> ComputerReply {
        let pages = Scrolling.pages(request.dy ?? 0)
        guard pages != 0 else { return .failure("scroll needs `dy`: pages to scroll, positive for down.") }
        guard let view = view(request, bundleID, running: running) else { return .failure(Self.lookFirst) }
        guard !view.frame.isEmpty else { return .failure("There is no open window to scroll.") }
        var area: AXUIElement?
        var point: CGPoint?
        if let number = request.element {
            switch control(number, in: view) {
            case .success(let found):
                guard !found.statusItem else { return .failure("A menu bar item is not a scrolling view.") }
                area = Scrolling.area(containing: found.element)
                point = CGPoint(x: found.frame.midX, y: found.frame.midY)
            case .failure(let reply): return reply
            }
        } else if request.x != nil || request.y != nil {
            switch screenPoint(request, in: view) {
            case .success(let found):
                point = found
                // Hit testing can fail when a parked window's centre is offscreen.
                area = AX.hitTest(view.app, found).flatMap(Scrolling.area(containing:))
            case .failure(let reply): return reply
            }
        }
        if area == nil, let window = view.window { area = Scrolling.area(in: window, frame: view.frame, at: point) }
        let bounds = area.flatMap(AX.frame)?.intersection(view.frame)
        let viewport = bounds.flatMap { $0.isEmpty ? nil : $0 } ?? view.frame
        let destination = point.flatMap { viewport.contains($0) ? $0 : nil } ?? CGPoint(x: viewport.midX, y: viewport.midY)
        let position = Scrolling.Position(area: area, viewport: viewport)
        // Send one precise wheel event per page; each delta is a viewport, not a fraction of the document.
        let distance = Scrolling.distance(pages: pages > 0 ? 1 : -1, viewport: viewport)
        for _ in 0..<abs(pages) {
            guard Input.scroll(pid: view.pid, at: destination, windowID: view.windowID, points: distance) else {
                return .failure("Could not send a scroll-wheel event to the window.")
            }
            if abs(pages) > 1 { try? await Task.sleep(for: .milliseconds(50)) }
        }
        try? await Task.sleep(for: .milliseconds(450))
        var movement = position.movement()
        var fallback = ""
        // Don't scroll twice when movement simply can't be measured. Only try the app's native page control when
        // the scrollbar confirms it didn't move and isn't already at the requested end.
        if movement == .still, let button = position.pageButton(pages: pages) {
            for _ in 0..<abs(pages) {
                guard AX.perform(button, kAXPressAction) else { break }
                try? await Task.sleep(for: .milliseconds(70))
            }
            try? await Task.sleep(for: .milliseconds(350))
            fallback = " Also tried the app's page control."
            movement = position.movement()
        }
        let direction = pages > 0 ? "down" : "up"
        let name = running.localizedName ?? bundleID
        let did = "Sent a scroll of \(abs(pages)) page\(abs(pages) == 1 ? "" : "s") \(direction).\(fallback) \(movement.report)"
        return await look(request, running: running, bundleID: bundleID, did: did, summary: "Scroll \(direction) in \(name): \(movement.report)")
    }

    private static func menuTitle(_ title: String) -> String {
        title.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
    }

    /// The items a menu bar item or a menu item opens.
    private static func menuItems(of element: AXUIElement) -> [AXUIElement] {
        let children = AX.children(element)
        if let menu = children.first(where: { AX.role($0) == "AXMenu" }) { return AX.children(menu) }
        return children
    }

    private static func menuParts(_ path: String) -> [String] {
        path.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func menu(_ request: ComputerRequest, running: NSRunningApplication, bundleID: String) async -> ComputerReply {
        let parts = Self.menuParts(request.path ?? "")
        guard !parts.isEmpty else { return .failure("menu needs `path`, such as \"File > Save\".") }
        // The Apple menu is the Mac's, not the app's: sleep, restart, log out.
        if Self.menuTitle(parts[0]) == "apple" || parts[0] == "" { return .failure("The Apple menu is not available to agents.") }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 2)
        guard let bar = AX.element(app, kAXMenuBarAttribute) else { return .failure("\(running.localizedName ?? bundleID) has no menu bar to use.") }
        var items = AX.children(bar)
        var chosen: AXUIElement?
        for (index, part) in parts.enumerated() {
            let titles = items.compactMap { AX.string(AX.value($0, kAXTitleAttribute)) }
            guard let match = items.first(where: { AX.string(AX.value($0, kAXTitleAttribute)).map(Self.menuTitle) == Self.menuTitle(part) }) else {
                let offered = titles.filter { $0 != "Apple" }.prefix(40).joined(separator: ", ")
                return .failure("There is no “\(part)” \(index == 0 ? "menu" : "in that menu"). It has: \(offered).")
            }
            chosen = match
            if index < parts.count - 1 { items = Self.menuItems(of: match) }
        }
        guard let chosen else { return .failure("Nothing to choose.") }
        if (AX.value(chosen, kAXEnabledAttribute) as? Bool) == false { return .failure("“\(parts.joined(separator: " > "))” is greyed out right now.") }
        if !Self.menuItems(of: chosen).isEmpty, AX.role(chosen) != "AXMenuItem" || !AX.children(chosen).isEmpty {
            let offered = Self.menuItems(of: chosen).compactMap { AX.string(AX.value($0, kAXTitleAttribute)) }.prefix(40).joined(separator: ", ")
            return .failure("“\(parts.joined(separator: " > "))” is a menu, not a command. It has: \(offered).")
        }
        guard AX.perform(chosen, kAXPressAction) else { return .failure("“\(parts.joined(separator: " > "))” could not be chosen.") }
        try? await Task.sleep(for: .milliseconds(500))
        let name = running.localizedName ?? bundleID
        let path = parts.joined(separator: " > ")
        return await look(request, running: running, bundleID: bundleID, did: "Chose \(path).", summary: "Chose \(path) in \(name)")
    }

    // MARK: - Describing, for approval

    /// What an action would do, in words a person can approve: "Click the “Send” button in Mail".
    private func describe(_ request: ComputerRequest, bundleID: String) -> String {
        let name = Self.name(of: bundleID)
        let view = Self.running(bundleID).flatMap { self.view(request, bundleID, running: $0) }
        let listed: Control? = request.element.flatMap { number in view.flatMap { number >= 1 && number <= $0.controls.count ? $0.controls[number - 1] : nil } }
        switch request.of ?? "" {
        case "open_app": return "Open \(name)"
        case "click":
            let verb = (request.count ?? 1) >= 2 ? "Double-click" : "Click"
            if let listed { return "\(verb) \(listed.phrase) in \(name)" }
            if let view, let x = request.x, let y = request.y {
                let point = CGPoint(x: view.frame.minX + x / view.scale, y: view.frame.minY + y / view.scale)
                if let found = AX.hitTest(view.app, point).map(Self.identify(element:)), let label = found.label {
                    return "\(verb) “\(label.clipped(60))”\(found.kind.isEmpty ? "" : " (\(found.kind))") in \(name)"
                }
                return "\(verb) at (\(Int(x)), \(Int(y))) in \(name)’s window"
            }
            return "\(verb) in \(name)"
        case "type":
            let text = "“\((request.text ?? "").clipped(120))”"
            if let listed { return "Type \(text) into \(listed.phrase) in \(name)" }
            return "Type \(text) in \(name)"
        case "key":
            return "Press \(Input.parse(request.text ?? "")?.display ?? (request.text ?? "a key")) in \(name)"
        case "scroll":
            let pages = abs(Scrolling.pages(request.dy ?? 1))
            return "Scroll \((request.dy ?? 1) < 0 ? "up" : "down") \(pages) page\(pages == 1 ? "" : "s") in \(name)"
        case "menu":
            return "Choose \(Self.menuParts(request.path ?? "").joined(separator: " > ")) from \(name)’s menu"
        case "context_menu":
            if let listed { return "Open the context menu of \(listed.phrase) in \(name)" }
            if let view, let x = request.x, let y = request.y {
                let point = CGPoint(x: view.frame.minX + x / view.scale, y: view.frame.minY + y / view.scale)
                if let found = AX.hitTest(view.app, point).map(Self.identify(element:)), let label = found.label {
                    return "Open the context menu of “\(label.clipped(60))”\(found.kind.isEmpty ? "" : " (\(found.kind))") in \(name)"
                }
                return "Open the context menu at (\(Int(x)), \(Int(y))) in \(name)’s window"
            }
            return "Open a context menu in \(name)"
        default:
            return "Use \(name)"
        }
    }
}

extension ComputerController {
    /// Show macOS's own prompt for Accessibility. Only ever called from a button the person pressed.
    public static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// Show macOS's own prompt for Screen Recording. Only ever called from a button the person pressed.
    public static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
}
