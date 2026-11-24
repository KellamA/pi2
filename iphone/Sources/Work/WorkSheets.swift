import PiModels
import SwiftUI

/// Giving a piece to an agent (docs/design/iphone.md, "The Work tab"): the project's workers, each with what it has
/// already, as the Mac's Give menu lists them. Choosing one starts it on the piece at once, in a sub-chat of the
/// orchestrator's conversation, as on the Mac.
struct WorkGiveSheet: View {
    let item: WorkPiece
    let noun: String
    let agents: [AgentProfile]
    /// The pieces each agent holds now, by agent id.
    let holding: [String: [WorkPiece]]
    let give: (AgentProfile) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(agents) { agent in
                        Button {
                            dismiss()
                            give(agent)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                AgentMark(agent: agent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(holdingWords(agent))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(agent.name), \(holdingWords(agent))")
                        .accessibilityHint("Gives \(noun) #\(item.id) to \(agent.name), which starts on it.")
                        .accessibilityAddTraits(.isButton)
                    }
                } header: {
                    Text("#\(item.id) \(item.title)")
                        .textCase(nil)
                } footer: {
                    Text("The agent starts on it at once, in a sub-chat of the orchestrator's conversation, and the \(noun) shows as in progress.")
                }
            }
            .navigationTitle("Give to an Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func holdingWords(_ agent: AgentProfile) -> String {
        let held = holding[agent.id] ?? []
        guard let first = held.first else { return "Has nothing from this list" }
        let state = first.state == "in_progress" ? "" : " (\(WorkState.name(first.state).lowercased()))"
        let more = held.count > 1 ? " and \(held.count - 1) more" : ""
        return "Has #\(first.id) \(first.title)\(state)\(more)"
    }
}

/// Filing a piece of work, or changing one's title and text (docs/design/iphone.md, "The Work tab"): the Mac's form, in
/// a sheet. It stays up while the engine is asked, and says there what it refused, so nothing typed is lost.
struct WorkComposer: View {
    enum Mode: Equatable {
        case new
        case edit(WorkPiece)
    }

    let mode: Mode
    let noun: String
    /// Where it goes: "Kept by pi² in Demo project's list", "Filed as an issue in owner/name".
    let destination: String
    /// Sends it; answers the engine's refusal, or nil once it has taken it.
    let send: (_ title: String, _ text: String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var text: String
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var titleFocused: Bool

    init(mode: Mode, noun: String, destination: String, send: @escaping (_ title: String, _ text: String) async -> String?) {
        self.mode = mode
        self.noun = noun
        self.destination = destination
        self.send = send
        switch mode {
        case .new:
            _title = State(initialValue: "")
            _text = State(initialValue: "")
        case .edit(let item):
            _title = State(initialValue: item.title)
            _text = State(initialValue: item.text)
        }
    }

    /// The title is one line wherever it is shown, so a line break typed into it becomes a space, as on the Mac.
    static func oneLine(_ title: String) -> String {
        title.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var ready: Bool { !Self.oneLine(title).isEmpty && !sending }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, prompt: Text("Title"), axis: .vertical)
                        .font(.body.weight(.medium))
                        .focused($titleFocused)
                        .accessibilityLabel("Title")
                    TextField("What needs doing", text: $text, prompt: Text("What needs doing (you can leave this empty)"), axis: .vertical)
                        .lineLimit(5...)
                        .accessibilityLabel("Text")
                } footer: {
                    Text(destination)
                }
                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .disabled(sending)
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button(mode == .new ? "Add" : "Save") { submit() }
                            .disabled(!ready)
                    }
                }
            }
            .onAppear { if mode == .new { titleFocused = true } }
            #if DEBUG
            .task {
                if mode == .new, WorkDebugAct.take("new-send") {
                    title = WorkDebugAct.argument("new") ?? ""
                    submit()
                }
            }
            #endif
        }
        .interactiveDismissDisabled(sending)
    }

    private var heading: String {
        switch mode {
        case .new: noun == "issue" ? "New Issue" : "New Work"
        case .edit(let item): noun == "issue" ? "Edit Issue #\(item.id)" : "Edit Work #\(item.id)"
        }
    }

    private func submit() {
        let line = Self.oneLine(title)
        guard !line.isEmpty, !sending else { return }
        title = line
        sending = true
        Task {
            let refused = await send(line, text)
            sending = false
            problem = refused
            if refused == nil { dismiss() }
        }
    }
}
