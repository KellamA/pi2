import SwiftUI

/// Whether the commands agents run start at a lower priority than pi² itself (#344). The engine keeps the switch and
/// sends it as its `priority` event; it applies to every agent and sub-chat, from the next command started. See
/// docs/architecture.md, "Agents' commands at a lower priority".
struct CommandPrioritySettings: View {
    let engine: EngineClient

    @State private var problem: String?

    private var event: JSONValue? { engine.extras["priority"] }
    /// On until the engine says otherwise, as it starts.
    private var lower: Bool {
        if case .bool(let on)? = event?["lower"] { return on }
        return true
    }

    var body: some View {
        Section {
            Toggle("Run agents' commands at a lower priority", isOn: Binding(
                get: { lower },
                set: { on in change(on) }
            ))
            if let problem {
                Text(problem).foregroundStyle(Theme.bad).font(.callout)
            }
        } header: {
            Text("Agents' commands")
        } footer: {
            Text("When this is on, the commands agents run, and everything those start, give way to pi² and to your other apps whenever the Mac is busy, so pi² stays quick however hard agents work it. With room to spare, they run as fast as before. It changes nothing a command can do or see. It applies from the next command an agent starts; one already running keeps the priority it started with.").formFooter()
        }
    }

    private func change(_ on: Bool) {
        Task {
            do {
                try await engine.call("priority.set", ["lower": on])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
