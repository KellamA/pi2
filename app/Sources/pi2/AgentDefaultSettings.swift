import SwiftUI

/// The default model for agents as the engine last sent it, in its `agentDefault` event (#617): what the person chose
/// (none for the model used last), with its thinking level, and the model an agent with none of its own starts on now.
struct AgentDefaultState: Equatable {
    var model: ModelRef?
    var thinkingLevel: String?
    var using: ModelRef?
    /// The chosen model is switched off or its provider is gone, so agents start on `using` instead.
    var fellBack = false

    init(_ value: JSONValue?) {
        model = Self.ref(value?["model"])
        thinkingLevel = value?["thinkingLevel"]?.stringValue
        using = Self.ref(value?["using"])
        if case .bool(let on)? = value?["fellBack"] { fellBack = on }
    }

    private static func ref(_ value: JSONValue?) -> ModelRef? {
        guard let provider = value?["provider"]?.stringValue, let modelId = value?["modelId"]?.stringValue else { return nil }
        return ModelRef(provider: provider, modelId: modelId)
    }
}

extension EngineClient {
    var agentDefault: AgentDefaultState { AgentDefaultState(extras["agentDefault"]) }

    /// "Anthropic · Opus 5.5": the model an agent with none of its own starts on now, as a picker names one closed.
    var defaultModelName: String? {
        guard let ref = defaultModel else { return nil }
        guard let model = allModels.first(where: { $0.ref == ref }) else { return ref.modelId }
        return "\(model.providerName) · \(model.name)"
    }
}

/// Settings › General: the model, and its thinking level, that every agent with no model of its own starts each
/// conversation on (#617). An agent follows it: changing it changes what such an agent starts its next conversation on.
struct AgentDefaultSettings: View {
    let engine: EngineClient
    @State private var problem: String?

    var body: some View {
        let state = engine.agentDefault
        let chosen = state.model.flatMap { ref in engine.allModels.first { $0.ref == ref } }
        // Every agent, of a project or not, that is not removed and has no model of its own.
        let following = engine.allAgents.filter { $0.model == nil && $0.removedAt == nil }.count
        Section {
            ChatModelPicker(engine: engine, label: "Default model for new agents", selection: state.model) { model in
                change(model, thinking: nil)
            }
            if let chosen, !chosen.thinkingLevels.isEmpty {
                Picker("Thinking", selection: Binding(get: { state.thinkingLevel }, set: { change(chosen.ref, thinking: $0) })) {
                    Text("The model’s default").tag(String?.none)
                    ForEach(chosen.thinkingLevels, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                }
            }
            if state.fellBack, let model = state.model {
                Label(
                    "\(chosen.map { "\($0.providerName) · \($0.name)" } ?? model.modelId) is \(chosen?.hidden == true ? "switched off" : "not available, as its provider is signed out or no longer offers it"), so agents start on \(engine.defaultModelName ?? "the demo model") instead until it is back.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
            if let problem {
                Text(problem).foregroundStyle(Theme.bad).font(.callout)
            }
        } header: {
            Text("Agents")
        } footer: {
            Text(footer(state, following: following)).formFooter()
        }
    }

    private func footer(_ state: AgentDefaultState, following: Int) -> String {
        let agents = following == 1 ? "1 agent has" : "\(following) agents have"
        let what = state.model == nil
            ? "With The model used last, it is the model you last picked in a conversation\(engine.defaultModelName.map { ", now \($0)" } ?? "")."
            : "Picking a model in a conversation changes only that conversation."
        return "The model an agent runs on when it has none of its own, which is every new agent until you choose one in its settings. Agents follow it: \(agents) no model of their own and start their next conversation, and any work handed to them, on this one; conversations already started keep theirs. \(what)"
    }

    private func change(_ model: ModelRef?, thinking: String?) {
        Task {
            do {
                var params: [String: Any] = ["model": model.map { ["provider": $0.provider, "modelId": $0.modelId] } ?? NSNull()]
                if let thinking { params["thinkingLevel"] = thinking }
                try await engine.call("settings.setAgentDefault", params)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
