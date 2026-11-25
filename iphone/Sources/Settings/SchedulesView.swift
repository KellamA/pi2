import EngineKit
import PiModels
import SwiftUI

/// The schedules, as the Mac has them, from More on the projects list (docs/design/iphone.md, "Every screen and function
/// of the Mac app": as it is). The Mac lists each project's on its Settings tab and each template's on its page; the
/// phone lists them all on one screen, by project, with the templates' last. Each can be run now, turned on or off,
/// edited and deleted, and a new one made, as on the Mac (`schedules.runNow`, `.save`, `.delete`).
struct SchedulesView: View {
    init() {}

    @Environment(AppSession.self) private var session
    @Environment(\.placement) private var placement
    @State private var editing: ScheduleEditing?
    @State private var problems = SettingsProblems()

    var body: some View {
        let source = SettingsSource(session)
        let book = source.book
        let groups = book.groups
        List {
            if SettingsConnectionLine(connected: source.connected, connection: session.connection).shows || !source.samples.isEmpty || problems["list"] != nil {
                Section {
                    SettingsConnectionLine(connected: source.connected, connection: session.connection)
                    #if DEBUG
                    SettingsSamples.note(source)
                    #endif
                    SettingsProblem(text: problems["list"])
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.schedules) { schedule in
                        ScheduleRow(schedule: schedule, book: book, connected: source.connected, edit: { editing = .schedule(schedule.id) }) { request in
                            request.send(through: session.engine, row: "list", into: $problems)
                        }
                    }
                } header: {
                    Text(group.title)
                }
            }
            if !groups.isEmpty {
                Section {
                } footer: {
                    Text("Each run starts a new conversation with its agent, which works with no one watching. Swipe a schedule to run it now or turn it off. An agent that may schedule its own work asks you before each schedule it sets.")
                }
            }
        }
        .listStyle(.insetGrouped)
        #if DEBUG
        // Once the Mac is reached as well as the schedule listed: drawn first from the phone's last state, a change would
        // only be refused.
        .task(id: source.connected ? groups.first?.schedules.first?.id : nil) {
            guard source.connected, let first = groups.first?.schedules.first else { return }
            let request: SettingsRequest? =
                if SettingsSamples.shouldPress("run") { .runSchedule(first.id, title: first.title) }
                else if SettingsSamples.shouldPress("pause") { .setSchedule(first, enabled: !first.enabled) }
                else if SettingsSamples.shouldPress("delete") { .deleteSchedule(first.id, title: first.title) }
                else { nil }
            request?.send(through: session.engine, row: "list", into: $problems)
        }
        .onChange(of: book.everyAgent.isEmpty, initial: true) { _, empty in
            guard !empty, let open = SettingsSamples.open, !SettingsSamples.opened else { return }
            SettingsSamples.opened = true
            editing = open == "new" ? .new : .schedule(open)
        }
        #endif
        .overlay {
            if groups.isEmpty {
                if !source.connected {
                    ProgressView("Waiting for your Mac…")
                } else {
                    ContentUnavailableView {
                        Label("No schedules", systemImage: "calendar.badge.clock")
                    } description: {
                        Text("Have an agent start a conversation on its own: every morning, every hour, or once at a set time.")
                    } actions: {
                        Button("New Schedule") { editing = .new }
                            .buttonStyle(.borderedProminent)
                            .disabled(book.everyAgent.isEmpty || !source.connected)
                    }
                }
            }
        }
        .navigationTitle("Schedules")
        .navigationBarTitleDisplayMode(placement == .screen ? .large : .inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Schedule", systemImage: "plus") { editing = .new }
                    .disabled(book.everyAgent.isEmpty || !source.connected)
            }
        }
        .sheet(item: $editing) { editing in
            switch editing {
            case .new:
                ScheduleEditor(original: nil, agents: book.everyAgent, book: book)
                    .environment(session)
            case .schedule(let id):
                if let schedule = book.schedules.first(where: { $0.id == id }) {
                    ScheduleEditor(original: schedule, agents: book.everyAgent, book: book)
                        .environment(session)
                } else {
                    ContentUnavailableView("This schedule is gone", systemImage: "calendar.badge.exclamationmark", description: Text("It was deleted on the Mac or by another device."))
                }
            }
        }
    }
}
