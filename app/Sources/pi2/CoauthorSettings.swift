import SwiftUI

/// Whether agents are asked to name pi² as a co-author of the commits they make, and the line they are asked to end the
/// message with (#201). The engine keeps both and sends them as its `coauthor` event; it applies to every agent and
/// sub-chat, from each conversation's next message. See docs/commits.md.
struct CoauthorSettings: View {
    let engine: EngineClient

    @State private var draft = ""
    @State private var problem: String?

    /// What the engine sent; before it has, what it starts with.
    private static let fallback = "Co-authored-by: pi² <noreply@pi2.invalid>"
    private var event: JSONValue? { engine.extras["coauthor"] }
    private var enabled: Bool {
        if case .bool(let on)? = event?["enabled"] { return on }
        return false
    }
    private var line: String { event?["line"]?.stringValue ?? Self.fallback }
    private var defaultLine: String { event?["defaultLine"]?.stringValue ?? Self.fallback }

    var body: some View {
        let line = line
        Section {
            Toggle("Add pi² as a co-author to agents' commits", isOn: Binding(
                get: { enabled },
                set: { on in change(["enabled": on]) }
            ))
            HStack(spacing: 8) {
                TextField("Co-author line", text: $draft, prompt: Text(defaultLine))
                    .labelsHidden()
                    .font(Theme.mono)
                    .accessibilityLabel("Line agents end a commit message with")
                    .onSubmit { save() }
                Button("Save") { save() }
                    .disabled(draft.trimmingCharacters(in: .whitespaces) == line)
                if line != defaultLine {
                    Button("Use Default") {
                        draft = defaultLine
                        save()
                    }
                }
            }
            if let problem {
                Text(problem).foregroundStyle(Theme.bad).font(.callout)
            }
        } header: {
            Text("Agents' commits")
        } footer: {
            Text("When this is on, agents are asked to end the message of every commit they make with this line, a Co-authored-by trailer that git hosts such as GitHub show as a co-author. It applies to every agent and sub-chat that can run commands, from each conversation's next message. It is an instruction, not something pi² enforces: an agent may leave it out, and nothing is added to commits made any other way. pi² never changes your git settings, a commit's author or committer, or commits already made. The default address ends in .invalid, a name reserved so that it can never belong to anyone, so it credits no one's account.").formFooter()
        }
        .onAppear { draft = line }
        .onChange(of: line) { _, latest in draft = latest }
    }

    private func save() {
        change(["line": draft])
    }

    private func change(_ params: [String: Any]) {
        Task {
            do {
                try await engine.call("coauthor.set", params)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
