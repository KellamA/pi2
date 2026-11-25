import AppKit
import PiModels
import SwiftUI
import TranscriptKit
import WebKit

/// The scene's names for a presentation's window.
enum PresentationWindowScene {
    static let id = "presentation"
}

/// A presentation's window (docs/design/presenting.md, "The window"): one per presentation, opened by Expand on its card
/// or under Needs you, or brought forward at the version and item asked for (`PresentationWindows`). The frame is pi²'s
/// own and says whose it is: the bar along the top (the agent, the conversation, the version, and for a page whose files
/// it was drawn from and whether it may reach the network) and the strip of items along the bottom are SwiftUI views
/// around the picture or the page, never part of it, and stay in full screen. Every text an agent wrote is drawn as
/// plain text, on one line, cut to a length (`PresentationText`).
///
/// It reads `presented.list` once and follows `conversation.presented`, keeping the conversation open with the engine
/// while it is open, and closes when the conversation is archived or deleted. It is not brought back when pi² opens
/// again (`restorationBehavior(.disabled)`, as the browser and a background command's output are): the main window is
/// what starts the engine, and a presentation is opened again from its card.
struct PresentationWindow: View {
    let app: AppModel
    let ref: PresentationRef
    @State private var model: PresentationWindowModel
    @ObservedObject private var windows = PresentationWindows.shared
    @Environment(\.dismiss) private var dismiss
    @State private var askingNetwork = false

    private var engine: EngineClient { app.engine }

    init(app: AppModel, ref: PresentationRef) {
        self.app = app
        self.ref = ref
        _model = State(initialValue: PresentationWindowModel(ref: ref, feed: Self.feed(app.engine, ref)))
    }

    private static func feed(_ engine: EngineClient, _ ref: PresentationRef) -> PresentationFeed {
        #if PI2_DEVELOPMENT
        if ref.conversationId == PresentationFixture.conversation { return PresentationFixture.feed }
        #endif
        return .engine(engine, conversation: ref.conversation ?? -1, presentation: ref.presentation)
    }

    // MARK: Whose it is

    private var summary: ConversationSummary? {
        ref.conversation.flatMap { id in engine.conversations.first { $0.id == id } }
    }

    private var agent: AgentProfile? { engine.agent(summary?.runsAs ?? summary?.agentId) }

    private var agentName: String {
        #if PI2_DEVELOPMENT
        if ref.conversationId == PresentationFixture.conversation { return PresentationFixture.agent }
        #endif
        let name = PresentationText.plain(agent?.name, limit: PresentationText.agent)
        return name.isEmpty ? "an agent" : name
    }

    private var conversationTitle: String {
        #if PI2_DEVELOPMENT
        if ref.conversationId == PresentationFixture.conversation { return PresentationText.plain(PresentationFixture.conversationTitle, limit: PresentationText.conversation) }
        #endif
        let id = ref.conversation ?? 0
        let title = summary?.title ?? engine.archived.first { $0.id == id }?.title
        let plain = PresentationText.plain(title, limit: PresentationText.conversation)
        return plain.isEmpty ? "conversation \(ref.conversationId)" : plain
    }

    private var projectName: String? {
        guard let project = summary?.projectId.flatMap(engine.project) else { return nil }
        let name = PresentationText.plain(project.name, limit: PresentationText.conversation)
        return name.isEmpty ? nil : name
    }

    /// The window's title, as Mission Control and the Window menu list it: the presentation's title and whose it is.
    private var windowTitle: String {
        let title = PresentationText.plain(model.version?.title, limit: PresentationText.title)
        return "\(title.isEmpty ? "Presentation" : title) — Mockup by \(agentName)"
    }

    var body: some View {
        VStack(spacing: 0) {
            PresentationBar(model: model, agent: agent, agentName: agentName, conversation: conversationTitle, project: projectName) {
                askingNetwork = true
            }
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.stripShown, model.items.count > 0 {
                PresentationStrip(model: model)
            }
        }
        .background(Theme.window)
        .navigationTitle(windowTitle)
        .background { PresentationKeys(model: model) }
        .task {
            await model.run(asked: windows.asked[ref])
        }
        // The engine sends `conversation.presented` only to a connection that has the conversation open, so the window
        // keeps it open for as long as it is: asked for again well within the two minutes after which the app lets an
        // unseen conversation go. Only its newest entries, unless something else shows it whole.
        .task(id: ref) {
            guard let id = ref.conversation else { return }
            while !Task.isCancelled {
                engine.openConversation(id, tail: true)
                try? await Task.sleep(for: .seconds(45))
            }
        }
        .onChange(of: windows.asked[ref]) { _, asked in
            if let asked { model.apply(asked) }
        }
        // After the engine has started again, what it sent meanwhile was missed: read the list again.
        .onChange(of: engine.status) { old, status in
            if status == .connected, old != .connected { Task { await model.reload(asked: nil) } }
        }
        // It closes with the conversation's archiving or deletion: one listed that leaves the library, or one in the
        // Archive that leaves it without coming back to the library.
        .onChange(of: engine.conversations.map(\.id)) { old, listed in
            guard let id = ref.conversation, engine.hasLoadedLibrary, old.contains(id), !listed.contains(id) else { return }
            dismiss()
        }
        .onChange(of: engine.archived.map(\.id)) { old, archived in
            guard let id = ref.conversation, engine.hasLoadedLibrary, old.contains(id), !archived.contains(id),
                  !engine.conversations.contains(where: { $0.id == id }) else { return }
            dismiss()
        }
        .onDisappear { model.close() }
        .alert("Allow network for this page?", isPresented: $askingNetwork) {
            Button("Allow Network") { Task { await model.setNetwork(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: networkMeaning)
        }
    }

    /// What allowing the network means, said before it is allowed.
    private var networkMeaning: String {
        let number = model.place.map { "version \($0.0)" } ?? "this version"
        return "The page, which \(agentName) wrote, can then load from and send to any address on the internet: pictures, fonts and scripts from other sites, and whatever it is shown or you type into it. It still cannot reach this Mac or your local network, leave this window, open others, or ask for your files, camera, microphone or location.\n\nIt is for \(number) alone: a newer version \(agentName) presents starts with the network off again."
    }

    @ViewBuilder
    private var stage: some View {
        if !model.loaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let problem = model.problem {
            PresentationNote(text: problem)
        } else if let current = model.current, let key = model.key {
            switch current.kind {
            case .picture: pictureStage(current, key)
            case .page: pageStage
            }
        } else {
            PresentationNote(text: "This version has nothing to show.")
        }
    }

    @ViewBuilder
    private func pictureStage(_ item: PresentedItem, _ key: PresentationWindowModel.ItemKey) -> some View {
        Group {
            if let image = model.pictures[key] {
                PictureStage(image: image, pixels: pixels(item), zoom: $model.zoom, background: model.background) { model.magnification = $0 }
            } else if let problem = model.pictureProblems[key] {
                PresentationNote(text: problem)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: key) { await model.load(key) }
    }

    private func pixels(_ item: PresentedItem) -> CGSize? {
        guard let width = item.width, let height = item.height, width > 0, height > 0, item.mimeType != "image/svg+xml" else { return nil }
        return CGSize(width: width, height: height)
    }

    @ViewBuilder
    private var pageStage: some View {
        ZStack(alignment: .bottom) {
            if let view = model.pageView {
                PageStage(view: view, width: model.width)
                    .background(Theme.card)
                    // A seam of pi²'s accent between the window's frame and the page, so that a page that draws a bar
                    // like the window's own still sits visibly below it.
                    .overlay(alignment: .top) { Rectangle().fill(Theme.acc.opacity(0.55)).frame(height: 2) }
            } else if let problem = model.pageProblem {
                PresentationNote(text: problem)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // pi²'s own notes about the page, over its area but drawn by the window.
            if model.pageStopped {
                PresentationToast(text: "The page stopped working twice, so it is not drawn again by itself. Reload draws it again.")
            } else if let link = model.blockedLink {
                PresentationToast(text: "Blocked a link to \(link): a presented page does not leave its window.")
            }
        }
    }
}

/// The bar along the top: whose it is, which version, and the stage's controls. Drawn by pi², above the page's area.
private struct PresentationBar: View {
    let model: PresentationWindowModel
    let agent: AgentProfile?
    let agentName: String
    let conversation: String
    let project: String?
    let askNetwork: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatar(agent: agent, size: 20)
            who
                .layoutPriority(-1)
            Spacer(minLength: 8)
            versions
            Spacer(minLength: 8)
            tools
            Button { model.stripShown.toggle() } label: { Image(systemName: "rectangle.bottomthird.inset.filled") }
                .buttonStyle(BarButtonStyle(on: model.stripShown))
                .help(model.stripShown ? "Hide the strip of items (⌥⌘S)" : "Show the strip of items (⌥⌘S)")
                .accessibilityLabel(model.stripShown ? "Hide the strip" : "Show the strip")
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line2).frame(height: 1) }
    }

    /// "Mockup by Forge · Sign-in screen · pi2 · Drawn from Forge's files · network off", each part its own text.
    private var who: some View {
        HStack(spacing: 5) {
            Text(verbatim: "Mockup by \(agentName)").fontWeight(.semibold).foregroundStyle(Theme.tx).lineLimit(1).fixedSize()
            Text(verbatim: "·").foregroundStyle(Theme.tx3)
            // In quotation marks: a name someone gave, never one of the bar's own words.
            Text(verbatim: "“\(conversation)”").foregroundStyle(Theme.tx2).lineLimit(1).truncationMode(.middle)
            if let project {
                Text(verbatim: "·").foregroundStyle(Theme.tx3)
                Text(verbatim: project).foregroundStyle(Theme.tx2).lineLimit(1).truncationMode(.tail)
            }
            if let current = model.current {
                Text(verbatim: "·").foregroundStyle(Theme.tx3)
                if current.kind == .page {
                    Text(verbatim: "Drawn from \(agentName)’s files").foregroundStyle(Theme.tx2).lineLimit(1).fixedSize()
                } else {
                    Text(verbatim: "A picture \(agentName) made").foregroundStyle(Theme.tx2).lineLimit(1).fixedSize()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var versions: some View {
        HStack(spacing: 2) {
            Button { model.step(version: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(BarButtonStyle())
                .disabled((model.place?.0 ?? 1) <= 1)
                .help("The version before (⌘[)")
                .accessibilityLabel("Previous version")
            Text(verbatim: model.place.map { "Version \($0.0) of \($0.1)" } ?? "Version")
                .fontWeight(.medium).foregroundStyle(Theme.tx).monospacedDigit().fixedSize()
                .padding(.horizontal, 4)
            Button { model.step(version: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(BarButtonStyle())
                .disabled(model.place.map { $0.0 >= $0.1 } ?? true)
                .help("The version after (⌘])")
                .accessibilityLabel("Next version")
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .fixedSize()
    }

    @ViewBuilder
    private var tools: some View {
        if model.current?.kind == .page {
            pageTools
        } else if model.current?.kind == .picture {
            pictureTools
        }
    }

    private var pageTools: some View {
        HStack(spacing: 6) {
            Segmented(choices: PageWidth.allCases, chosen: model.width, label: widthLabel, help: widthHelp) { model.width = $0 }
            Button { model.reloadPage() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(BarButtonStyle())
                .help("Draw the page again from its copy (⌘R)")
                .accessibilityLabel("Reload")
            network
        }
    }

    private func widthLabel(_ width: PageWidth) -> Text { Text(verbatim: width.rawValue) }

    private func widthHelp(_ width: PageWidth) -> String {
        guard let points = width.points else { return "Draw the page as wide as the window" }
        return "Draw the page \(Int(points)) points wide"
    }

    private var pictureTools: some View {
        HStack(spacing: 6) {
            Segmented(choices: [PictureZoom.fit, PictureZoom.actual], chosen: model.zoom, label: zoomLabel, help: zoomHelp) { model.zoom = $0 }
            Button { model.zoom = .scale(model.magnification / 1.25) } label: { Image(systemName: "minus") }
                .buttonStyle(BarButtonStyle()).help("Zoom out (⌘−)").accessibilityLabel("Zoom out")
            Button { model.zoom = .scale(model.magnification * 1.25) } label: { Image(systemName: "plus") }
                .buttonStyle(BarButtonStyle()).help("Zoom in (⌘+)").accessibilityLabel("Zoom in")
            Segmented(choices: PictureBackground.allCases, chosen: model.background, label: backgroundLabel, help: backgroundHelp) { model.background = $0 }
        }
    }

    private func zoomLabel(_ zoom: PictureZoom) -> Text { Text(verbatim: zoom == .fit ? "Fit" : "100%") }
    private func zoomHelp(_ zoom: PictureZoom) -> String { zoom == .fit ? "Fit the picture to the window (⌘0)" : "Show it at its actual size (⌘1)" }

    private func backgroundLabel(_ background: PictureBackground) -> Image {
        switch background {
        case .light: Image(systemName: "sun.max")
        case .dark: Image(systemName: "moon")
        case .chequered: Image(systemName: "checkerboard.rectangle")
        }
    }

    private func backgroundHelp(_ background: PictureBackground) -> String { "A \(background.rawValue) background behind the picture" }

    /// The network's state, said plainly, and the switch. Allowing it asks first; turning it off does not.
    private var network: some View {
        let on = model.networkAllowed
        return Button {
            if on { Task { await model.setNetwork(false) } } else { askNetwork() }
        } label: {
            Label(on ? "Network on" : "Network off", systemImage: on ? "network" : "network.slash")
                .font(.system(size: 12, weight: on ? .semibold : .regular))
        }
        .buttonStyle(NetworkButtonStyle(on: on))
        .help(on ? "This version's page can reach the internet. Click to turn it off." : "This page cannot reach the network. Click to allow it, for this version alone, after saying what that means.")
    }
}

/// A row of choices in the bar, one of them on, as the mockup's segmented controls.
private struct Segmented<Choice: Hashable, Label: View>: View {
    let choices: [Choice]
    let chosen: Choice
    let label: (Choice) -> Label
    let help: (Choice) -> String
    let choose: (Choice) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.self) { choice in
                Button { choose(choice) } label: {
                    label(choice)
                        .font(.system(size: 12))
                        .frame(minWidth: 26, minHeight: 22)
                        .padding(.horizontal, 6)
                        .foregroundStyle(choice == chosen ? Theme.tx : Theme.tx2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(choice == chosen ? Theme.card2 : .clear)
                            .shadow(color: .black.opacity(choice == chosen ? 0.18 : 0), radius: 1, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(choice))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
        .fixedSize()
    }
}

private struct BarButtonStyle: ButtonStyle {
    var on = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(on ? Theme.acc : Theme.tx2)
            .frame(width: 26, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Theme.card2 : .clear))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.35)
    }
}

private struct NetworkButtonStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(on ? Theme.warn : Theme.tx2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.warn.opacity(0.14) : (configuration.isPressed ? Theme.card2 : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Theme.warn.opacity(0.6) : Theme.line2, lineWidth: 1))
            .contentShape(Rectangle())
            .fixedSize()
    }
}

/// The strip of items along the bottom, with their labels and captions; it folds away with ⌥⌘S.
private struct PresentationStrip: View {
    let model: PresentationWindowModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                            PresentationThumb(model: model, index: index, item: item, on: index == model.item)
                                .id(index)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: model.item) { _, item in withAnimation { scroller.scrollTo(item) } }
            }
            Text(verbatim: model.items.count > 1 ? "← → between items · ⌥⌘S hides the strip" : "⌥⌘S hides the strip")
                .font(.system(size: 11)).foregroundStyle(Theme.tx3)
                .fixedSize()
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(height: 112)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line2).frame(height: 1) }
    }
}

private struct PresentationThumb: View {
    let model: PresentationWindowModel
    let index: Int
    let item: PresentedItem
    let on: Bool

    private var key: PresentationWindowModel.ItemKey? {
        model.version.map { .init(version: $0.version, item: index) }
    }

    var body: some View {
        Button { model.select(index) } label: {
            HStack(spacing: 9) {
                mini
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: label).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.tx).lineLimit(1)
                    if !caption.isEmpty {
                        Text(verbatim: caption).font(.system(size: 11.5)).foregroundStyle(Theme.tx2).lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(5)
            .frame(width: 280, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Theme.acc.opacity(0.10) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Theme.acc : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(PresentationText.plain(item.name, limit: 300))
        .task(id: "\(key.map { "\($0.version)-\($0.item)" } ?? "")-\(item.snapshot?.isDrawn == true)") {
            if let key { await model.load(key) }
        }
    }

    private var label: String {
        let label = PresentationText.plain(item.label, limit: PresentationText.label)
        if item.kind == .page { return label.isEmpty || label == "Page" ? "Page" : "\(label) · Page" }
        return label.isEmpty ? "Picture \(index + 1)" : label
    }

    private var caption: String { PresentationText.plain(item.caption, limit: PresentationText.caption) }

    private var mini: some View {
        ZStack {
            Theme.card
            if let key, let image = model.pictures[key] {
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.kind == .page ? "doc.richtext" : "photo").foregroundStyle(Theme.tx3)
            }
        }
        .frame(width: 120, height: 75)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
    }
}

/// A line of pi²'s own in the middle of the stage: why there is nothing to show.
private struct PresentationNote: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(.callout).foregroundStyle(Theme.tx2).multilineTextAlignment(.center)
            .padding(30).frame(maxWidth: 520).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A note of pi²'s own over the bottom of the page's area, such as a link it stopped.
private struct PresentationToast: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(.system(size: 12)).foregroundStyle(Theme.tx2)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel).shadow(color: .black.opacity(0.2), radius: 7, y: 4))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line2, lineWidth: 1))
            .padding(.bottom, 14)
    }
}

/// The window's keys: ← → between items, ⌘[ ⌘] between versions, ⌘0 ⌘1 ⌘+ ⌘− for a picture, ⌘R for a page, ⌥⌘S for
/// the strip. Full screen is the window's own (the green button, ⌃⌘F). They are taken from the window's key events
/// before its views see them, since a page's web view would otherwise keep ⌘[ and ⌘] (back and forward) and the arrows
/// for itself; but while the page has the keyboard (the person clicked into it, to type in a mockup's field), ← → are
/// the page's, and the strip or ⌘[ ⌘] still move.
private struct PresentationKeys: NSViewRepresentable {
    let model: PresentationWindowModel

    func makeNSView(context: Context) -> KeyTaker {
        let view = KeyTaker()
        view.model = model
        return view
    }

    func updateNSView(_ view: KeyTaker, context: Context) {
        view.model = model
    }

    static func dismantleNSView(_ view: KeyTaker, coordinator: ()) {
        view.stop()
    }

    final class KeyTaker: NSView {
        var model: PresentationWindowModel?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let window = event.window
                let taken = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let own = self.window, window === own else { return false }
                    return self.take(event, in: own)
                }
                return taken ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Whether the event was one of the window's keys, and was done.
        private func take(_ event: NSEvent, in window: NSWindow) -> Bool {
            guard let model, window.attachedSheet == nil else { return false }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let key = event.charactersIgnoringModifiers ?? ""
            let picture = model.current?.kind == .picture
            switch (flags, key) {
            case ([], _) where event.keyCode == 123 || event.keyCode == 124:
                // The arrows are the page's or a field's while either has the keyboard.
                if window.firstResponder is WKWebView || window.firstResponder is NSText { return false }
                if (window.firstResponder as? NSView)?.isDescendant(of: model.pageView ?? NSView()) == true { return false }
                model.step(item: event.keyCode == 123 ? -1 : 1)
            case ([.command], "["): model.step(version: -1)
            case ([.command], "]"): model.step(version: 1)
            case ([.command, .option], "s"), ([.command, .option], "ß"): model.stripShown.toggle()
            case ([.command], "0") where picture: model.zoom = .fit
            case ([.command], "1") where picture: model.zoom = .actual
            case ([.command], "="), ([.command], "+"), ([.command, .shift], "="), ([.command, .shift], "+"):
                guard picture else { return false }
                model.zoom = .scale(model.magnification * 1.25)
            case ([.command], "-"):
                guard picture else { return false }
                model.zoom = .scale(model.magnification / 1.25)
            case ([.command], "r") where model.current?.kind == .page: model.reloadPage()
            default: return false
            }
            return true
        }
    }
}

/// Gives `PresentationWindows` its way to open a window, from a view that has the environment to do it; and in a
/// development build opens the window `PI2_SHOW=presentation:…` asks for (`PresentationLaunch`).
struct PresentationWindowOpener: View {
    let engine: EngineClient
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                PresentationWindows.shared.open = { openWindow(id: PresentationWindowScene.id, value: $0) }
            }
            #if PI2_DEVELOPMENT
            .task(id: engine.hasLoadedLibrary) {
                guard engine.hasLoadedLibrary, let asked = PresentationLaunch.take() else { return }
                try? await Task.sleep(for: .seconds(1))
                PresentationWindows.shared.show(asked.ref, version: asked.version, item: asked.item)
            }
            #endif
    }
}
