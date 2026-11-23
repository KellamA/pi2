import EngineKit
import PiModels
import SwiftUI

/// The app's settings a phone may change, from More on the projects list: what the Mac's Settings shows that is not a
/// secret, a sign-in or the Mac's upkeep (docs/design/iphone.md, "Every screen and function of the Mac app" and "What
/// stays on the Mac, and why"), under the phone's own: this iPhone, its pairing, Face ID and notifications. Each of the
/// Mac's is sent as the Mac's Settings sends it (`SettingsRequest`), and what stays on the Mac is listed, so the person
/// knows where to go.
struct SettingsView: View {
    init() {}

    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @State private var problems = SettingsProblems()
    @State private var coauthorLine = ""
    @FocusState private var editingLine: Bool

    var body: some View {
        let source = SettingsSource(session)
        ScrollViewReader { proxy in
            Form {
                if SettingsConnectionLine(connected: source.connected, connection: session.connection).shows || !source.samples.isEmpty {
                    Section {
                        SettingsConnectionLine(connected: source.connected, connection: session.connection)
                        #if DEBUG
                        SettingsSamples.note(source)
                        #endif
                    }
                }
                SettingsPhoneSection(connection: session.connection, macName: session.macName).id("phone")
                generalSection(source).id("mac")
                chatSection(source).id("chat")
                coauthorSection(source).id("commits")
                moreSection.id("more")
                macSection.id("onlyMac")
            }
            #if DEBUG
            .task { await SettingsSamples.scroll(proxy) }
            .onChange(of: source.awake, initial: true) { _, awake in
                if let awake, source.connected, SettingsSamples.shouldPress("awake") {
                    send(.awake(keep: !awake.keep, battery: awake.battery), row: "awake")
                }
            }
            #endif
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings")
        .onAppear { coauthorLine = source.coauthor?.line ?? "" }
        .onChange(of: source.coauthor?.line) { _, line in
            if !editingLine { coauthorLine = line ?? "" }
        }
    }

    private var engine: EngineSession<MessageField> { session.engine }

    private func send(_ request: SettingsRequest, row: String) {
        request.send(through: engine, row: row, into: $problems)
    }

    // MARK: General

    private func generalSection(_ source: SettingsSource) -> some View {
        Section {
            if let awake = source.awake {
                Toggle("Keep the Mac awake while agents work", isOn: Binding(
                    get: { awake.keep },
                    set: { send(.awake(keep: $0, battery: awake.battery), row: "awake") }
                ))
                .disabled(!source.connected)
                Toggle("Also on battery", isOn: Binding(
                    get: { awake.battery },
                    set: { send(.awake(keep: awake.keep, battery: $0), row: "awake") }
                ))
                .disabled(!source.connected || !awake.keep)
            } else {
                SettingsNotKnown(title: "Keep the Mac awake while agents work")
            }
            SettingsProblem(text: problems["awake"])

            if source.libraryLoaded {
                Picker("Archive unused conversations after", selection: Binding(
                    get: { source.autoArchiveDays ?? 0 },
                    set: { send(.autoArchive(days: $0), row: "archive") }
                )) {
                    Text(SettingsAutoArchive.label(nil)).tag(0)
                    ForEach(SettingsAutoArchive.choices(including: source.autoArchiveDays), id: \.self) { days in
                        Text(SettingsAutoArchive.label(days)).tag(days)
                    }
                }
                .pickerStyle(.navigationLink)
                .disabled(!source.connected)
            } else {
                SettingsNotKnown(title: "Archive unused conversations after")
            }
            SettingsProblem(text: problems["archive"])

            if let compaction = source.compaction {
                Picker("Summarise long conversations at", selection: Binding(
                    get: { compaction.tokens },
                    set: { send(.compaction($0), row: "compaction") }
                )) {
                    Text("Off").tag(Int?.none)
                    ForEach(SettingsCompaction.choices(including: compaction.tokens), id: \.self) { tokens in
                        Text(SettingsCompaction.label(tokens)).tag(Int?.some(tokens))
                    }
                }
                .pickerStyle(.navigationLink)
                .disabled(!source.connected)
            } else {
                SettingsNotKnown(title: "Summarise long conversations at")
            }
            SettingsProblem(text: problems["compaction"])

            LabeledContent("Default model for new agents") {
                Text(agentDefaultText(source))
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityHint("Changed on the Mac")
        } header: {
            Text("On your Mac")
        } footer: {
            Text("While agents work, pi² stops the Mac sleeping by itself, on battery only with “Also on battery” on. A conversation working or waiting for you is never archived; archiving deletes nothing. A summary replaces a long conversation’s earlier part, as the model sees it, so later turns read less. The default model for agents is chosen on the Mac.")
        }
    }

    private func agentDefaultText(_ source: SettingsSource) -> String {
        guard let state = source.agentDefault else { return "Not known yet" }
        if let chosen = state.model { return source.modelName(chosen) ?? chosen.modelId }
        return "The model used last" + (source.modelName(state.using).map { " (\($0))" } ?? "")
    }

    // MARK: Chat

    private func chatSection(_ source: SettingsSource) -> some View {
        Section {
            if let chat = source.chat {
                NavigationLink {
                    SettingsChatInstructions(saved: chat.instructions)
                } label: {
                    LabeledContent("Instructions", value: chat.instructions.isEmpty ? "None" : "Set")
                }
                .disabled(!source.connected)
                Picker("Model for new chats", selection: Binding(
                    get: { chat.defaultModel },
                    set: { send(.chatModel($0), row: "chat") }
                )) {
                    Text("The one chosen last").tag(ModelRef?.none)
                    if let current = chat.defaultModel, !source.allModels.contains(where: { $0.ref == current }) {
                        Text(current.modelId).tag(ModelRef?.some(current))
                    }
                    ForEach(source.modelGroups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.models, id: \.ref) { model in
                                Text(model.listName).tag(ModelRef?.some(model.ref))
                            }
                        }
                    }
                }
                .pickerStyle(.navigationLink)
                .disabled(!source.connected)
                Toggle("Start new chats with the web on", isOn: Binding(get: { chat.web }, set: { send(.chatWeb($0), row: "chat") }))
                    .disabled(!source.connected)
                Toggle("Chat memory", isOn: Binding(get: { chat.memory }, set: { send(.chatMemory($0), row: "chat") }))
                    .disabled(!source.connected)
            } else {
                SettingsNotKnown(title: "Chat settings")
            }
            SettingsProblem(text: problems["chat"])
        } header: {
            Text("Chat")
        } footer: {
            Text("What every chat is told, the model and web switch a new chat starts with, and whether chats remember what you tell them. Each applies from a chat’s next message.")
        }
    }

    // MARK: Agents' commits

    private func coauthorSection(_ source: SettingsSource) -> some View {
        Section {
            if let coauthor = source.coauthor {
                Toggle("Add pi² as a co-author to agents’ commits", isOn: Binding(
                    get: { coauthor.enabled },
                    set: { send(.coauthor(enabled: $0), row: "coauthor") }
                ))
                .disabled(!source.connected)
                TextField("Co-author line", text: $coauthorLine, prompt: Text(coauthor.defaultLine), axis: .vertical)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($editingLine)
                    .accessibilityLabel("Line agents end a commit message with")
                HStack {
                    Button("Save Line") {
                        editingLine = false
                        send(.coauthor(line: coauthorLine), row: "coauthor")
                    }
                    .disabled(coauthorLine.trimmingCharacters(in: .whitespaces) == coauthor.line || !source.connected)
                    if coauthor.line != coauthor.defaultLine {
                        Spacer()
                        Button("Use Default") {
                            coauthorLine = coauthor.defaultLine
                            send(.coauthor(line: coauthor.defaultLine), row: "coauthor")
                        }
                        .disabled(!source.connected)
                    }
                }
                .buttonStyle(.borderless)
            } else {
                SettingsNotKnown(title: "Agents’ commits")
            }
            SettingsProblem(text: problems["coauthor"])
        } header: {
            Text("Agents’ commits")
        } footer: {
            Text("When this is on, agents are asked to end the message of every commit they make with this line, which GitHub shows as a co-author. It is an instruction, not something pi² enforces.")
        }
    }

    // MARK: Elsewhere

    private var moreSection: some View {
        Section {
            SettingsRouteRow(title: "Usage and limits", symbol: "chart.bar") { openRoute(.usage) }
            SettingsRouteRow(title: "Schedules", symbol: "calendar.badge.clock") { openRoute(.schedules) }
        } footer: {
            Text("A project’s own settings and limits are under More in its hub.")
        }
    }

    private var macSection: some View {
        Section {
            ForEach(SettingsReach.onTheMac, id: \.title) { item in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text(item.why).font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: item.symbol).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Only on the Mac")
        } footer: {
            Text("Secrets, sign-ins and the Mac’s own upkeep stay on the Mac, in pi²’s Settings there.")
        }
    }
}

/// This iPhone: what it is paired with and how it reaches it, Face ID, notifications, and unpairing. Face ID and
/// unpairing come with the phone's keys (#680) and its store (#692), notifications with pushes (#689); until they are
/// built, each is drawn and says so, and none pretends to work.
struct SettingsPhoneSection: View {
    let connection: AppSession.Connection
    let macName: String?

    var body: some View {
        Section {
            LabeledContent("Paired with", value: pairedWith)
            LabeledContent("Reached", value: reached)
            LabeledContent("Face ID", value: "Asked to open pi²")
            LabeledContent("Notifications", value: "Not in this build")
            Button("Unpair This iPhone", role: .destructive) {}
                .disabled(true)
                .accessibilityHint("Not in this build yet")
        } header: {
            Text("This iPhone")
        } footer: {
            Text("Face ID opens pi² on this iPhone, and nothing is asked after, as you chose. Notifications come with pushes through pi²’s relay, and unpairing with the keys pairing makes; this build has neither yet. A lost iPhone is cut off on the Mac (Settings › Devices › Revoke) or by erasing it with Find My.")
        }
    }

    private var pairedWith: String {
        switch connection {
        case .notPaired: "No Mac"
        case .demo: "The demo"
        default: macName ?? "Your Mac"
        }
    }

    private var reached: String {
        switch connection {
        case .notPaired: "Not paired"
        case .demo: "No network: canned data"
        case .connecting: "Reaching…"
        case .connected(.home, let relay): relay ? "At home" : "At home · relay unreachable"
        case .connected(.relay, _): "Through pi²’s relay"
        case .connected(.direct, _): "Direct"
        case .outOfReach(let seen?): "Out of reach since \(seen.formatted(date: .omitted, time: .shortened))"
        case .outOfReach(nil): "Out of reach"
        }
    }
}

/// A row for a setting whose value the engine has not sent yet: drawn, but with nothing to change.
struct SettingsNotKnown: View {
    let title: String

    var body: some View {
        LabeledContent(title, value: "Not known yet")
            .foregroundStyle(.secondary)
    }
}

/// A row that opens another screen by its route.
struct SettingsRouteRow: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label {
                    // `Color.primary`, not `.primary`, which a button resolves to its tint.
                    Text(title).foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(Color.pi2Accent)
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityAddTraits(.isLink)
    }
}

/// What every chat is told: edited here, sent when Save is pressed, as the Mac's Settings › Chat sends it.
struct SettingsChatInstructions: View {
    let saved: String

    @Environment(AppSession.self) private var session
    @State private var draft: String
    @State private var problem: String?
    @State private var sending = false

    init(saved: String) {
        self.saved = saved
        _draft = State(initialValue: saved)
    }

    private var current: String { SettingsChat(session.engine.extras["chat"])?.instructions ?? saved }

    var body: some View {
        Form {
            Section {
                TextField("Instructions", text: $draft, prompt: Text("My name is Alex. Keep answers short."), axis: .vertical)
                    .lineLimit(6...20)
                    .accessibilityLabel("Chat instructions")
            } footer: {
                Text("What chats should know about you and how you want them to answer. They are sent to the model in every chat, from its next message, and never to your agents. Your Mac tells you of instructions changed from here.")
            }
            if let problem {
                Section { SettingsProblem(text: problem) }
            }
        }
        .navigationTitle("Chat Instructions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines) == current || sending || session.engine.status != .connected)
            }
        }
    }

    private func save() {
        sending = true
        Task {
            problem = await SettingsRequest.chatInstructions(draft).send(through: session.engine)
            sending = false
        }
    }
}
