import SwiftUI

/// The agent's task list for the conversation, pinned above the message field.
///
/// Nothing when there is no list. Otherwise one line with a ring, the count and the step in hand; opened, the whole
/// checklist. When every step is done and the agent has stopped, it says so quietly and can be dismissed.
struct PlanStrip: View {
    let engine: EngineClient
    let id: Int
    let state: ConversationState?

    @State private var expanded = false
    /// The version of the list the person dismissed. A new list has a new version and shows again.
    @State private var dismissed: Double?

    var body: some View {
        if let plan = state?.plan, !plan.items.isEmpty, dismissed != plan.updatedAt {
            let finished = plan.isFinished && state?.busy != true
            VStack(alignment: .leading, spacing: 0) {
                header(plan, finished: finished)
                if expanded && !finished {
                    Divider().overlay(Theme.line).padding(.top, 8)
                    checklist(plan)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .panel(radius: 10, fill: Theme.card, border: Theme.line2)
            .padding(.horizontal, 28).padding(.top, 8)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: expanded)
            .animation(.easeInOut(duration: 0.2), value: plan)
        }
    }

    private func header(_ plan: TaskList, finished: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    ring(plan)
                    if finished {
                        Text("All \(plan.items.count) done").foregroundStyle(Theme.tx3)
                    } else {
                        Text("\(plan.doneCount) of \(plan.items.count)").foregroundStyle(Theme.tx2).monospacedDigit()
                        if let current = plan.current {
                            Text(current.content).foregroundStyle(Theme.tx).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                    if !finished {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.tx3)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(finished)
            .accessibilityLabel(summary(plan, finished: finished))
            .accessibilityHint(finished ? "" : (expanded ? "Hides the whole list" : "Shows the whole list"))
            .help(finished ? "Everything on the list is done" : (expanded ? "Hide the whole task list" : "Show the whole task list"))
            if finished {
                Button("Dismiss", systemImage: "xmark") {
                    withAnimation(.easeInOut(duration: 0.2)) { dismissed = plan.updatedAt }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.tx3)
                .help("Hide the task list. A new list shows again.")
            }
        }
        .font(.system(size: 12.5))
    }

    private func summary(_ plan: TaskList, finished: Bool) -> String {
        if finished { return "Task list: all \(plan.items.count) done" }
        let now = plan.current.map { ", now: \($0.content)" } ?? ""
        return "Task list: \(plan.doneCount) of \(plan.items.count) done\(now)"
    }

    private func ring(_ plan: TaskList) -> some View {
        let fraction = plan.items.isEmpty ? 0 : Double(plan.doneCount) / Double(plan.items.count)
        return ZStack {
            Circle().stroke(Theme.line2, lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(plan.isFinished ? Theme.ok : Theme.acc, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }

    private func checklist(_ plan: TaskList) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(plan.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        mark(item.state).frame(width: 12, height: 12).padding(.top, 2)
                        Text(item.content)
                            .foregroundStyle(item.state == .completed ? Theme.tx3 : Theme.tx)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.content), \(item.state.words)")
                }
            }
            .font(.system(size: 12.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func mark(_ step: TaskItem.Step) -> some View {
        switch step {
        case .completed:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tx3)
        case .inProgress:
            Spinner(size: 10)
        case .pending:
            Circle().stroke(Theme.line2, lineWidth: 1.5).frame(width: 9, height: 9)
        }
    }
}
