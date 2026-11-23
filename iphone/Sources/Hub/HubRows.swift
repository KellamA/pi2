import EngineKit
import PiModels
import SwiftUI

// The rows a hub's Now tab and a Dashboard page both show: who is working, and what finished today, as the Mac's
// `WorkingRow` and `FinishedRow` show them (app/Sources/pi2/ProjectNowTab.swift), laid out for a phone's list.

/// One agent working in the project: its mark and name, its model, how long, its last line and the shell command it
/// waits on. Tapping it opens its conversation; Stop is a swipe and a context menu away, and a VoiceOver action. Whether
/// it waits for the person or for a provider's limit shows in place of the spinner.
struct HubWorkingRow: View {
    let engine: EngineSession<MessageField>
    let run: ActivityRun
    /// Whether Stop was asked for and the run has not ended yet.
    let stopping: Bool
    let open: () -> Void
    let stop: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var agent: AgentProfile? { engine.agent(run.runsAs ?? run.agentId ?? "") }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                AgentMark(agent: agent, maximum: 40)
                VStack(alignment: .leading, spacing: 3) {
                    // Side by side; one under another at the largest sizes, where the line cannot hold them.
                    let line = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                    line {
                        Text(agent?.name ?? "An agent")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let model = engine.hubModelName(agent: run.runsAs ?? run.agentId) {
                            Text(model)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        }
                        if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
                        clock
                    }
                    if !run.title.isEmpty {
                        Text(run.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let line = run.lastLine, !line.isEmpty {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let command = run.commands?.first {
                        Text(command.command)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    state
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(stopping ? "Stopping" : "Stop", systemImage: "stop.fill", role: .destructive, action: stop)
                .disabled(stopping)
        }
        .contextMenu {
            Button("Open Conversation", systemImage: "bubble.left", action: open)
            Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
                .disabled(stopping)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(agent?.name ?? "the agent")’s conversation.")
        .accessibilityAction(named: "Stop", stop)
    }

    /// How long it has worked, ticking, after a spinner while it works.
    private var clock: some View {
        HStack(spacing: 5) {
            if working {
                ProgressView()
                    .controlSize(.mini)
                    // On the line of the name, as the text beside it is.
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    .accessibilityLabel("Working")
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(HubClock.text(since: run.since, now: context.date))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(HubClock.spoken(since: run.since, now: context.date))
            }
        }
    }

    /// Working, rather than waiting for the person or a limit, or being stopped.
    private var working: Bool { !stopping && run.status != "waiting" && run.limit == nil }

    /// Waiting for the person, for a provider's limit, or being stopped; nothing while it works.
    @ViewBuilder
    private var state: some View {
        if stopping {
            Label("Stopping", systemImage: "stop.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if run.status == "waiting" {
            Label("Waits for you", systemImage: "exclamationmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(HubTone.warn)
        } else if let limit = run.limit {
            Label(limit.sentence, systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(HubTone.warn)
        }
    }
}

/// One run that ended today: which agent, on what, how it ended and when, and a mark on what the orchestrator has not
/// read yet.
struct HubFinishedRow: View {
    let engine: EngineSession<MessageField>
    let report: HubReport

    @Environment(\.dynamicTypeSize) private var typeSize

    private var agent: AgentProfile? { engine.agent(report.agentId) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentMark(agent: agent, maximum: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.title.isEmpty ? (agent?.name ?? "An agent") : report.title)
                    .font(.body)
                let line = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
                    : AnyLayout(HStackLayout(spacing: 6))
                line {
                    HubTag(text: report.outcomeWord, tone: tone)
                    Text(agent?.name ?? "An agent")
                    if let endedAt = report.endedAt {
                        if !typeSize.isAccessibilitySize { Text("·") }
                        Text(endedAt, format: .dateTime.hour().minute())
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if report.deliveredBy == nil {
                    HubTag(text: "not read yet", tone: HubTone.warn)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tone: Color {
        switch report.outcome {
        case "answered": HubTone.ok
        case "failed": .red
        case "stopped": HubTone.warn
        default: .secondary
        }
    }
}

/// A word in a tinted capsule: an outcome, or "not read yet".
struct HubTag: View {
    let text: String
    let tone: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tone.opacity(0.15), in: Capsule())
    }
}

/// What the engine said when a request was refused or could not be sent, where it was asked.
struct HubProblem: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }
}

/// A quiet line where a section has nothing to say.
struct HubQuietLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// The orange and green the rows' words are written in: the system's in dark, darker in light, so that a word in them
/// reads against a white row as well as against a black one.
enum HubTone {
    static let warn = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemOrange : UIColor(red: 0.70, green: 0.38, blue: 0.0, alpha: 1)
    })
    static let ok = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0.11, green: 0.50, blue: 0.24, alpha: 1)
    })
}
