import SwiftUI

/// One thing waiting on the person, with the controls to answer it. Used in the transcript, the inbox, and above the
/// composer for a subagent's requests.
struct InboxCard: View {
    let engine: EngineClient
    let item: InboxItem
    /// Whether to say which agent and conversation is asking; off where the surrounding view already shows it.
    let showsSource: Bool
    var framed = true
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsSource {
                HStack(spacing: 6) {
                    Text(item.agentName ?? "Agent").font(.callout.weight(.semibold))
                    Text(item.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if item.kind == "approval" {
                Text("Wants to use \(item.tool):").font(.callout)
                Text(item.call.summary)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(6)
                HStack {
                    Button("Allow Once") { decide("once") }
                        .buttonStyle(.borderedProminent)
                    Button("Always Allow \(item.tool) Here") { decide("always") }
                        .help("Stop asking about \(item.tool) in this conversation")
                    Button("Deny", role: .destructive) { decide("deny") }
                }
            } else {
                Text(item.question ?? "").textSelection(.enabled)
                HStack {
                    TextField("Type an answer…", text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Send") { send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(framed ? 12 : 0)
        .background(framed ? AnyShapeStyle(Color.orange.opacity(0.12)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(framed ? Color.orange.opacity(0.4) : .clear))
    }

    private func decide(_ decision: String) {
        engine.perform("inbox.decide", ["id": item.id, "decision": decision])
    }

    private func send() {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        engine.perform("inbox.answer", ["id": item.id, "text": answer])
        answer = ""
    }
}

/// Everything waiting on the person, across all conversations.
struct InboxView: View {
    @Bindable var model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        Group {
            if engine.inbox.isEmpty {
                ContentUnavailableView("Nothing needs you", systemImage: "tray", description: Text("Approvals and questions from your agents appear here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(engine.inbox) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                InboxCard(engine: engine, item: item, showsSource: true)
                                Button("Open “\(item.rootTitle.isEmpty ? "New conversation" : item.rootTitle)”") {
                                    model.selection = .conversation(item.rootConversationId)
                                }
                                .buttonStyle(.link)
                                .font(.callout)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Inbox")
        .navigationSubtitle(engine.inbox.isEmpty ? "" : "\(engine.inbox.count) waiting")
    }
}

/// A subagent's own conversation, opened from the delegation card that started it.
struct SubagentSheet: View {
    let engine: EngineClient
    let id: Int
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let data = engine.open[id] ?? ConversationData()
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text("Subagent transcript").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if data.state?.busy == true {
                    ProgressView().controlSize(.small)
                    Button("Stop") { engine.perform("abort", ["id": id]) }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            TranscriptView(engine: engine, conversationID: id, items: data.items, state: data.state)
        }
        .frame(width: 760, height: 560)
        .onAppear { engine.openConversation(id) }
    }
}
