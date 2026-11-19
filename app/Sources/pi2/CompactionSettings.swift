import SwiftUI

/// When a conversation's earlier messages are summarised (#408): a size in tokens, as a default for all agents in
/// Settings › General and for each agent on its page. Unset in both, pi² summarises only as a conversation nears its
/// model's limit. The engine keeps both and decides; see docs/compaction.md.
enum CompactionSize {
    /// The sizes offered. One set elsewhere (the engine's socket) is shown as well, so it is never silently replaced.
    static let choices = [50_000, 100_000, 200_000, 300_000, 500_000]

    static func choices(including value: Int?) -> [Int] {
        guard let value, !choices.contains(value) else { return choices }
        return (choices + [value]).sorted()
    }

    static func label(_ tokens: Int) -> String { "\(tokens.formatted()) tokens" }

    /// What a size means, for a person who does not count in tokens.
    static func words(_ tokens: Int) -> String { "about \((tokens / 4 * 3).formatted()) words" }

    /// What happens with this size in effect, as the first sentence of a footer.
    static func sentence(_ tokens: Int?, whose: String) -> String {
        guard let tokens else { return "\(whose) are summarised only as they near the most their model can read at once." }
        return "\(whose) are summarised once a request to the model would be larger than \(label(tokens)), \(words(tokens)) of English."
    }

    /// The trade, said once for both places.
    static let trade = "Every answer reads the whole conversation again, so a long one costs more on every turn and uses more of a subscription’s limits. A summary replaces the earlier part, as the model sees it, with a shorter account: later turns read less, but detail is lost, and the turn after it costs more once while the model’s cache fills again. The earlier messages stay in the conversation for you to read. A size the model would not reach before its own limit changes nothing."
}

/// The default for all agents, in Settings › General. The engine sends it as its `compactionSettings` event.
struct CompactionDefaultSettings: View {
    let engine: EngineClient
    @State private var problem: String?

    private var size: Int? { engine.extras["compactionSettings"]?["defaultCompactionTokens"]?.intValue }

    var body: some View {
        let size = size
        Section {
            Picker("Summarise earlier messages when a conversation reaches", selection: Binding(
                get: { size },
                set: { change($0) }
            )) {
                Text("Off").tag(Int?.none)
                Divider()
                ForEach(CompactionSize.choices(including: size), id: \.self) { Text(CompactionSize.label($0)).tag(Int?.some($0)) }
            }
            if let problem {
                Text(problem).foregroundStyle(Theme.bad).font(.callout)
            }
        } header: {
            Text("Long conversations")
        } footer: {
            Text("\(size == nil ? "Off: " + CompactionSize.sentence(nil, whose: "conversations") : CompactionSize.sentence(size, whose: "Conversations")) \(CompactionSize.trade) Each agent can have a size of its own in its settings; chats with pi²’s assistant do not use this one.").formFooter()
        }
    }

    private func change(_ size: Int?) {
        Task {
            do {
                try await engine.call("settings.setCompaction", ["defaultCompactionTokens": size.map { $0 as Any } ?? NSNull()])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// One agent's size, on its page: inherit with nil, opt out with 0, or save a size as `compactionTokens`.
struct AgentCompactionSection: View {
    let engine: EngineClient
    @Binding var tokens: Int?

    private var fallback: Int? { engine.extras["compactionSettings"]?["defaultCompactionTokens"]?.intValue }

    var body: some View {
        let fallback = fallback
        let off = tokens == 0
        let note = off
            ? "Off: its conversations are summarised only as they near the most their model can read at once, whatever the default."
            : CompactionSize.sentence(tokens ?? fallback, whose: "Its conversations")
        Section {
            Picker("Summarise earlier messages when a conversation reaches", selection: $tokens) {
                Text("Use the default (\(fallback.map(CompactionSize.label) ?? "off"))").tag(Int?.none)
                Text("Off").tag(Int?.some(0))
                Divider()
                ForEach(CompactionSize.choices(including: off ? nil : tokens), id: \.self) { Text(CompactionSize.label($0)).tag(Int?.some($0)) }
            }
        } header: {
            Text("Long conversations")
        } footer: {
            Text("\(note) Later turns then read less, but a summary loses detail; the earlier messages stay in the conversation for you. Settings › General has the default for all agents, and says more. To let the agent choose a good moment itself, such as between two pieces of work, turn on Summarise its own conversation under Built-in tools.").formFooter()
        }
    }
}
