import EngineKit
import PiModels
import SwiftUI

/// One schedule's row: its agent's mark, its name and what it does when, as the Mac's row says it. Tapping it edits it;
/// its swipe actions (and VoiceOver's actions) run it now, open its last run, turn it on or off, and delete it.
struct ScheduleRow: View {
    let schedule: Schedule
    let book: ScheduleBook
    let connected: Bool
    let edit: () -> Void
    let send: (SettingsRequest) -> Void

    @Environment(\.openRoute) private var openRoute
    @State private var confirmingDelete = false

    var body: some View {
        let agent = book.agent(book.runsAs(schedule))
        Button(action: edit) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                AgentMark(agent: agent, size: 28)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                VStack(alignment: .leading, spacing: 3) {
                    Text(schedule.title)
                        .foregroundStyle(.primary)
                    Text(book.detail(schedule))
                        .font(.subheadline)
                        .foregroundStyle(schedule.holdReason != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !book.isActive(schedule) {
                    Text(schedule.holdReason != nil ? "Held" : "Off")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(schedule.title). \(book.detail(schedule))")
        .accessibilityHint("Edits the schedule")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            Button("Run Now", systemImage: "play") { send(.runSchedule(schedule.id)) }
                .tint(.pi2Accent)
                .disabled(schedule.holdReason != nil || !connected)
        }
        .swipeActions(edge: .leading) {
            Button(schedule.enabled ? "Turn Off" : "Turn On", systemImage: schedule.enabled ? "pause" : "power") {
                send(.setSchedule(schedule, enabled: !schedule.enabled))
            }
            .tint(.gray)
            .disabled(!connected)
            if let last = book.lastRun(schedule) {
                Button("Last Run", systemImage: "bubble.left") { openRoute(.conversation(last)) }
                    .tint(.blue)
            }
        }
        .contextMenu {
            Button("Run Now", systemImage: "play") { send(.runSchedule(schedule.id)) }
                .disabled(schedule.holdReason != nil || !connected)
            if let last = book.lastRun(schedule) {
                Button("Open Last Run", systemImage: "bubble.left") { openRoute(.conversation(last)) }
            }
            Button("Edit", systemImage: "pencil", action: edit)
            Button(schedule.enabled ? "Turn Off" : "Turn On", systemImage: schedule.enabled ? "pause" : "power") {
                send(.setSchedule(schedule, enabled: !schedule.enabled))
            }
            .disabled(!connected)
            Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog("Delete “\(schedule.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { send(.deleteSchedule(schedule.id)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will not run again. Conversations its runs started stay as they are.")
        }
    }
}

/// What a schedule sheet is opened for: a new one, or one by its id.
enum ScheduleEditing: Identifiable, Hashable {
    case new
    case schedule(String)

    var id: String {
        switch self {
        case .new: "new"
        case .schedule(let id): id
        }
    }
}
