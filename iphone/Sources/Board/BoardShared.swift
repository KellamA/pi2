
import SwiftUI

extension AppSession {
    /// What the board's pages read, from the engine; in a debug build launched with `PI2_BOARD_SAMPLE`, with the sample
    /// values of `BoardSample` laid over it, which the pages say they show.
    var boardData: BoardData {
        var data = BoardData(engine)
        #if DEBUG
        BoardSample.overlay(&data)
        #endif
        return data
    }
}

/// What a board page shows when what it was opened on is not among the Mac's: while the engine's lists are still
/// coming, a wait; once they have come, that the Mac has no such thing now.
struct BoardMissing: View {
    let waiting: Bool
    let title: String
    let description: String

    var body: some View {
        if waiting {
            ProgressView("Waiting for your Mac…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(title, systemImage: "questionmark.circle", description: Text(description))
        }
    }
}

/// The engine's words when a change was refused, or could not be sent, beside what was changed.
struct BoardProblem: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Not done: \(text)")
    }
}

/// A row that opens another screen, with the chevron a list's navigation row has: through `openRoute`, never by naming
/// the screen's view (docs/iphone-app.md).
struct BoardLinkRow<Label: View>: View {
    let route: Route
    @ViewBuilder let label: Label
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        Button {
            openRoute(route)
        } label: {
            HStack(spacing: 8) {
                label
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .foregroundStyle(.primary)
    }
}

/// A small word beside a name: "Orchestrator", "working", "allows everything".
struct BoardTag: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: .capsule)
    }
}

/// Said at the top of a page a debug build draws with sample values, so that nobody takes them for the Mac's.
struct BoardSampleNote: View {
    let what: String

    var body: some View {
        Label("Sample data, drawn by a debug build: \(what). None of it came from a Mac.", systemImage: "testtube.2")
            .font(.footnote)
            .foregroundStyle(.orange)
    }
}

/// Runs a request that answers nil or the engine's words, and keeps those words for the row that asked.
@MainActor
func boardSend(_ problem: Binding<String?>, _ request: @escaping @MainActor () async -> String?) {
    Task { @MainActor in
        problem.wrappedValue = await request()
    }
}
