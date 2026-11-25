import EngineKit
import PiModels
import SwiftUI
import TranscriptKit

/// A conversation on its own screen, an orchestrator's or an agent's: the transcript page and the message field
/// (docs/design/iphone.md, "An agent's conversation"; docs/iphone.md P18). Drawn inline in a project's hub too, as its
/// Chat tab, where the hub draws the header.
///
/// The transcript is TranscriptKit's page (`ConversationPage`), which loads nothing from the network and acts through
/// nothing: everything the person does here that reaches the engine is a control of this screen, outside the page
/// (docs/iphone.md section 8), sent through the session's client as the Mac sends it (`ConversationRequests`). The
/// page may only have the client read more of this conversation for it: older entries, and a picture.
struct ConversationView: View {
    /// The conversation's id, as `ConversationSummary.id`.
    let conversationID: Int

    init(conversationID: Int) {
        self.conversationID = conversationID
    }

    @Environment(AppSession.self) private var session
    @Environment(\.placement) private var placement
    @Environment(\.openRoute) private var openRoute
    @Environment(\.openURL) private var openURL
    @State private var steer = true
    @State private var problem: String?
    @State private var link: URL?
    @State private var pageShown = false

    private var engine: EngineSession<MessageField> { session.engine }
    private var data: OpenConversation<MessageField>? { engine.open[conversationID] }
    private var state: ConversationState? { data?.state }
    private var summary: ConversationSummary? { engine.conversations.first { $0.id == conversationID } }
    private var agent: AgentProfile? { engine.agent(state?.agent.agentId ?? summary?.agentId) }
    private var requests: ConversationRequests { ConversationRequests(engine: engine, conversationID: conversationID) }
    private var pictures: ConversationPictures { ConversationPictures.of(conversationID) }

    private var status: ConversationStatus {
        let status = ConversationStatus.make(
            conversationID: conversationID, state: state, agentName: agent?.name, outgoing: engine.outgoing[conversationID] ?? [],
            connected: engine.status == .connected, inbox: engine.inbox, needs: engine.conversationNeeds,
            archivedInLibrary: engine.archived.contains { $0.id == conversationID }, models: engine.allModels
        )
        #if DEBUG
        if let sample = ConversationSample.current { return sample.status(over: status) }
        #endif
        return status
    }

    var body: some View {
        let status = status
        transcript
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ConversationFooter(
                    status: status, draft: data?.draft, pictures: pictures, steer: $steer,
                    connected: engine.status == .connected, problem: $problem,
                    send: send, stop: stop, withdraw: withdraw, carryOn: carryOn, restore: restore,
                    openNeeds: { openRoute(.needs(project: projectID)) }
                )
            }
            .modifier(ConversationChrome(placement: placement, header: header(status)))
            .onAppear {
                engine.openConversation(conversationID)
                ConversationShown.appeared(conversationID, in: engine)
            }
            .onDisappear {
                ConversationShown.disappeared(conversationID, in: engine)
            }
            .alert("Open this link?", isPresented: Binding(get: { link != nil }, set: { if !$0 { link = nil } }), presenting: link) { url in
                Button("Open") { openURL(url) }
                Button("Cancel", role: .cancel) {}
            } message: { url in
                Text("An agent wrote it: \(url.absoluteString)")
            }
            #if DEBUG
            .task { await ConversationSample.current?.act(sending: sendText, pictures: pictures) }
            #endif
    }

    // MARK: The transcript

    @ViewBuilder
    private var transcript: some View {
        if let folder = TranscriptPage.folder {
            if let state, isEmpty(state) {
                ContentUnavailableView {
                    Label("Nothing here yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Write to \(agent?.name ?? "the agent") below. It works on your Mac.")
                }
            } else if notOnTheMac {
                ContentUnavailableView {
                    Label("Not on your Mac", systemImage: "questionmark.bubble")
                } description: {
                    Text("Your Mac has no conversation \(conversationID). It may have been deleted.")
                }
            } else {
                ZStack {
                    if !pageShown {
                        ProgressView("Opening the conversation…")
                            .foregroundStyle(.secondary)
                    }
                    ConversationPage(
                        folder: folder,
                        content: ConversationPageContent(
                            conversationID: conversationID, items: data?.items ?? [], earlier: data?.earlier ?? 0,
                            older: TranscriptFeed.Older(more: data?.more ?? false, loading: data?.loadingOlder ?? false), state: state,
                            names: ConversationNames.page(conversationID: conversationID, state: state, engine: engine)
                        ),
                        onShown: {
                            pageShown = true
                            data?.markShown()
                        },
                        onLink: { link = $0 },
                        onOpenConversation: { openRoute(.conversation($0)) },
                        onFile: { openRoute(.filePreview(conversation: conversationID, path: $0)) },
                        loadOlder: { engine.loadOlder(conversationID) },
                        fetchPicture: { entry, index in await requests.picture(entry: entry, index: index) }
                    )
                    .accessibilityLabel("Conversation")
                }
            }
        } else {
            // A build without the page in its bundle: say so, rather than show an empty screen.
            ContentUnavailableView {
                Label("The conversation page is missing", systemImage: "exclamationmark.triangle")
            } description: {
                Text("This build of pi² does not carry the page that shows conversations.")
            }
        }
    }

    /// Nothing in it yet and nothing on its way.
    private func isEmpty(_ state: ConversationState) -> Bool {
        (data?.items.isEmpty ?? true) && !state.busy && state.partial == nil && engine.outgoing[conversationID] == nil
    }

    /// The engine has sent its list of conversations, and this one is not in it: the client let the request go.
    private var notOnTheMac: Bool {
        engine.hasLoadedLibrary && data == nil && summary == nil && !engine.archived.contains { $0.id == conversationID }
    }

    private var projectID: String? {
        summary?.projectId ?? summary?.parent.flatMap { parent in engine.conversations.first { $0.id == parent }?.projectId }
    }

    private func header(_ status: ConversationStatus) -> ConversationHeader {
        let model = ConversationNames.shortModelName(state?.agent.model ?? agent?.model, engine: engine)
        let project = projectID.flatMap { id in engine.projects.first { $0.id == id }?.name }
        let place = state?.agent.parent != nil ? "sub-chat \(conversationID)" : project ?? summary?.title
        return ConversationHeader(
            name: agent?.name ?? summary?.title ?? state?.title ?? "Conversation \(conversationID)", color: agent?.color,
            subtitle: [model, place].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), busy: status.busy
        )
    }

    // MARK: Requests, from the screen's own controls

    private func send() {
        guard let draft = data?.draft else { return }
        let text = draft.text
        draft.text = ""
        sendText(text)
    }

    private func sendText(_ text: String) {
        let carried = pictures.takeReady()
        let steered = status.busy && steer
        problem = nil
        Task {
            switch await requests.send(text, pictures: carried, steer: steered) {
            case .sent:
                break
            case .refused(let why):
                // A definite refusal: what was written goes back in the field, as on the Mac.
                problem = why
                if let draft = data?.draft, !text.isEmpty {
                    draft.text = draft.text.isEmpty ? text : text + "\n\n" + draft.text
                }
                pictures.restore(carried)
            case .unconfirmed(let why):
                problem = why
            }
        }
    }

    private func stop() {
        Task { if let why = await requests.stop() { problem = why } }
    }

    private func withdraw(_ submission: Int) {
        Task { if let why = await requests.withdraw(submission) { problem = why } }
    }

    private func carryOn() {
        Task { if let why = await requests.carryOn() { problem = why } }
    }

    private func restore(_ root: Int?) {
        Task { if let why = await requests.restore(root ?? conversationID) { problem = why } }
    }
}

/// What only a whole screen has: the header in the navigation bar. Inline, in a hub's Chat tab, the hub draws its own.
private struct ConversationChrome: ViewModifier {
    let placement: Placement
    let header: ConversationHeader

    func body(content: Content) -> some View {
        if placement == .screen {
            content
                .navigationTitle(header.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { header }
                }
                .tint(Color.pi2Accent)
        } else {
            content
        }
    }
}
