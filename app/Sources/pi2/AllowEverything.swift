import SwiftUI

/// Allow everything (#294): an agent that is asked about nothing and may use any app. The engine decides; this is the
/// switch in the agent's settings, the confirmation before it goes on, and the warnings wherever such an agent shows.
/// The warnings use the app's mark for danger, red (`Theme.bad`), as a failed run and "over budget" do.
enum AllowEverything {
    static let tag = "allows everything"

    static func confirmationTitle(_ name: String) -> String { "Let \(name) do anything without asking you?" }

    /// What a conversation's warning says, or nil when it runs as its agent's settings ask. It follows the conversation's
    /// own agent, never its parent's: a sub-chat runs under its own agent's switch.
    static func warning(_ conversation: ConversationSummary?, agent: AgentProfile?) -> String? {
        let taken = conversation?.allowEverything == true
        let agentOn = agent?.allowEverything == true
        guard taken || agentOn else { return nil }
        let name = agent?.name ?? "This agent"
        return switch (taken, agentOn) {
        case (true, true): "Allow everything is on: \(name) does anything here without asking you, and may use any app."
        case (true, false): "Allow everything was turned off for \(name), but holds here until this conversation’s next message."
        default: "Allow everything is on for \(name): from this conversation’s next message, nothing here is asked about."
        }
    }

    static func confirmation(_ name: String) -> String {
        """
        \(name) will no longer ask before anything it does: running commands, changing and deleting files, clicking and typing in apps and web pages, making worktrees and setting schedules. With computer use on, it may use any app, not only the ones listed, including Safari, Chrome and other browsers where you are signed in.

        This covers every conversation of \(name), from each one’s next message: scheduled runs, which happen with nobody watching, and the sub-chats other agents hand it. Sub-chats it opens follow their own agent’s settings.

        What still holds: computer use cannot work pi² itself, terminals, script editors or password managers, or type into password fields, and can only look at System Settings. Your daily budget, its turn limit and its tool access hold too.

        Turn it on only where anything the agent can reach is something you could lose.
        """
    }
}

/// The switch in an agent's settings. It is kept as soon as it is changed, without Save, like command rules.
struct AllowEverythingSection: View {
    let engine: EngineClient
    let agentID: String
    @State private var confirming = false
    @State private var problem: String?

    private var agent: AgentProfile? { engine.agent(agentID) }
    private var on: Bool { agent?.allowEverything == true }
    private var name: String { agent?.name ?? "This agent" }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { on }, set: { want in if want { confirming = true } else { set(false) } })) {
                Text("Allow everything")
                Text("Asks you about nothing, and may use any app.")
            }
            .tint(Theme.bad)
            if confirming, !on { confirmation }
            if on {
                Label("\(name) does anything without asking you, in every conversation, scheduled runs included.", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(Theme.bad)
            }
            if let problem { Text(problem).foregroundStyle(Theme.bad).font(.callout) }
        } header: {
            Text("Allow everything")
        } footer: {
            Text(footer).formFooter()
        }
        #if PI2_DEVELOPMENT
        // `PI2_SHOW=agent:<id>#everything` opens the page here, with the confirmation up while the switch is off, so a
        // throwaway copy can show it without a click (docs/development.md).
        .task {
            if ProcessInfo.processInfo.environment["PI2_SHOW"] == "agent:\(agentID)#everything", !on { confirming = true }
        }
        #endif
    }

    /// In the page rather than in an alert, so the whole of it can be read, in the red of anything risky.
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(AllowEverything.confirmationTitle(name), systemImage: "exclamationmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(Theme.bad)
            Text(AllowEverything.confirmation(name))
                .foregroundStyle(Theme.tx)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirming = false }
                    .buttonStyle(.piSecondary)
                Button("Allow Everything") {
                    confirming = false
                    set(true)
                }
                .buttonStyle(.piDanger)
            }
        }
        .padding(12)
        .panel(fill: Theme.bad.opacity(0.08), border: Theme.bad.opacity(0.35))
    }

    private var footer: String {
        var text = on
            ? "On: commands, file changes, computer use, the browser, worktrees and schedules go ahead without an approval, and computer use is not limited to the apps listed. "
            : "Off: the agent asks as its other settings say. "
        text += "What still holds: computer use cannot work pi² itself, terminals, script editors or password managers, or type into password fields, and can only look at System Settings. The daily budget, the turn limit and the tool access above hold too. "
        text += "A change applies from each conversation’s next message; Stop ends a run at once. "
        text += "For computer use in any app, pi² needs Accessibility, and Screen Recording for pictures: grant them under Computer use."
        return text
    }

    private func set(_ value: Bool) {
        Task {
            do {
                try await engine.call("agents.allowEverything", ["id": agentID, "on": value])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Across the top of a conversation whose agent allows everything, or that still has it from its latest message.
struct AllowEverythingBanner: View {
    let engine: EngineClient
    let conversation: ConversationSummary?
    var inset: CGFloat = 28

    var body: some View {
        let agent = engine.agent(conversation?.agentId)
        if let text = AllowEverything.warning(conversation, agent: agent) {
            let name = agent?.name ?? "This agent"
            Label(text, systemImage: "exclamationmark.octagon.fill")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.bad)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .panel(fill: Theme.bad.opacity(0.08), border: Theme.bad.opacity(0.35))
                .padding(.horizontal, inset).padding(.top, 8)
                .help("Set in \(name)’s settings, under Allow everything")
        }
    }
}

/// The banner's mark, small, on a conversation's row in the sidebar (#328), so the list shows which conversations run
/// unasked before one is opened. It reads only the conversation's row and the agents, which change rarely and are set
/// only when they change, so it adds nothing to what makes a row draw again while agents work.
struct AllowEverythingMark: View {
    let engine: EngineClient
    let conversation: ConversationSummary

    var body: some View {
        if let text = AllowEverything.warning(conversation, agent: engine.agent(conversation.agentId)) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.bad)
                .help(text)
                .accessibilityLabel("Allows everything")
        }
    }
}
