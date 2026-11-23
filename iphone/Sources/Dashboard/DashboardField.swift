import EngineKit
import PiModels
import SwiftUI

/// The field at the foot of the Dashboard, which messages the orchestrator of the page shown, as the field under a
/// Dashboard column does on the Mac (`HubStrip`). The text stays in the field until the engine has taken it; a refusal
/// is said above the field, and the text kept for sending again.
struct DashboardField: View {
    let project: ProjectRow

    @Environment(AppSession.self) private var session
    @State private var text = ""
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var engine: EngineSession<MessageField> { session.engine }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Why nothing can be sent now, if so.
    private var closed: String? {
        if project.archivedAt != nil { return "This project is archived." }
        if project.conversation == nil { return "The conversation with the orchestrator has not started yet." }
        return nil
    }
    private var canSend: Bool {
        !trimmed.isEmpty && closed == nil && !sending && engine.status == .connected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem {
                HubProblem(text: problem)
            } else if let closed {
                Text(closed)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message the orchestrator", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .disabled(closed != nil)
                    .accessibilityLabel("Message \(project.name)’s orchestrator")
                Button(action: send) {
                    Group {
                        if sending {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .resizable()
                                .scaledToFit()
                        }
                    }
                    .frame(width: 34, height: 34)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send to \(project.name)’s orchestrator")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // At the largest sizes the field and what it says would take the page; past this they keep a part of it.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .background(.bar)
        .onChange(of: text) { _, _ in if !sending { problem = nil } }
        #if DEBUG
        .task {
            if HubDebugAct.take("send"), let words = HubDebugAct.argument("send") {
                text = words
                send()
            }
        }
        #endif
    }

    private func send() {
        guard canSend else { return }
        let message = trimmed
        sending = true
        problem = nil
        Task {
            let refusal = await HubRequests.message(engine, message, to: project)
            sending = false
            if let refusal {
                problem = "Not sent: \(refusal)"
            } else if trimmed == message {
                text = ""
            }
        }
    }
}
