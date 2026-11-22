import AppKit
import BrowserKit
import ComputerKit
import PiModels
import SwiftUI
import UniformTypeIdentifiers
import WindowKit

/// A computer action as the engine sends it.
struct ComputerEvent: Decodable {
    let requestId: String
    let action: String
    let of: String?
    let app: String?
    let apps: [String]?
    /// The agent allows everything: any app, browsers controllable.
    let anyApp: Bool?
    let element: Int?
    let x: Double?
    let y: Double?
    let text: String?
    let dy: Int?
    let count: Int?
    let path: String?
    let image: Bool?
    let conversationId: Int
    let agentName: String?
    /// Sent by the engine only for an agent allowed test copies of pi².
    let testCopies: Bool?
}

/// Carries out what agents ask of other apps' windows, and shows the person that it is happening.
///
/// The engine decides what is allowed and asks for approval; this does the seeing and the clicking, because macOS
/// gives the permissions for those to the app. The hard limits (no terminals, no password managers, browsers look
/// only) are checked again in ComputerKit, whatever the engine sends.
@MainActor
final class ComputerSession {
    private let controller = ComputerController()
    private let indicator = ComputerIndicator()

    func handle(_ event: ComputerEvent, engine: EngineClient) {
        let request = ComputerRequest(
            action: event.action, of: event.of, app: event.app, apps: event.apps ?? [], anyApp: event.anyApp ?? false, element: event.element, x: event.x, y: event.y,
            text: event.text, dy: event.dy, count: event.count, path: event.path, image: event.image ?? true, conversationId: event.conversationId,
            testCopies: event.testCopies ?? false
        )
        // Describing an action for approval and listing apps touch nothing, so they are not announced.
        let acts = !["describe", "list_apps"].contains(event.action)
        if acts, let app = event.app {
            let root = engine.conversations.first { $0.id == event.conversationId }?.parent ?? event.conversationId
            indicator.show(agent: event.agentName ?? "An agent", app: ComputerController.name(of: app), report: { [weak engine] in engine?.note($0) }) { [weak engine] in
                engine?.perform("abort", ["id": root])
            }
        }
        Task {
            let reply = await controller.perform(request)
            var params: [String: Any] = ["requestId": event.requestId, "ok": reply.ok, "text": reply.text]
            if let summary = reply.summary { params["summary"] = summary }
            if let jpeg = reply.jpeg { params["image"] = ["data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"] }
            // If the engine has gone there is nobody to tell; it ends the call itself when the app disconnects.
            _ = try? await engine.call("computer.result", params)
            if acts { indicator.rest() }
        }
    }
}

// MARK: - Indicator

/// A small pill at the top of the screen while an agent is working another app or a web page, with the way to stop it.
/// Pressing Esc twice does the same from anywhere.
@MainActor
final class ComputerIndicator {
    private let panel: IndicatorPanel
    private var hide: Task<Void, Never>?
    private var monitors: [Any] = []
    private var lastEscape = Date.distantPast
    private var stop: () -> Void = {}
    init(row: Int = 0) {
        panel = IndicatorPanel(row: row)
    }

    /// `doing` is what joins the agent to the thing it works ("Atlas is using Notes"); `reveal`, when given, puts a
    /// Show button on the pill.
    func show(agent: String, app: String, doing: String = "is using", reveal: (() -> Void)? = nil, report: @escaping @MainActor (String) -> Void, stop: @escaping () -> Void) {
        hide?.cancel()
        self.stop = stop
        panel.show(agent: agent, app: app, doing: doing, reveal: reveal, report: report) { [weak self] in self?.stopNow() }
        watchEscape()
    }

    /// The action finished; stay up a moment in case the next follows, then go.
    func rest() {
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        panel.dismiss()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }

    private func stopNow() {
        stop()
        dismiss()
    }

    private func watchEscape() {
        guard monitors.isEmpty else { return }
        let pressed: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if Date().timeIntervalSince(self.lastEscape) < 0.6 { self.stopNow() }
                self.lastEscape = Date()
            }
        }
        // Keys typed in other apps (needs the Accessibility permission the agent's actions need anyway), and in pi².
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: pressed) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { pressed($0); return $0 }) { monitors.append(local) }
    }
}

// MARK: - Agent settings

/// The part of an agent's settings that lets it use apps on this Mac.
struct ComputerUseSection: View {
    @Binding var settings: ComputerSettings
    /// The agent allows everything: any app, not only those listed, and browsers can be controlled.
    var allowsEverything = false
    @State private var refused: String?

    var body: some View {
        Section {
            Toggle("Let this agent use apps on this Mac", isOn: $settings.enabled)
            if settings.enabled {
                ForEach(settings.apps, id: \.self) { bundleID in
                    HStack(spacing: 9) {
                        Image(nsImage: Self.icon(for: bundleID)).resizable().frame(width: 22, height: 22).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ComputerController.name(of: bundleID))
                            Text(bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if ComputerPolicy.isViewOnly(bundleID, anyApp: allowsEverything) {
                            Tag("look only").help("The agent can see this app's windows but not click or type in them.")
                        }
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { settings.apps.removeAll { $0 == bundleID } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Remove \(ComputerController.name(of: bundleID))")
                    }
                }
                HStack {
                    Button("Add Apps…") { add() }
                    if allowsEverything {
                        Text("Allow everything is on, so the agent may use any app, listed here or not.").foregroundStyle(Theme.bad)
                    } else if settings.apps.isEmpty, settings.testCopies != true {
                        Text("Until you add an app, the agent is not given computer use at all.").foregroundStyle(.secondary)
                    }
                }
                if let refused { Text(refused).font(.callout).foregroundStyle(Theme.warn) }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Test copies of pi²", isOn: Binding(get: { settings.testCopies ?? false }, set: { settings.testCopies = $0 }))
                    Text("For work on pi² itself: the agent may also click, type and choose menu commands in the throwaway copies scripts/test-copy starts (dev.pi2.app.test…), without adding each one. pi² checks that each is such a copy of a development build; this pi², release builds and other apps are not covered. A copy runs commands for its own agents, so acting in one is close to running a command. Needs Accessibility for pi² below; the copies need nothing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Ask before each action", isOn: $settings.ask)
                // Permissions belong to macOS; this only shows where they stand and opens the way to grant them.
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    permission(
                        "Accessibility", granted: ComputerController.accessibilityGranted,
                        detail: "Needed to read and work the apps’ buttons and fields.",
                        pane: "Privacy_Accessibility", request: ComputerController.requestAccessibility
                    )
                    permission(
                        "Screen Recording", granted: ComputerController.screenRecordingGranted,
                        detail: "For pictures of the window. Optional: without it the agent works from the list of controls.",
                        pane: "Privacy_ScreenCapture", request: ComputerController.requestScreenRecording
                    )
                }
            }
        } header: {
            Text("Computer use")
        } footer: {
            Text(footer).formFooter()
        }
    }

    private var footer: String {
        guard settings.enabled else { return "Off: this agent cannot see or control any app." }
        var text: String
        if allowsEverything {
            let copies = settings.testCopies == true ? "copies of pi² other than test copies" : "copies of pi²"
            text = "Allow everything is on: the agent works in any app, one window at a time, in the background, and acts without asking. Whatever those windows show is sent to its model. Browsers can be controlled, with the accounts you are signed in to there. Terminals, password managers and pi² itself still cannot be used, and System Settings and \(copies) can only be looked at."
        } else {
            text = "The agent works one app window at a time, in the background, and only in the apps listed. Whatever those windows show is sent to its model. "
            text += settings.ask
                ? "It asks before each click, keystroke or menu command; you can allow an app for the rest of a conversation. Looking is not asked about. "
                : "It acts without asking. "
            text += settings.testCopies == true
                ? "Terminals, password managers and pi² itself cannot be added; browsers, System Settings and copies of pi² other than test copies can be looked at but not controlled."
                : "Terminals, password managers and pi² itself cannot be added; browsers, System Settings and test copies of pi² can be looked at but not controlled."
        }
        if !EngineClient.isSelfContained {
            text += " This is a development build: macOS ties these permissions to the exact build, so after rebuilding you may need to remove pi² from the list in System Settings and grant it again."
        }
        return text
    }

    private func permission(_ name: String, granted: Bool, detail: String, pane: String, request: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? Theme.ok : Theme.warn)
                .accessibilityLabel(granted ? "Granted" : "Not granted")
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(granted ? "Granted" : detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…") {
                    request()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
                }
                .help("Opens System Settings, where you switch pi² on. pi² may need to be reopened afterwards.")
            }
        }
    }

    private func add() {
        guard let urls = FilePanels.open("computer-apps", selecting: .files, multiple: true, configure: { panel in
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.applicationBundle]
            panel.prompt = "Add"
            panel.message = "Choose the apps this agent may use."
        }) else { return }
        var turnedAway: [String] = []
        for url in urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            if ComputerPolicy.isNever(bundleID) || ComputerPolicy.same(bundleID, Bundle.main.bundleIdentifier) {
                turnedAway.append(name)
            } else if !settings.apps.contains(where: { ComputerPolicy.same($0, bundleID) }) {
                settings.apps.append(bundleID)
            }
        }
        refused = turnedAway.isEmpty ? nil : "\(ListFormatter.localizedString(byJoining: turnedAway)) cannot be given to an agent: typing there runs commands, it holds your passwords, or it is pi² itself."
    }

    private static func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

// MARK: - Pictures in the transcript

/// A picture kept with a transcript entry (a screenshot an agent took, or a picture the person attached), fetched
/// from the engine when it is first shown.
struct ScreenshotView: View {
    let engine: EngineClient
    let conversationID: Int
    let entryID: Int
    /// Which of the entry's pictures.
    var index = 0
    /// What the picture is, for the tooltip.
    var caption = "What the agent saw"
    /// And for VoiceOver.
    var label = "Screenshot the agent took"
    /// Set to show the picture as a thumbnail this high, shaped as the picture is, instead of across the row.
    var thumbnailHeight: CGFloat?
    @State private var image: NSImage?
    @State private var failed = false
    @State private var large = false

    @MainActor private static let cache = NSCache<NSString, NSImage>()
    private var key: String { "\(entryID)/\(index)" }

    var body: some View {
        Group {
            if let image {
                framed(Image(nsImage: image).resizable().interpolation(.high).scaledToFit(), image)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line2))
                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { large.toggle() } }
                    .help(large ? "\(caption). Click to shrink." : "\(caption). Click to enlarge.")
                    .accessibilityLabel(label)
            } else if failed {
                Text("The picture could not be loaded.").font(.system(size: 11.5)).foregroundStyle(Theme.tx3)
            } else {
                ProgressView().controlSize(.small).frame(width: thumbnailHeight, height: thumbnailHeight ?? 60)
            }
        }
        .frame(maxWidth: thumbnailHeight == nil ? .infinity : nil, alignment: .leading)
        .task(id: key) { await load() }
    }

    @ViewBuilder
    private func framed(_ picture: some View, _ image: NSImage) -> some View {
        if let thumbnailHeight {
            // Sized outright from the picture's own shape, so a row of thumbnails needs no guessing to lay out.
            let limit = large ? CGSize(width: 560, height: 560) : CGSize(width: thumbnailHeight * 2.4, height: thumbnailHeight)
            let width = max(image.size.width, 1), height = max(image.size.height, 1)
            // A very small picture is shown large enough to click, and no larger.
            let scale = min(limit.width / width, limit.height / height, max(1, 44 / height))
            picture.frame(width: width * scale, height: height * scale)
        } else {
            picture.frame(maxHeight: large ? 640 : 240)
        }
    }

    private func load() async {
        if let cached = Self.cache.object(forKey: key as NSString) {
            image = cached
            return
        }
        guard let result = try? await engine.call("conversation.image", ["id": conversationID, "entryId": entryID, "index": index]),
              let data = result["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }), let loaded = NSImage(data: data) else {
            failed = true
            return
        }
        Self.cache.setObject(loaded, forKey: key as NSString)
        image = loaded
    }
}
