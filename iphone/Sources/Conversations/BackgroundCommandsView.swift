import EngineKit
import PiModels
import SwiftUI

/// The background commands: a list, one's output read on a screen of its own, and Stop (docs/design/iphone.md, "Every
/// screen and function of the Mac app": background commands and their output window, another shape). A command's output
/// opens with `openRoute(.backgroundCommands(output: id))`, which this same view draws.
struct BackgroundCommandsView: View {
    /// The command whose output it shows, as `BackgroundCommand.id`; nil for the list.
    let commandID: String?

    init(commandID: String? = nil) {
        self.commandID = commandID
    }

    var body: some View {
        if let commandID {
            BackgroundCommandsOutputPage(id: commandID)
        } else {
            BackgroundCommandsList()
        }
    }
}

/// Every command agents left running in the background, oldest first as the engine lists them, with its clock and Stop.
private struct BackgroundCommandsList: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @State private var problem: String?
    /// The commands Stop was pressed for: each stays, marked, until the engine says it is gone.
    @State private var stopping: Set<String> = []

    private var engine: EngineSession<MessageField> { session.engine }

    private var rows: [BackgroundCommandsRow] {
        #if DEBUG
        if let sample = ConversationsSample.current?.commands { return sample }
        #endif
        return BackgroundCommandsRow.read(engine.backgroundCommands, conversations: engine.conversations, agents: engine.allAgents)
    }

    private var isSample: Bool {
        #if DEBUG
        return ConversationsSample.current?.commands != nil
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if !isSample, engine.status != .connected || !engine.hasLoadedLibrary {
                ConversationsWaiting()
            } else {
                list(rows)
            }
        }
        .navigationTitle("Background commands")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .task(id: engine.hasLoadedLibrary) {
            guard engine.hasLoadedLibrary || isSample else { return }
            if await ConversationsSample.take("stop", in: session), let first = rows.first { stop(first) }
        }
        #endif
    }

    private func list(_ rows: [BackgroundCommandsRow]) -> some View {
        List {
            if isSample {
                ConversationsSampleNote()
            }
            if let problem {
                ConversationsProblemRow(message: problem) { self.problem = nil }
            }
            if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing running in the background", systemImage: "terminal",
                    description: Text("When an agent starts a command that goes on while it does other things, such as a server or a long build, it is listed here, where you can read its output and stop it.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(rows) { row in
                        Button { openRoute(.backgroundCommands(output: row.id)) } label: {
                            BackgroundCommandsRowView(row: row, stopping: stopping.contains(row.id))
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) { stopButton(row) }
                        .contextMenu {
                            Button("Output", systemImage: "text.alignleft") { openRoute(.backgroundCommands(output: row.id)) }
                            Button("Open the conversation", systemImage: "bubble.left") { openRoute(.conversation(row.rootConversationId)) }
                            stopButton(row)
                        }
                    }
                } footer: {
                    Text("Stop ends a command and everything it started. The agent that started it is told when it ends.")
                }
            }
        }
        .onChange(of: rows.map(\.id)) { _, ids in stopping.formIntersection(ids) }
    }

    private func stopButton(_ row: BackgroundCommandsRow) -> some View {
        Button("Stop", systemImage: "stop.fill", role: .destructive) { stop(row) }
            .disabled(stopping.contains(row.id))
    }

    private func stop(_ row: BackgroundCommandsRow) {
        stopping.insert(row.id)
        Task {
            if let failure = await ConversationsRequests.stopCommand(engine, command: row.id) {
                stopping.remove(row.id)
                problem = "\(row.id) was not stopped: \(failure)"
            }
        }
    }
}

/// One command: what it runs, whose it is and where, and how long it has run.
private struct BackgroundCommandsRowView: View {
    let row: BackgroundCommandsRow
    let stopping: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text(row.oneLine)
                    .font(.body.monospaced())
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                Text(row.source)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                HStack(spacing: 6) {
                    Text(stopping ? "stopping" : row.id)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(stopping ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(stopping ? Color.orange : Color.secondary)
                    // "for 6:15", as its output page says it: alone, "6:15" reads as a time of day.
                    Text("for \(BackgroundCommandsClock.text(since: row.startedAt, until: context.date))")
                        .monospacedDigit()
                    Text("· \(row.folder)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(row.oneLine), \(row.id), in \(row.source), folder \(row.folder)")
            .accessibilityValue(stopping ? "stopping" : "running for \(BackgroundCommandsClock.spoken(since: row.startedAt, until: context.date))")
            .accessibilityHint("Opens its output")
            .accessibilityAddTraits(.isButton)
        }
    }
}
