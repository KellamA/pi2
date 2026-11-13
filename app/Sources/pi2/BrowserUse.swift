import AppKit
import BrowserKit
import CryptoKit
import SwiftUI

/// A browser action as the engine sends it. BrowserKit reads it, so that the app and the developer probe agree with
/// the engine in one place.
typealias BrowserEvent = BrowserKit.BrowserEvent

/// Carries out what agents ask of web pages, in pi²'s own browser, and shows the person that it is happening.
///
/// The engine decides what is allowed and asks for approval; this loads the pages and works them, because the web
/// views live in the app. The hard limits (public http and https only, no passwords typed, no downloads) are checked
/// again in BrowserKit, whatever the engine sends.
@MainActor
final class BrowserSession {
    /// Made when first needed: a browser nobody uses costs nothing.
    private(set) lazy var controller = BrowserController(profile: .persistent(Self.profile))
    private let indicator = ComputerIndicator(row: 1)
    /// Brings the Browser window forward; set by a view that can open windows.
    var showWindow: () -> Void = {}

    /// Where the browser keeps its cookies and sign-ins. One store for the person's data folder, and a different one
    /// for any other folder, so a copy of pi² run on a throwaway folder does not share the real sign-ins.
    private static var profile: UUID {
        guard let home = ProcessInfo.processInfo.environment["PI2_HOME"] else { return UUID(uuidString: "5C1A2B7E-3D4F-4A60-9B8C-70B2E15A6F01")! }
        var bytes = Array(SHA256.hash(data: Data(home.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func handle(_ event: BrowserEvent, engine: EngineClient) {
        let request = event.request
        let conversation = request.conversationId
        // A conversation that was deleted takes its page with it.
        if engine.hasLoadedLibrary { controller.keepOnly(Set(engine.conversations.map(\.id))) }
        // Describing an action for approval touches nothing, so it is not announced.
        let acts = request.action != "describe"
        if acts {
            let site = request.url.flatMap { URL(string: $0)?.host } ?? controller.page(conversation)?.site ?? ""
            let root = engine.conversations.first { $0.id == conversation }?.parent ?? conversation
            indicator.show(
                agent: event.agentName ?? "An agent", app: site.isEmpty ? "the web" : site, doing: "is browsing",
                reveal: { [weak self] in self?.reveal(conversation) },
                stop: { [weak engine] in engine?.perform("abort", ["id": root]) }
            )
        }
        Task {
            let reply = await controller.perform(request)
            // If the engine has gone there is nobody to tell; it ends the call itself when the app disconnects.
            _ = try? await engine.call("browser.result", reply.result(for: event.requestId))
            if acts { indicator.rest() }
        }
    }

    /// Show a conversation's page in the Browser window.
    func reveal(_ conversationId: Int) {
        if controller.page(conversationId) != nil { controller.selected = conversationId }
        showWindow()
        NSApp.activate()
    }
}

extension BrowserSession {
    /// The one line a browser call shows on its card: what the app says it did, or until then what was asked.
    static func line(for call: ToolCall, details: JSONValue?) -> String {
        if let summary = details?["summary"]?.stringValue { return summary }
        let arguments = call.arguments
        let element = arguments["element"]?.intValue.map { "element \($0)" } ?? "an element"
        switch arguments["action"]?.stringValue ?? "" {
        case "open": return "Open \(arguments["url"]?.stringValue ?? "a page")"
        case "search": return "Search for “\(arguments["query"]?.stringValue ?? "")”"
        case "read": return "Read the page"
        case "screenshot": return "Take a picture of the page"
        case "click": return "Click \(element)"
        case "type": return "Type into \(element)"
        case "select": return "Choose “\(arguments["option"]?.stringValue ?? "")” in \(element)"
        case "scroll": return "Scroll \((arguments["dy"]?.intValue ?? 1) < 0 ? "up" : "down")"
        case "back": return "Go back"
        case "upload": return "Upload \(((arguments["path"]?.stringValue ?? "a file") as NSString).lastPathComponent)"
        default: return call.summary
        }
    }
}

// MARK: - Agent settings

/// The part of an agent's settings that lets it browse the web.
struct BrowserSection: View {
    @Binding var settings: BrowserSettings

    var body: some View {
        Section {
            Toggle("Let this agent browse the web", isOn: $settings.enabled)
            if settings.enabled {
                Toggle("Ask before clicking buttons, typing and uploading", isOn: $settings.ask)
            }
        } header: {
            Text("Browser")
        } footer: {
            Text(footer).formFooter()
        }
    }

    private var footer: String {
        guard settings.enabled else { return "Off: this agent cannot open web pages." }
        var text = "The agent uses pi²’s own browser, which you can watch and use in Window › Browser. It is signed in only where you sign in there: Safari’s and Chrome’s sign-ins are not shared with it. Whatever a page shows is sent to the agent’s model. "
        text += settings.ask
            ? "It opens pages, searches, reads and follows links without asking. It asks before clicking a button, typing, choosing from a list or uploading, and you can allow a site for the rest of a conversation. "
            : "It acts without asking. "
        text += "It never types into password fields, cannot download files, and cannot open addresses on this Mac or your local network. It can upload only its reference files, or files in the folder of a conversation that may read files."
        return text
    }
}

// MARK: - The Browser window

/// pi²'s browser: the pages agents are on, one per conversation, and the person's own. The person can use any of them
/// as in any browser, to sign in, to get past a CAPTCHA, or to take over.
struct BrowserWindow: View {
    let engine: EngineClient

    @State private var typed = ""
    @State private var refusal: String?
    @State private var confirmingForget = false
    @FocusState private var editingAddress: Bool

    private var browser: BrowserController { engine.browser.controller }
    private var page: BrowserPage? { browser.selected.flatMap { browser.page($0) } }

    var body: some View {
        VStack(spacing: 0) {
            strip
            Rectangle().fill(Theme.line).frame(height: 1)
            bar
            if let page, page.isLoading {
                ProgressView(value: page.progress).progressViewStyle(.linear).controlSize(.small).tint(Theme.acc)
                    .accessibilityLabel("Loading the page")
            } else {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            if let page, page.busy { working(page) }
            if let notice = refusal ?? page?.notice { noticeBar(notice) }
            if page != nil {
                PageHost(browser: browser, id: browser.selected)
            } else {
                empty
            }
        }
        .background(Theme.window)
        .frame(minWidth: 620, minHeight: 400)
        .navigationTitle(page.map { $0.title.isEmpty ? "Browser" : $0.title } ?? "Browser")
        .navigationSubtitle(page?.site ?? "")
        .onAppear { typed = page?.address?.absoluteString ?? "" }
        .onChange(of: page?.address) { _, address in
            // Follow the page, but never overwrite what the person is typing.
            if !editingAddress { typed = address?.absoluteString ?? "" }
        }
        .onChange(of: browser.selected) { _, _ in
            typed = page?.address?.absoluteString ?? ""
            refusal = nil
        }
        .onChange(of: engine.conversations) { _, list in
            if engine.hasLoadedLibrary { browser.keepOnly(Set(list.map(\.id))) }
        }
        .confirmationDialog("Sign out everywhere in pi²’s browser?", isPresented: $confirmingForget) {
            Button("Forget Sign-ins and Site Data", role: .destructive) {
                Task { await browser.forgetEverything() }
            }
        } message: {
            Text("This removes every cookie and everything else sites have stored in pi²’s browser. Safari and your other browsers are not affected.")
        }
    }

    // MARK: Pages

    private func name(of page: BrowserPage) -> String {
        if page.id == BrowserController.ownPageID { return "Your page" }
        let title = engine.conversations.first { $0.id == page.id }?.title ?? ""
        return title.isEmpty ? "New conversation" : title
    }

    private func agent(of page: BrowserPage) -> AgentProfile? {
        engine.agent(engine.conversations.first { $0.id == page.id }?.agentId)
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(browser.pages, id: \.id) { page in tab(page) }
                Button("Open a Page of Your Own", systemImage: "plus") { openOwnPage() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.tx2)
                    .help("Open a page of your own, for example to sign in to a site before an agent needs it")
                    .disabled(browser.page(BrowserController.ownPageID) != nil)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(Theme.side)
    }

    private func tab(_ page: BrowserPage) -> some View {
        let selected = browser.selected == page.id
        let label = name(of: page)
        return HStack(spacing: 6) {
            Button {
                browser.selected = page.id
            } label: {
                HStack(spacing: 6) {
                    if page.busy {
                        Spinner().frame(width: 16)
                    } else if page.id == BrowserController.ownPageID {
                        Image(systemName: "person.crop.circle").foregroundStyle(Theme.tx2).frame(width: 16).accessibilityHidden(true)
                    } else {
                        AgentAvatar(agent: agent(of: page), size: 16)
                    }
                    Text(label).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                        .foregroundStyle(selected ? Theme.tx : Theme.tx2)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(page.title.isEmpty ? label : "\(label): \(page.title)")
            .accessibilityLabel(page.busy ? "\(label), an agent is working in this page" : label)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button("Close", systemImage: "xmark") { browser.close(page.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.tx3)
                .help("Close this page. Sign-ins are kept.")
                .accessibilityLabel("Close \(label)")
        }
        .font(.system(size: 12))
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 4)
        .panel(radius: 8, fill: selected ? Theme.card2 : Theme.card, border: selected ? Theme.acc.opacity(0.5) : Theme.line)
    }

    private func openOwnPage() {
        Task {
            _ = await browser.openPage(BrowserController.ownPageID)
            browser.selected = BrowserController.ownPageID
            editingAddress = true
        }
    }

    // MARK: Address bar

    private var bar: some View {
        HStack(spacing: 8) {
            Button("Back", systemImage: "chevron.left") { page?.webView.goBack() }
                .disabled(page?.canGoBack != true)
                .help("Go back")
            Button("Forward", systemImage: "chevron.right") { page?.webView.goForward() }
                .disabled(page?.canGoForward != true)
                .help("Go forward")
            if page?.isLoading == true {
                Button("Stop Loading", systemImage: "xmark") { page?.webView.stopLoading() }
                    .help("Stop loading this page")
            } else {
                Button("Reload", systemImage: "arrow.clockwise") { page?.webView.reload() }
                    .disabled(page?.hasDocument != true)
                    .help("Load this page again")
            }
            HStack(spacing: 6) {
                Image(systemName: page?.address?.scheme == "https" ? "lock.fill" : "globe")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.tx3)
                    .accessibilityLabel(page?.address?.scheme == "https" ? "Encrypted connection" : "Address")
                TextField("Search or enter an address", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($editingAddress)
                    .onSubmit { go() }
                    .accessibilityLabel("Address")
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .panel(radius: 8, fill: Theme.card, border: editingAddress ? Theme.acc.opacity(0.55) : Theme.line2)
            Menu {
                Button("Forget Sign-ins and Site Data…") { confirmingForget = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.tx2)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.side)
    }

    private func go() {
        let text = typed
        let id = browser.selected ?? BrowserController.ownPageID
        refusal = nil
        Task {
            refusal = await browser.go(text, in: id)
            if browser.selected == nil { browser.selected = id }
            editingAddress = false
        }
    }

    // MARK: Notes above the page

    private func working(_ page: BrowserPage) -> some View {
        let who = agent(of: page)?.name ?? "An agent"
        let root = engine.conversations.first { $0.id == page.id }?.parent ?? page.id
        return HStack(spacing: 9) {
            Spinner(size: 11)
            Text("\(who) is working in this page.").foregroundStyle(Theme.tx)
            Spacer()
            Button("Stop", systemImage: "stop.fill") { engine.perform("abort", ["id": root]) }
                .buttonStyle(PiButtonStyle(kind: .danger, compact: true))
                .help("Stop \(who)’s run")
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.acc.opacity(0.10))
    }

    private func noticeBar(_ notice: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warn).accessibilityHidden(true)
            Text(notice).foregroundStyle(Theme.tx).lineLimit(3).textSelection(.enabled)
            Spacer()
            Button("Dismiss", systemImage: "xmark") {
                refusal = nil
                page?.notice = nil
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.tx3)
            .help("Dismiss")
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.warn.opacity(0.10))
    }

    private var empty: some View {
        VStack(spacing: 12) {
            EmptyState(
                icon: "globe",
                title: "No pages yet",
                message: "When an agent with the browser switched on opens a page, it shows here, and you can use it too. Sign-ins made here stay in pi²’s browser; they are not shared with Safari or Chrome."
            )
            .frame(maxHeight: 220)
            Button("Open a Page of Your Own") { openOwnPage() }
                .buttonStyle(.piPrimary)
                .help("For example to sign in to a site before an agent needs it")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The place in the window where the selected page's web view sits. The web views belong to the browser, not to the
/// window: closing the window puts the page back where agents can go on working it.
private struct PageHost: NSViewRepresentable {
    let browser: BrowserController
    let id: Int?

    final class Coordinator {
        let browser: BrowserController
        init(browser: BrowserController) {
            self.browser = browser
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser)
    }

    func makeNSView(context: Context) -> NSView {
        BrowserPaneView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        browser.show(id, in: view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.browser.show(nil, in: view)
    }
}

/// A toolbar button that opens the Browser window on a conversation's page.
struct BrowserButton: View {
    let engine: EngineClient
    let conversationID: Int
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Browser", systemImage: "globe") {
            let browser = engine.browser.controller
            if browser.page(conversationID) != nil { browser.selected = conversationID }
            openWindow(id: "browser")
        }
        .labelStyle(.titleAndIcon)
        .help("Show the page this conversation’s agent is on, in pi²’s browser")
    }
}
