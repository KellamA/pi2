import AppKit
import SwiftUI

/// What the app knows about an engine that keeps failing to start: shown in the window until an engine answers.
struct EngineStartProblem: Equatable {
    /// Starts tried since the app last reached an engine.
    var attempts: Int
    /// Why the app itself could not start the engine, when it could not (Node or the engine not where the build said).
    var reason: String?
    /// How the last engine the app started ended, such as "exited with status 1". Nil when the login item started it.
    var lastExit: String?
    /// The end of engine.log when this was written.
    var logTail: String
    var checkedAt: Date
}

/// Across the top of the window while the engine cannot be started: that it cannot, what its log ends with, and what
/// to do about it. It goes away by itself once an engine answers.
struct EngineTroubleBanner: View {
    let engine: EngineClient

    var body: some View {
        if let problem = engine.startProblem {
            VStack(alignment: .leading, spacing: 8) {
                Label("The engine could not be started", systemImage: "exclamationmark.octagon.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.bad)
                // No fixedSize on these texts: inside the window's top inset it stopped the whole window drawing.
                Text(summary(problem))
                    .font(.callout).foregroundStyle(Theme.tx2)
                // When the app could not run the engine at all, nothing new is in the log, so its end would mislead.
                if problem.reason == nil, !problem.logTail.isEmpty {
                    Text("The end of engine.log:").font(.caption).foregroundStyle(Theme.tx3)
                    ScrollView {
                        Text(problem.logTail)
                            .font(Theme.mono)
                            .foregroundStyle(Theme.tx2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(maxHeight: 130)
                    .panel(radius: 7, fill: Theme.window)
                }
                Text(advice(problem))
                    .font(.callout).foregroundStyle(Theme.tx2)
                HStack(spacing: 8) {
                    Button("Try Again") { engine.tryStartingAgain() }
                        .buttonStyle(.piPrimary)
                        .help("Start the engine now instead of waiting for the next try")
                    Button("Show engine.log in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([engine.dataFolder.appendingPathComponent("engine.log")])
                    }
                    .buttonStyle(.piSecondary)
                    Spacer(minLength: 0)
                    Text("Last tried \(problem.checkedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(Theme.tx3)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(fill: Theme.bad.opacity(0.08), border: Theme.bad.opacity(0.35))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.window)
        }
    }

    private func summary(_ problem: EngineStartProblem) -> String {
        var text = "pi² has tried to start its engine \(problem.attempts) times since it last reached one, and each time it stopped before it could be used."
        if let reason = problem.reason {
            text = "pi² cannot start its engine. \(reason)"
        } else if let exit = problem.lastExit {
            text += " The last one \(exit)."
        }
        return text + " Until it runs, conversations cannot be opened or sent. pi² keeps trying in the background, less often as time goes on."
    }

    private func advice(_ problem: EngineStartProblem) -> String {
        let start = problem.reason == nil ? "The log usually says why. " : ""
        if EngineClient.isSelfContained {
            return "\(start)If it keeps failing, install pi² again from its latest release; your conversations are kept in the data folder, not in the app."
        }
        return "\(start)This development build runs Node and the engine from where it was built: check that Node is still installed, that the checkout is still there with its packages (npm ci in engine/), or build the app again with app/build.sh."
    }
}
