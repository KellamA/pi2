import AppKit
import SwiftUI

// Models run on this Mac (#291, part of #173): what the conversation, Activity and the menu bar show of them. The engine
// starts and stops them (engine/src/localrun.ts); the app says which conversations it shows, sees what runs, and can stop
// one. See docs/local-models-running.md.

/// What a conversation whose model runs on this Mac is told of it: whether it is loading, loaded, stopped or failed.
struct LocalModelState: Codable, Equatable {
    let name: String
    /// "starting", "ready", "stopping", "stopped" or "failed".
    let status: String
    /// Since when it is in that state (milliseconds since 1970), when known.
    let since: Double?
    /// How far loading has got, 0 to 1, when the engine says.
    let progress: Double?
    /// What the engine says it is doing while it loads, in its own words ("mapping the experts").
    let stage: String?
    /// Why it could not start, or why it stopped, when it failed.
    let error: String?
    /// The last lines of its log, when it failed.
    let lines: [String]?
    let log: String?
}

/// A model running on this Mac, as the engine's `local.running` event lists it.
struct LocalServer: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    /// "starting", "ready" or "stopping".
    let status: String
    let startedAt: Double
    let readyAt: Double?
    let progress: Double?
    let stage: String?
    /// Bytes its processes hold in memory, at the engine's last look: its own and those it started.
    let memory: Double?
    /// The conversations using it.
    let users: [Int]
    /// When it stops for want of anyone using it, while that is counting down.
    let stopsAt: Double?
    let log: String
}

struct LocalRunningEvent: Decodable { let running: [LocalServer] }

enum LocalModels {
    /// "63.2 GB": memory as the person reads it.
    static func memory(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// "loaded since 14:05", "loading, 40%": a running model's state in a few words.
    static func standing(_ server: LocalServer) -> String {
        switch server.status {
        case "starting": server.progress.map { "loading, \(Int(($0 * 100).rounded()))%" } ?? server.stage.map { "loading: \($0)" } ?? "loading"
        case "stopping": "stopping"
        default: "loaded since \(Date(timeIntervalSince1970: (server.readyAt ?? server.startedAt) / 1000).formatted(date: .omitted, time: .shortened))"
        }
    }

    /// "0:42": how long until `end` (milliseconds since 1970).
    static func remaining(until end: Double, from now: Date) -> String {
        let seconds = max(0, Int((end / 1000 - now.timeIntervalSince1970).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func showLog(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

/// Above the message field of a conversation whose model runs on this Mac: that it is loading, how far, that a message
/// sent now waits for it; why it could not start, with the end of its log; or that it is not loaded.
struct LocalModelStrip: View {
    let state: LocalModelState?
    var inset: CGFloat = 28

    var body: some View {
        if let state, let shown = shown(state) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if state.status == "starting" || state.status == "stopping" {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: state.status == "failed" ? "exclamationmark.triangle.fill" : "cpu")
                            .foregroundStyle(state.status == "failed" ? Theme.bad : Theme.tx2)
                    }
                    if state.status == "starting", let since = state.since {
                        // How long it has been loading, ticking: a first start takes minutes, and a clock shows it is not stuck.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = max(0, Int(context.date.timeIntervalSince1970 - since / 1000))
                            Text(shown.replacingOccurrences(of: "{elapsed}", with: String(format: "%d:%02d", seconds / 60, seconds % 60)))
                                .foregroundStyle(Theme.tx).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(shown.replacingOccurrences(of: " ({elapsed})", with: "")).foregroundStyle(Theme.tx).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if state.status == "failed", let log = state.log {
                        Button("Show Log") { LocalModels.showLog(log) }
                            .buttonStyle(PiButtonStyle(kind: .secondary, compact: true))
                            .help("Open what the engine printed: \(log)")
                    }
                }
                if state.status == "starting", let progress = state.progress {
                    ProgressView(value: progress).progressViewStyle(.linear)
                }
                if state.status == "failed", let lines = state.lines, !lines.isEmpty {
                    Text(lines.joined(separator: "\n"))
                        .font(Theme.mono).foregroundStyle(Theme.tx2)
                        .lineLimit(6).textSelection(.enabled)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .panel(fill: state.status == "failed" ? Theme.bad.opacity(0.08) : Theme.panel, border: state.status == "failed" ? Theme.bad.opacity(0.35) : Theme.line)
            .padding(.horizontal, inset).padding(.top, 8)
            .transition(.opacity)
        }
    }

    /// What to say, or nil when there is nothing worth a line: a loaded model needs none.
    private func shown(_ state: LocalModelState) -> String? {
        switch state.status {
        case "starting":
            let percent = state.progress.map { " (\(Int(($0 * 100).rounded()))%)" } ?? ""
            let stage = state.stage.map { ": \($0)" } ?? ""
            return "Starting \(state.name) on this Mac ({elapsed})\(percent)\(stage). A message sent now is answered once it has loaded. The first start after setting it up can take about three minutes; later starts about 20 seconds."
        case "stopping": return "Stopping \(state.name)…"
        case "failed": return "\(state.name) could not run on this Mac: \(state.error ?? "it stopped unexpectedly"). Your next message tries again."
        case "stopped" where state.since != nil: return "\(state.name) is not loaded. Your next message starts it on this Mac."
        default: return nil
        }
    }
}

/// Activity's section for models running on this Mac: each with since when, how much memory, who uses it, and Stop.
struct LocalModelsActivity: View {
    let model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Models on this Mac").font(.headline)
            Text("A model starts when a conversation that uses it is opened or set working, and stops a minute after none is. Stopping one here does not break the conversations using it: their next message starts it again.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(engine.localRunning) { server in
                LocalServerRow(model: model, server: server)
            }
        }
    }
}

private struct LocalServerRow: View {
    let model: AppModel
    let server: LocalServer
    private var engine: EngineClient { model.engine }

    private var detail: String {
        var parts = [LocalModels.standing(server)]
        // Resident memory, as `ps` counts it: the model's file, mapped and kept in memory for the GPU, is most of it. Activity
        // Monitor's Memory column counts only what each process holds of its own (about 15 GB of the 60 for IQ3_S).
        if let memory = server.memory { parts.append("\(LocalModels.memory(memory)) in memory, its file included") }
        if server.users.isEmpty {
            if server.stopsAt != nil { parts.append("no conversation is using it") }
        } else {
            parts.append(server.users.count == 1 ? "used by 1 conversation" : "used by \(server.users.count) conversations")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.tx2)
                .frame(width: 22, height: 22)
                .background(Theme.line2.opacity(0.5), in: .rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).lineLimit(1)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.tx3).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let stopsAt = server.stopsAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("stops in \(LocalModels.remaining(until: stopsAt, from: context.date))")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.tx2)
                }
                .fixedSize()
            }
            if let first = server.users.first {
                Button("Open") { model.openConversation(engine.conversations.first { $0.id == first }?.parent ?? first) }
                    .buttonStyle(PiButtonStyle(kind: .secondary, compact: true))
                    .fixedSize()
                    .help("Open a conversation using it")
            }
            Button("Log") { LocalModels.showLog(server.log) }
                .buttonStyle(PiButtonStyle(kind: .secondary, compact: true))
                .fixedSize()
                .help("Open what the engine has printed: \(server.log)")
            Button("Stop", systemImage: "stop.fill") { engine.perform("local.stop", ["id": server.id]) }
                .labelStyle(.iconOnly)
                .buttonStyle(PiButtonStyle(kind: .danger, compact: true))
                .disabled(server.status == "stopping")
                .fixedSize()
                .help("Unload this model. The conversations using it start it again with their next message.")
        }
        .padding(10)
        .panel()
    }
}

/// The menu bar's row for a model running on this Mac: its name, how it stands and its memory, with Stop.
struct LocalServerMenuRow: View {
    let engine: EngineClient
    let server: LocalServer
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").font(.system(size: 11)).foregroundStyle(Theme.tx2).frame(width: 16)
                    Text(server.name).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Text([LocalModels.standing(server), server.memory.map(LocalModels.memory)].compactMap(\.self).joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.tx2).lineLimit(1).fixedSize()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show it in Activity")
            Button("Stop", systemImage: "stop.fill") { engine.perform("local.stop", ["id": server.id]) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.bad)
                .disabled(server.status == "stopping")
                .help("Unload this model. The conversations using it start it again with their next message.")
        }
    }
}
