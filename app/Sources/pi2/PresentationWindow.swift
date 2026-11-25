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
        let model = PresentationWindowModel(ref: ref, feed: Self.feed(app.engine, ref))
        #if PI2_DEVELOPMENT
        model.note = { [engine = app.engine] in engine.note($0) }
        #endif
        _model = State(initialValue: model)
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

    /// The conversation as the Archive lists it, for a window on an archived one.
    private var archived: ArchivedConversation? {
        ref.conversation.flatMap { id in engine.archived.first { $0.id == id } }
    }

    private var agent: AgentProfile? { engine.agent(summary.map { $0.runsAs ?? $0.agentId } ?? archived?.agentId) }

    /// The names in the bar, each someone else's choice: the agent's, the conversation's, the project's.
    private var names: PresentationNames {
        #if PI2_DEVELOPMENT
        if ref.conversationId == PresentationFixture.conversation {
            return PresentationNames(agent: PresentationText.name(PresentationFixture.agent, limit: PresentationText.agent),
                                     conversation: PresentationText.name(PresentationFixture.conversationTitle, limit: PresentationText.conversation),
                                     project: PresentationText.name(PresentationFixture.projectName, limit: PresentationText.project))
        }
        #endif
        let agent = PresentationText.name(agent?.name, limit: PresentationText.agent)
        let conversation = PresentationText.name(summary?.title ?? archived?.title, limit: PresentationText.conversation)
        let project = (summary?.projectId ?? archived?.projectId).flatMap(engine.project).map { PresentationText.name($0.name, limit: PresentationText.project) }
        return PresentationNames(agent: agent.isEmpty ? "An agent" : agent,
                                 conversation: conversation.isEmpty ? "Conversation \(ref.conversationId)" : conversation,
                                 project: project?.isEmpty == false ? project : nil)
    }

    /// The window's title, as Mission Control and the Window menu list it: the presentation's title and whose it is.
    private var windowTitle: String {
        let title = PresentationText.name(model.version?.title, limit: PresentationText.title)
        return "\(title.isEmpty ? "Presentation" : title) — Mockup by \(names.agent)"
    }

    var body: some View {
        VStack(spacing: 0) {
            PresentationBar(model: model, agent: agent, names: names) {
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
        #if PI2_DEVELOPMENT
        .background { if PresentationLaunch.smallest { SmallestWindow() } }
        .task(id: model.pageView != nil) {
            guard PresentationLaunch.networkAlert, model.pageView != nil, !model.networkAllowed else { return }
            try? await Task.sleep(for: .seconds(1))
            askingNetwork = true
        }
        #endif
        .alert("Allow network for this page?", isPresented: $askingNetwork) {
            Button("Allow Network") { Task { await model.setNetwork(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: networkMeaning)
        }
    }

    /// What allowing the network means, said before it is allowed: what the page can then do, and what is not stopped.
    private var networkMeaning: String {
        let number = model.place.map { "version \($0.0)" } ?? "this version"
        return "The page, which an agent wrote, can then load anything from the internet over secure (https) addresses, and send whatever it holds, or whatever you type into it, to any site.\n\nPlain http addresses stay blocked, and so do the addresses of this Mac and your local network as written. A secure address whose name points back at this Mac or your network is not stopped.\n\nIt still cannot leave this window, open others, or ask for your files, camera, microphone or location. It is for \(number) alone: a newer version starts with the network off again."
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
        ZStack(alignment: .bottom) {
            if let shown = model.shown, shown.key == key {
                PictureStage(image: shown.image, pixels: shown.pixels, zoom: $model.zoom, background: model.background) { model.magnification = $0 }
                if shown.smaller, let pixels = shown.pixels {
                    PresentationToast(text: "Shown smaller than its \(Int(pixels.width)) × \(Int(pixels.height)) pixels, to keep memory. 100% (⌘1) shows it at full size.")
                }
            } else if let problem = model.pictureProblems[key] {
                PresentationNote(text: problem)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: key) { await model.show(key) }
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
///
/// pi²'s own statements (the version, where the picture or page came from, the network's state) and the strip's button
/// are never cut or pushed out: each is drawn at its own size, with priority. As the window narrows, what gives way, in
/// this order: the names chip, cut in its middle, down to the agent's badge alone (the names then in its tooltip); then
/// the page's widths, or a picture's zoom and background controls, folding into one menu button. The window's
/// smallest width (`minimumWidth`) is what fits all of pi²'s own parts with both given way, measured by the bar check
/// (`PresentationBarCheck`, a development build's `PI2_SHOW=presentation:bar-check`).
struct PresentationBar: View {
    let model: PresentationWindowModel
    let agent: AgentProfile?
    let names: PresentationNames
    let askNetwork: () -> Void
    /// Where a bar check is told where each of pi²'s own parts was laid out.
    var report: PresentationBarReport?

    /// The window's smallest width, at which the bar still fits all of pi²'s own parts.
    static let minimumWidth: CGFloat = 760
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 12
    static let spacer: CGFloat = 8
    /// The chip with the agent's badge alone, and the least room in which its names are still worth drawing.
    static let badgeWidth: CGFloat = 26
    static let namesWidth: CGFloat = 150

    @State private var barWidth: CGFloat = 0
    @State private var versionWidth: CGFloat = 0
    @State private var fullWidth: CGFloat = 0
    @State private var foldedWidth: CGFloat = 0

    /// The room left for the names chip beside pi²'s own parts and the tools, folded or not.
    private func chipRoom(rightWidth: CGFloat) -> CGFloat {
        barWidth - 2 * Self.padding - versionWidth - rightWidth - 2 * Self.spacer - 4 * Self.spacing
    }

    /// The tools fold once the chip, at its badge alone, would not fit beside them.
    private var folded: Bool { barWidth > 0 && chipRoom(rightWidth: fullWidth) < Self.badgeWidth }
    private var namesShown: Bool { barWidth == 0 || chipRoom(rightWidth: folded ? foldedWidth : fullWidth) >= Self.namesWidth }

    var body: some View {
        HStack(spacing: Self.spacing) {
            PresentationNamesChip(agent: agent, names: names, namesShown: namesShown)
                .frame(minWidth: Self.badgeWidth, alignment: .leading)
                .layoutPriority(-1)
                .reportFrame("names", to: report)
            Spacer(minLength: Self.spacer)
            versions
                .layoutPriority(1)
                .reportFrame("version", to: report)
            Spacer(minLength: Self.spacer)
            right(folded: folded, report: report)
                .fixedSize()
                .layoutPriority(1)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, Self.padding)
        .frame(height: 44)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0; report?.barWidth = $0 }
        // The parts measured at their own sizes, unseen, for deciding what gives way.
        .background {
            ZStack {
                versions.fixedSize().onGeometryChange(for: CGFloat.self) { $0.size.width } action: { versionWidth = $0 }
                right(folded: false, report: nil).fixedSize().onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
                right(folded: true, report: nil).fixedSize().onGeometryChange(for: CGFloat.self) { $0.size.width } action: { foldedWidth = $0 }
            }
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipped()
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line2).frame(height: 1) }
        .onChange(of: folded, initial: true) { _, folded in report?.folded = folded }
        .onChange(of: namesShown, initial: true) { _, shown in report?.namesShown = shown }
    }

    /// The tools, pi²'s statement and the strip's button.
    private func right(folded: Bool, report: PresentationBarReport?) -> some View {
        HStack(spacing: Self.spacing) {
            tools(folded: folded)
            statement(report: report)
            Button { model.stripShown.toggle() } label: { Image(systemName: "rectangle.bottomthird.inset.filled") }
                .buttonStyle(BarButtonStyle(on: model.stripShown))
                .help(model.stripShown ? "Hide the strip of items (⌥⌘S)" : "Show the strip of items (⌥⌘S)")
                .accessibilityLabel(model.stripShown ? "Hide the strip" : "Show the strip")
                .fixedSize()
                .reportFrame("strip", to: report)
        }
    }

    /// Where it came from, and for a page its network: pi²'s own words, with no name in them.
    @ViewBuilder
    private func statement(report: PresentationBarReport?) -> some View {
        if let current = model.current {
            HStack(spacing: 8) {
                Divider().frame(height: 20)
                Label(current.kind == .page ? "Drawn from the agent’s files" : "A picture the agent made",
                      systemImage: current.kind == .page ? "doc.richtext" : "photo")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tx)
                    .lineLimit(1)
                    .fixedSize()
                    .reportFrame("whose", to: report)
                if current.kind == .page {
                    network
                        .fixedSize()
                        .reportFrame("network", to: report)
                }
            }
        }
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
    private func tools(folded: Bool) -> some View {
        if model.current?.kind == .page {
            pageTools(folded: folded)
        } else if model.current?.kind == .picture {
            if folded { pictureMenu } else { pictureTools }
        }
    }

    private func pageTools(folded: Bool) -> some View {
        HStack(spacing: 6) {
            if folded {
                Menu {
                    Picker("Width", selection: Binding(get: { model.width }, set: { model.width = $0 })) {
                        ForEach(PageWidth.allCases, id: \.self) { width in Text(verbatim: width.points.map { "\(width.rawValue), \(Int($0)) points" } ?? "Fit the window").tag(width) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(verbatim: model.width.rawValue).font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .help("The width the page is drawn at")
            } else {
                Segmented(choices: PageWidth.allCases, chosen: model.width, label: widthLabel, help: widthHelp) { model.width = $0 }
            }
            Button { model.reloadPage() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(BarButtonStyle())
                .help("Draw the page again from its copy (⌘R)")
                .accessibilityLabel("Reload")
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

    /// The zoom and background controls folded into one menu, for a narrow window.
    private var pictureMenu: some View {
        Menu {
            Button("Fit (⌘0)") { model.zoom = .fit }
            Button("Actual Size (⌘1)") { model.zoom = .actual }
            Button("Zoom In (⌘+)") { model.zoom = .scale(model.magnification * 1.25) }
            Button("Zoom Out (⌘−)") { model.zoom = .scale(model.magnification / 1.25) }
            Divider()
            Picker("Background", selection: Binding(get: { model.background }, set: { model.background = $0 })) {
                ForEach(PictureBackground.allCases, id: \.self) { background in Text(verbatim: background.rawValue.capitalized).tag(background) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Zoom and background")
        .accessibilityLabel("Zoom and background")
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

    /// The network's state, said plainly, and the switch. Allowing it asks first; turning it off does not. Without the
    /// switch at all (`PresentedPagePolicy.networkCanBeAllowed`), it only says "Network off".
    @ViewBuilder
    private var network: some View {
        let on = model.networkAllowed
        if PresentedPagePolicy.networkCanBeAllowed {
            Button {
                if on { Task { await model.setNetwork(false) } } else { askNetwork() }
            } label: {
                Label(on ? "Network on: https" : "Network off", systemImage: on ? "network" : "network.slash")
                    .font(.system(size: 12, weight: on ? .semibold : .regular))
            }
            .buttonStyle(NetworkButtonStyle(on: on))
            .help(on
                ? "This version's page can load anything from the internet over https, and send what it holds or what you type into it to any site. Addresses of this Mac and your network are blocked as written, but a secure address whose name points back at them is not. Click to turn it off."
                : "This page cannot reach the network. Click to allow it, for this version alone, after reading what that means.")
        } else {
            Label("Network off", systemImage: "network.slash")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tx2)
                .fixedSize()
                .help("This page cannot reach the network.")
        }
    }
}

/// The names in a presentation's bar, already made plain and cut.
struct PresentationNames: Equatable {
    let agent: String
    let conversation: String
    let project: String?
}

/// The names someone else chose, together, drawn as names: the agent's avatar, then its name, the conversation's and the
/// project's, each in the secondary colour and cut in its middle, in a chip of their own. The separators between them
/// are pi²'s own, a small chevron drawn as an image, which no name can contain. With too little room it is the agent's
/// badge alone, and the names are in its tooltip.
private struct PresentationNamesChip: View {
    let agent: AgentProfile?
    let names: PresentationNames
    let namesShown: Bool

    var body: some View {
        HStack(spacing: 6) {
            AgentAvatar(agent: agent, size: 18)
            if namesShown {
                // Each already cut to its own length; with too little room, the conversation's gives way first.
                name(names.agent).layoutPriority(2)
                separator
                name(names.conversation)
                if let project = names.project {
                    separator
                    name(project)
                }
            }
        }
        .font(.system(size: 12))
        .padding(.leading, 3).padding(.trailing, namesShown ? 9 : 3).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .help([names.agent, names.conversation, names.project].compactMap { $0 }.joined(separator: " › "))
    }

    private var separator: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.tx3)
            .accessibilityHidden(true)
    }

    private func name(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(Theme.tx2).lineLimit(1).truncationMode(.middle)
    }
}

/// Where each of pi²'s own parts of a bar was laid out, in its window's space, for the bar check.
@MainActor
final class PresentationBarReport {
    var barWidth: CGFloat = 0
    var frames: [String: CGRect] = [:]
    var folded = false
    var namesShown = true
}

private extension View {
    func reportFrame(_ name: String, to report: PresentationBarReport?) -> some View {
        // In the window's own space: a bar wider than its window would still hold all its parts in its own.
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            report?.frames[name] = frame
        }
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
        .clipped()
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
            .clipped()
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Theme.acc.opacity(0.10) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Theme.acc : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(PresentationText.plain(item.name, limit: 300))
        .task(id: "\(key.map { "\($0.version)-\($0.item)" } ?? "")-\(item.snapshot?.isDrawn == true)") {
            if let key { await model.loadThumbnail(key) }
        }
    }

    private var label: String {
        let label = PresentationText.name(item.label, limit: PresentationText.label)
        if item.kind == .page { return label.isEmpty || label == "Page" ? "Page" : "\(label) · Page" }
        return label.isEmpty ? "Picture \(index + 1)" : label
    }

    private var caption: String { PresentationText.plain(item.caption, limit: PresentationText.caption) }

    private var mini: some View {
        ZStack {
            Theme.card
            if let key, let image = model.thumbnails[key] {
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

/// The window's keys: ⌘W to close, ← → between items, ⌘[ ⌘] between versions, ⌘0 ⌘1 ⌘+ ⌘− for a picture, ⌘R for a page, ⌥⌘S for
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
            // ⌘W closes the window whatever has the keyboard: a page that answers its keydown cannot keep it open.
            case ([.command], "w"): window.performClose(nil)
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
                guard engine.hasLoadedLibrary, PresentationBarCheck.asked else { return }
                try? await Task.sleep(for: .seconds(1))
                await PresentationBarCheck.run(home: engine.dataFolder) { engine.note($0) }
            }
            .task(id: engine.hasLoadedLibrary) {
                guard engine.hasLoadedLibrary, let asked = PresentationLaunch.take() else { return }
                try? await Task.sleep(for: .seconds(1))
                PresentationWindows.shared.show(asked.ref, version: asked.version, item: asked.item)
            }
            #endif
    }
}

#if PI2_DEVELOPMENT
/// Puts its window at its smallest size once, for `PI2_SHOW=presentation:…@min`.
private struct SmallestWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Sizer() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Sizer: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    let top = NSPoint(x: window.frame.minX, y: window.frame.maxY)
                    window.setContentSize(NSSize(width: PresentationBar.minimumWidth, height: 460))
                    window.setFrameTopLeftPoint(top)
                }
            }
        }
    }
}
#endif
