import SwiftUI

/// One thing waiting on the person, with the controls to answer it. Used in the transcript, the inbox, and above the
/// composer for a subagent's requests.
struct InboxCard: View {
    let engine: EngineClient
    let item: InboxItem
    /// Whether to say which agent and conversation is asking; off where the surrounding view already shows it.
    let showsSource: Bool
    @State private var answer = ""

    private var agent: AgentProfile? { engine.agents.first { $0.name == item.agentName } }
    private var isApproval: Bool { item.kind == "approval" }

    /// "Atlas wants to run a command", in the words of what the tool does.
    private var request: String {
        let who = item.agentName ?? "The agent"
        return switch item.tool {
        case "bash": "\(who) wants to run a command"
        case "write": "\(who) wants to write a file"
        case "edit": "\(who) wants to edit a file"
        default: "\(who) wants to use \(item.tool)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if showsSource { AgentAvatar(agent: agent, size: 20) }
                Text(isApproval ? request : "\(item.agentName ?? "The agent") has a question")
                    .font(.system(size: 13, weight: .semibold))
                if showsSource {
                    Text(item.title).foregroundStyle(Theme.tx2).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("waits for you · survives restarts").font(.system(size: 11)).foregroundStyle(Theme.tx3)
            }
            if isApproval {
                Text(item.call.summary)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.tx)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.black.opacity(0.18), in: .rect(cornerRadius: 7))
                HStack(spacing: 8) {
                    Button("Allow Once") { decide("once") }
                        .buttonStyle(.piPrimary)
                    Button("Always Allow \(item.tool) Here") { decide("always") }
                        .buttonStyle(.piSecondary)
                        .help("Stop asking about \(item.tool) in this conversation")
                    Button("Deny") { decide("deny") }
                        .buttonStyle(.piDanger)
                }
            } else {
                Text(item.question ?? "").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("Type an answer…", text: $answer)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .panel(radius: 8, fill: Color.black.opacity(0.15), border: Theme.line2)
                        .onSubmit(send)
                    Button("Send") { send() }
                        .buttonStyle(.piPrimary)
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .font(.system(size: 12.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, 11)
        .panel(fill: isApproval ? Theme.warn.opacity(0.10) : Theme.panel, border: isApproval ? Theme.warn.opacity(0.4) : Theme.line2)
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
                EmptyState(icon: "checkmark.seal", title: "Nothing needs you", message: "Approvals and questions from your agents land here. You can answer them from the transcript too.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(engine.inbox) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                InboxCard(engine: engine, item: item, showsSource: true)
                                Button("Open “\(item.rootTitle.isEmpty ? "New conversation" : item.rootTitle)”") {
                                    model.selection = .conversation(item.rootConversationId)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.acc)
                                .font(.system(size: 12))
                            }
                        }
                    }
                    .padding(.horizontal, 28).padding(.vertical, 22)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.window)
        .navigationTitle("Inbox")
        .navigationSubtitle(engine.inbox.isEmpty ? "" : "\(engine.inbox.count) waiting")
    }
}

/// A calm, centred "nothing here" with the pi² accent.
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.acc)
                .frame(width: 60, height: 60)
                .background(Theme.acc.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(message).foregroundStyle(Theme.tx2).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
