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
        "pi² does not have Accessibility permission, which it needs to read and work other apps. The person can grant it in this agent's settings in pi², under Computer use. Until then, tell them that is what is missing."

    public func forget(conversationId: Int) {
        views = views.filter { !$0.key.hasPrefix("\(conversationId)|") }
    }

    // MARK: - Entry point

    public func perform(_ request: ComputerRequest) async -> ComputerReply {
        if request.action == "list_apps" { return listApps(request.apps) }
        guard let bundleID = request.app, !bundleID.isEmpty else { return .failure("\(request.action) needs `app`, a bundle ID from list_apps.") }
        let acting = request.action == "describe" ? (request.of ?? "") : request.action
        if bundleID == ownBundleID || ComputerPolicy.isNever(bundleID) { return .failure("\(bundleID) cannot be used by an agent.") }
        if ComputerPolicy.isViewOnly(bundleID), !["screenshot", "open_app"].contains(acting) {
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
        default: return .failure("Unknown action “\(request.action)”.")
        }
    }

    // MARK: - Apps

    private static func running(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    public static func name(of bundleID: String) -> String {
        if let name = running(bundleID)?.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    private func listApps(_ apps: [String]) -> ComputerReply {
        guard !apps.isEmpty else {
            return ComputerReply(ok: true, text: "No apps yet. The person chooses them in this agent's settings in pi², under Computer use.", summary: "Listed apps")
        }
        let lines = apps.map { bundleID -> String in
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            let state = Self.running(bundleID) != nil ? "running" : installed ? "not running" : "not installed"
            let limit = ComputerPolicy.isViewOnly(bundleID) ? ", look only" : ""
            return "\(bundleID) — \(Self.name(of: bundleID)) (\(state)\(limit))"
        }
        return ComputerReply(ok: true, text: "Apps you may use:\n" + lines.joined(separator: "\n"), summary: "Listed apps")
    }

    private func open(_ request: ComputerRequest, bundleID: String) async -> ComputerReply {
        let name = Self.name(of: bundleID)
        var did = "\(name) was already open."
        if let running = Self.running(bundleID) {
            // Running with nothing to see: bring a minimized window back, or ask the app for a new one.
            if Self.accessibilityGranted {
                let app = AXUIElementCreateApplication(running.processIdentifier)
                let windows = AX.children(app, kAXWindowsAttribute)
                let minimized = windows.filter { (AX.value($0, kAXMinimizedAttribute) as? Bool) == true }
                if !windows.isEmpty, minimized.count == windows.count, let first = minimized.first {
                    AX.set(first, kAXMinimizedAttribute, kCFBooleanFalse)
                    did = "Brought \(name)'s window back."
                } else if windows.isEmpty {
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
                if let running = Self.running(bundleID), running.isFinishedLaunching,
                   !Self.accessibilityGranted || !AX.children(AXUIElementCreateApplication(running.processIdentifier), kAXWindowsAttribute).isEmpty { break }
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

    private static func frontWindow(of app: AXUIElement) -> (window: AXUIElement?, minimized: Bool) {
        let usable: (AXUIElement) -> Bool = { (AX.value($0, kAXMinimizedAttribute) as? Bool) != true && AX.role($0) == "AXWindow" }
        if let focused = AX.element(app, kAXFocusedWindowAttribute), usable(focused) { return (focused, false) }
        if let main = AX.element(app, kAXMainWindowAttribute), usable(main) { return (main, false) }
        let windows = AX.children(app, kAXWindowsAttribute)
        if let first = windows.first(where: usable) { return (first, false) }
        return (nil, !windows.isEmpty)
    }

    /// The window server's number for the window at `frame`. Needs no permission, and clicks carry it.
    private static func windowID(pid: pid_t, frame: CGRect) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: (id: CGWindowID, distance: CGFloat)?
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat], let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            let distance = abs(rect.minX - frame.minX) + abs(rect.minY - frame.minY) + abs(rect.width - frame.width) + abs(rect.height - frame.height)
            if distance < (best?.distance ?? 12) { best = (id, distance) }
        }
        return best?.id
    }

    /// Read the front window and answer with it. `did` is what just happened, said first.
    private func look(_ request: ComputerRequest, running: NSRunningApplication, bundleID: String, did: String?, summary: String) async -> ComputerReply {
        let name = running.localizedName ?? Self.name(of: bundleID)
        let pid = running.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        let prefix = did.map { $0 + "\n\n" } ?? ""
        let front = Self.frontWindow(of: app)
        guard let window = front.window, let frame = AX.frame(window), frame.width > 1 else {
            views[key(request, bundleID)] = nil
            let why = front.minimized ? "\(name)'s window is minimized. Use open_app to bring it back." : "\(name) has no open window. Use open_app, or its menu, to open one."
            return ComputerReply(ok: did != nil, text: prefix + why, summary: summary)
        }
        var reader = WindowReader(windowFrame: frame)
        reader.read(window)

        let windowID = Self.windowID(pid: pid, frame: frame)
        var shot: WindowCapture.Shot?
        var noPicture: String?
        if !request.image {
            noPicture = nil // the model cannot see pictures; the list and the text are its view
        } else if !WindowCapture.permitted {
            noPicture = "No picture: pi² has no Screen Recording permission (the person can grant it in this agent's settings). The list below still works."
        } else if let target = await WindowCapture.window(pid: pid, frame: frame) {
            shot = await WindowCapture.capture(target, frame: frame)
            if shot == nil { noPicture = "No picture: the window could not be captured this time. The list below still works." }
        } else {
            noPicture = "No picture: the window could not be found for capture. The list below still works."
        }
        let scale = shot?.scale ?? 1
        views[key(request, bundleID)] = View(pid: pid, app: app, frame: frame, scale: scale, windowID: shot?.windowID ?? windowID, controls: reader.controls)

        let title = AX.string(AX.value(window, kAXTitleAttribute)).map { " — window “\($0.clipped(80))”" } ?? ""
        var lines: [String] = []
        if shot != nil {
            lines.append("\(name)\(title), \(Int((frame.width * scale).rounded()))×\(Int((frame.height * scale).rounded())) pixels.")
        } else {
            lines.append("\(name)\(title).")
            if let noPicture { lines.append(noPicture) }
        }
        if reader.controls.isEmpty {
            lines.append("No controls could be read from this window. Use x and y in the picture, or the menu.")
        } else {
            lines.append("Controls (these numbers are for this view only):")
            for (index, control) in reader.controls.enumerated() {
                var line = "[\(index + 1)] \(control.kind)"
                if let label = control.label { line += " “\(label.clipped(70))”" }
                if let value = control.value, value != control.label { line += ", value “\(value.clipped(80))”" }
                let x = Int(((control.frame.midX - frame.minX) * scale).rounded()), y = Int(((control.frame.midY - frame.minY) * scale).rounded())
                line += " (\(x),\(y))"
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
        return ComputerReply(ok: true, text: prefix + lines.joined(separator: "\n"), summary: summary, jpeg: shot?.jpeg)
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
        guard AX.value(control.element, kAXRoleAttribute) != nil else {
            return .failure(.failure("Control \(number) is no longer there; the window has changed. Take a screenshot to see it as it is now."))
        }
        return .success(control)
    }

    private func screenPoint(_ request: ComputerRequest, in view: View) -> Result<CGPoint, ComputerReply> {
        guard let x = request.x, let y = request.y else { return .failure(.failure("Give `element`, or both `x` and `y`.")) }
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
            } else if AX.actions(control.element).contains(kAXPressAction), AX.perform(control.element, kAXPressAction) {
                did = "Clicked \(control.phrase)."
            } else {
                Input.click(pid: view.pid, at: centre, windowID: view.windowID, count: 1)
                did = "Clicked \(control.phrase)."
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
                if reply.ok, signature(request, bundleID) == before {
                    reply.text = did + " Nothing in the window appears to have changed: this app may ignore clicks at a point while it is in the background. Use a listed control, the menu, or keys instead.\n\n" + reply.text.dropFirst(did.count).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return reply
            }
        }
        try? await Task.sleep(for: .milliseconds(450))
        return await look(request, running: running, bundleID: bundleID, did: did, summary: "\(count == 2 ? "Double-clicked" : "Clicked") \(what) in \(name)")
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
        Input.press(pid: running.processIdentifier, combo)
        try? await Task.sleep(for: .milliseconds(450))
        let name = running.localizedName ?? bundleID
        return await look(request, running: running, bundleID: bundleID, did: "Pressed \(combo.display).", summary: "Pressed \(combo.display) in \(name)")
    }

    /// The scrolling area an element sits in.
    private static func scrollArea(containing element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let candidate = current else { return nil }
            if AX.role(candidate) == "AXScrollArea" { return candidate }
            current = AX.parent(candidate)
        }
        return nil
    }

    /// The largest scrolling area in a window: what "scroll the window" means.
    private static func mainScrollArea(in window: AXUIElement) -> AXUIElement? {
        var queue = [window]
        var best: (AXUIElement, CGFloat)?
        var visited = 0
        while !queue.isEmpty, visited < 1200 {
            let element = queue.removeFirst()
            visited += 1
            if AX.role(element) == "AXScrollArea", let frame = AX.frame(element) {
                let area = frame.width * frame.height
                if area > (best?.1 ?? 0) { best = (element, area) }
                continue // areas nested inside are smaller
            }
            queue += AX.children(element)
        }
        return best?.0
    }

    private func scroll(_ request: ComputerRequest, running: NSRunningApplication, bundleID: String) async -> ComputerReply {
        guard let pages = request.dy, pages != 0 else { return .failure("scroll needs `dy`: pages to scroll, positive for down.") }
        guard let view = view(request, bundleID, running: running) else { return .failure(Self.lookFirst) }
        var area: AXUIElement?
        var point = CGPoint(x: view.frame.midX, y: view.frame.midY)
        if let number = request.element {
            switch control(number, in: view) {
            case .success(let found):
                area = Self.scrollArea(containing: found.element)
                point = CGPoint(x: found.frame.midX, y: found.frame.midY)
            case .failure(let reply): return reply
            }
        } else if request.x != nil || request.y != nil {
            switch screenPoint(request, in: view) {
            case .success(let found):
                point = found
                area = AX.hitTest(view.app, found).flatMap(Self.scrollArea(containing:))
            case .failure(let reply): return reply
            }
        } else if let window = Self.frontWindow(of: view.app).window {
            area = Self.mainScrollArea(in: window)
            if let frame = area.flatMap(AX.frame) { point = CGPoint(x: frame.midX, y: frame.midY) }
        }
        let steps = min(abs(pages), 10)
        var moved = false
        if let area, let bar = AX.element(area, kAXVerticalScrollBarAttribute) {
            // The scroll bar's own page buttons do exactly what a person's click there does, front or back.
            let wanted = pages > 0 ? "AXIncrementPage" : "AXDecrementPage"
            if let button = AX.children(bar).first(where: { (AX.value($0, kAXSubroleAttribute) as? String) == wanted }) {
                for _ in 0..<steps {
                    moved = AX.perform(button, kAXPressAction) || moved
                    try? await Task.sleep(for: .milliseconds(70))
                }
            }
            if !moved, let value = AX.value(bar, kAXValueAttribute) as? NSNumber, AX.settable(bar, kAXValueAttribute) {
                let next = max(0, min(1, value.doubleValue + (pages > 0 ? 0.15 : -0.15) * Double(steps)))
                moved = AX.set(bar, kAXValueAttribute, NSNumber(value: next))
            }
        }
        if !moved { Input.scroll(pid: view.pid, at: point, lines: (pages > 0 ? 12 : -12) * steps) }
        try? await Task.sleep(for: .milliseconds(350))
        let direction = pages > 0 ? "down" : "up"
        let name = running.localizedName ?? bundleID
        return await look(request, running: running, bundleID: bundleID, did: "Scrolled \(direction) \(steps) page\(steps == 1 ? "" : "s").", summary: "Scrolled \(direction) in \(name)")
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
            let pages = abs(request.dy ?? 1)
            return "Scroll \((request.dy ?? 1) < 0 ? "up" : "down") \(pages) page\(pages == 1 ? "" : "s") in \(name)"
        case "menu":
            return "Choose \(Self.menuParts(request.path ?? "").joined(separator: " > ")) from \(name)’s menu"
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
