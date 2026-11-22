import SwiftUI

// What a run is waiting on and how to stop it, and the engine's notice that it restarted: shown on a project's Now tab,
// in the Dashboard's columns and over the Dashboard and a hub (#645).

// MARK: - The command a run waits on

/// The shell command a run is waiting on: what it runs, for how long, and how long it has printed nothing once that is
/// a while (#196), so a stuck command can be told from a slow one. Ticks by itself; the engine sends only the times.
/// Shown on Activity's rows and on the Now tab's working rows; `compact`, in a Dashboard column, leaves out how long it
/// has run once it has been quiet a while, and the count of the run's other commands, so that the command keeps some room
/// in the narrow row (#645).
struct CommandClockLine: View {
    let command: RunningCommand
    /// Other commands of the same run running beside it.
    let more: Int
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let quiet = command.quiet(at: context.date)
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tx3)
                Text(command.command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? command.command)
                    .font(Theme.mono).foregroundStyle(Theme.tx2)
                    .lineLimit(1).truncationMode(.tail)
                if !(compact && quiet != nil) {
                    Text(command.elapsed(at: context.date)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.tx3)
                        .fixedSize()
                }
                if let quiet {
                    Text(quiet).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.warn).fixedSize()
                }
                if more > 0, !compact {
                    Text("and \(more) more").font(.system(size: 11.5)).foregroundStyle(Theme.tx3).fixedSize()
                }
            }
            .help(quiet == nil
                ? "Running for \(command.elapsed(at: context.date)): \(command.command)"
                : "Running for \(command.elapsed(at: context.date)), and nothing printed for a while. It may be waiting on something, such as a prompt on the screen. Stop stops the run.")
        }
    }
}

// MARK: - Stopping runs

/// Stopping runs from the projects' pages (#645): one working row's, or every run at once after a confirmation.
enum RunStopping {
    /// Stops each of these runs: the ones whose parent is not among them first, so that a conversation waiting on a
    /// sub-chat is stopped before the sub-chat, and does not go on with its turn when the sub-chat's result comes back.
    @MainActor
    static func stop(_ runs: [ActivityRun], engine: EngineClient) {
        let ids = Set(runs.map(\.conversationId))
        let tops = runs.filter { run in run.parent.map { !ids.contains($0) } ?? true }
        let rest = runs.filter { run in run.parent.map(ids.contains) ?? false }
        for run in tops + rest { engine.perform("abort", ["id": run.conversationId]) }
    }

    /// The agents' runs in these projects, or in every project and none when nil. A chat answering is not an agent's work
    /// and keeps its own Stop.
    @MainActor
    static func runs(in projects: Set<String>?, engine: EngineClient) -> [ActivityRun] {
        engine.activity.filter { run in
            run.chat != true && (projects.map { run.projectId.map($0.contains) == true } ?? true)
        }
    }
}

/// Stop All, asked for and waiting for the person to confirm it: from the Dashboard's line across all projects (the
/// projects it watches) or the palette (every agent's run).
struct StopAllRequest: Equatable {
    /// The projects whose runs it stops; nil for every agent's run.
    let projects: Set<String>?
}

extension View {
    /// The confirmation Stop All waits for, naming how many runs it stops, counted again as the runs come and go.
    func stopAllConfirmation(model: AppModel) -> some View {
        modifier(StopAllConfirmation(model: model))
    }
}

private struct StopAllConfirmation: ViewModifier {
    @Bindable var model: AppModel
    private var engine: EngineClient { model.engine }

    func body(content: Content) -> some View {
        let request = model.stoppingAll
        let count = request.map { RunStopping.runs(in: $0.projects, engine: engine).count } ?? 0
        content.confirmationDialog(
            count == 0 ? "Nothing is running now" : count == 1 ? "Stop 1 run?" : "Stop \(count) runs?",
            isPresented: Binding(get: { model.stoppingAll != nil }, set: { if !$0 { model.stoppingAll = nil } }),
            titleVisibility: .visible
        ) {
            if count > 0 {
                Button(count == 1 ? "Stop 1 Run" : "Stop \(count) Runs", role: .destructive) {
                    if let request { RunStopping.stop(RunStopping.runs(in: request.projects, engine: engine), engine: engine) }
                    model.stoppingAll = nil
                }
            }
            Button("Cancel", role: .cancel) { model.stoppingAll = nil }
        } message: {
            if count > 0 {
                Text(request?.projects == nil
                    ? "Every agent at work stops where it is, in every project, sub-chats included, and so do the commands they are running. Each conversation stays as it is and can be continued. Chats answering are left alone."
                    : "Every agent at work in the projects on the Dashboard stops where it is, sub-chats included, and so do the commands they are running. Each conversation stays as it is and can be continued.")
            }
        }
    }
}

// MARK: - The engine restarted

/// What an engine that started after an unclean stop found: the conversations it picked up, and the commands and
/// worktree set-ups it found cut off, with what became of each, and Dismiss (`recovery.dismiss`). Over the Dashboard or
/// a hub (#645), it is its headline and a line of counts until Details unfolds the rest, which then scrolls within a
/// space of its own rather than push the page below out of the window.
struct RecoveryNotice: View {
    let engine: EngineClient
    let recovery: RecoveryReport
    /// Shows a conversation: the one named, and the conversation in the sidebar it belongs to (the same, but for a
    /// sub-chat's command).
    let open: (_ conversation: Int, _ root: Int) -> Void
    @State private var unfolded = false
    @State private var detailsHeight: CGFloat = 0

    private var left: [RecoveryReport.LeftCommand] { recovery.background ?? [] }
    private var setups: [RecoveryReport.LeftSetup] { recovery.setups ?? [] }
    private var nothing: Bool { recovery.conversations.isEmpty && left.isEmpty && setups.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One line whatever the width, so that the page below keeps the window: the counts go first, then the
            // headline shortens, and the counts are in its help.
            ViewThatFits(in: .horizontal) {
                headline("The engine restarted after stopping unexpectedly (\(when))", counts: true)
                headline("The engine restarted after stopping unexpectedly (\(when))", counts: false)
                headline("The engine restarted (\(when))", counts: false)
            }
            if unfolded {
                ScrollView {
                    details
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
                }
                .frame(height: min(max(detailsHeight, 1), 200))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(fill: Theme.ok.opacity(0.08), border: Theme.ok.opacity(0.35))
    }

    private var when: String { Date(timeIntervalSince1970: recovery.at / 1000).formatted(date: .omitted, time: .shortened) }

    /// The headline on one line, with Details and Dismiss, and the counts beside it when they fit.
    private func headline(_ words: String, counts showsCounts: Bool) -> some View {
        HStack(spacing: 8) {
            Label(words, systemImage: "arrow.clockwise.circle.fill")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .help("The engine restarted after stopping unexpectedly (\(when)): \(counts)")
            if showsCounts {
                Text(counts).font(.callout).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 6)
            if !nothing {
                Button(unfolded ? "Hide Details" : "Details") { unfolded.toggle() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.acc)
                    .fixedSize()
                    .help(unfolded ? "Fold what was picked up and what was cut off" : "Show which conversations were picked up, and which commands and set-ups were cut off")
            }
            Button("Dismiss") { engine.perform("recovery.dismiss") }
                .buttonStyle(.piSecondary)
                .fixedSize()
                .help("Put this notice away")
        }
    }

    /// "2 picked up · 1 command and 1 set-up cut off", or that nothing was running.
    private var counts: String {
        if nothing { return "Nothing was running at the time; everything is as it was." }
        var parts: [String] = []
        if !recovery.conversations.isEmpty {
            parts.append(recovery.conversations.count == 1 ? "1 conversation picked up" : "\(recovery.conversations.count) conversations picked up")
        }
        let cut = [
            left.isEmpty ? nil : left.count == 1 ? "1 background command" : "\(left.count) background commands",
            setups.isEmpty ? nil : setups.count == 1 ? "1 set-up" : "\(setups.count) set-ups",
        ].compactMap(\.self)
        if !cut.isEmpty { parts.append("\(cut.joined(separator: " and ")) cut off") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if nothing {
                Text("Nothing was running at the time. Everything is as it was.").font(.callout).foregroundStyle(.secondary)
            }
            if !recovery.conversations.isEmpty {
                Text("These conversations were working and were picked up from where they stopped. A model request that was cut off is sent again; a shell command that was cut off is not run again, and its agent is told.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(recovery.conversations) { conversation in
                    Button(conversation.title.isEmpty ? "New conversation" : conversation.title) {
                        open(conversation.id, conversation.id)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.acc)
                }
            }
            if !left.isEmpty {
                Text(Self.leftIntro(left))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, recovery.conversations.isEmpty ? 0 : 4)
                ForEach(left) { command in
                    leftRow(title: command.title, conversation: command.conversationId, root: command.rootConversationId, command: command.command, outcome: command.outcome, group: command.group, background: true)
                }
            }
            if !setups.isEmpty {
                Text(Self.setupsIntro(setups))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, recovery.conversations.isEmpty && left.isEmpty ? 0 : 4)
                ForEach(setups) { setup in
                    leftRow(title: setup.title, conversation: setup.conversationId, root: setup.rootConversationId, command: setup.command, outcome: setup.outcome, group: setup.group, background: false)
                }
            }
        }
    }

    /// What the notice says of the commands agents had left running in the background when the engine stopped.
    static func leftIntro(_ left: [RecoveryReport.LeftCommand]) -> String {
        let intro = left.count == 1
            ? "An agent had left a command running in the background. It is not started again; its conversation has a line about it, and its agent is told."
            : "Agents had left commands running in the background. None is started again; each conversation has a line about it, and its agent is told."
        let unsure = left.contains { ["partly", "unsure", "unknown"].contains($0.outcome) }
        return unsure ? intro + " pi² leaves alone whatever it cannot be sure belongs to a command, so part of one may still be running." : intro
    }

    /// What the notice says of the worktrees' set-up commands that were running when the engine stopped.
    static func setupsIntro(_ setups: [RecoveryReport.LeftSetup]) -> String {
        let intro = setups.count == 1
            ? "A worktree’s set-up command was running. It is not run again; its conversation has a line about it, and its agent is told."
            : "Set-up commands were running in new worktrees. None is run again; each conversation has a line about it, and its agent is told."
        let unsure = setups.contains { ["partly", "unsure", "unknown"].contains($0.outcome) }
        return unsure ? intro + " pi² leaves alone whatever it cannot be sure belongs to a set-up, so part of one may still be running." : intro
    }

    /// One command the last engine left, in the background or setting up a worktree: its conversation, the command, and
    /// what became of it.
    private func leftRow(title: String, conversation: Int, root: Int, command: String, outcome: String, group: Int?, background: Bool) -> some View {
        let group = group.map { " (process group \($0))" } ?? ""
        let said: String
        switch outcome {
        case "stopped": said = "stopped"
        case "partly": said = "stopped in part; the rest may still be running\(group)"
        // A set-up that was not running any more had not finished: it was cut off.
        case "gone": said = background ? "had already ended" : "cut off"
        case "unsure", "unknown": said = "left alone; it may still be running\(group)"
        default: said = "ended"
        }
        let settled = outcome == "stopped" || outcome == "gone"
        return VStack(alignment: .leading, spacing: 1) {
            Button(title.isEmpty ? "New conversation" : title) {
                open(conversation, root)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.acc)
            .lineLimit(1).truncationMode(.tail)
            .help(background ? "Open the conversation that started it" : "Open the conversation whose worktree it was setting up")
            // The command is what gets cut short; what became of it keeps its size.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(command.split(whereSeparator: \.isNewline).joined(separator: " "))
                    .font(Theme.mono).foregroundStyle(Theme.tx2)
                    .lineLimit(1).truncationMode(.tail)
                    .help(command)
                Text("·").foregroundStyle(Theme.tx3)
                Text(said)
                    .font(.callout).foregroundStyle(settled ? Theme.tx2 : Theme.warn)
                    .fixedSize()
            }
        }
    }
}

/// The restart notice as a banner over the Dashboard or a project's hub, while there is one (#645): folded to a line,
/// with what it names opened where it lives (#644).
struct RecoveryBanner: View {
    let model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        if let recovery = engine.recovery {
            RecoveryNotice(engine: engine, recovery: recovery, open: { conversation, root in model.openConversation(conversation, from: root == conversation ? nil : root) })
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.window)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }

}
