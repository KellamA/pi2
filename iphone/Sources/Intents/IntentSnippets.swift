
import SwiftUI

/// What Shortcuts and Siri show under an intent's words: the answer, the list of what waits, or what was stopped. Drawn
/// by the system from values alone, outside the app's window and its environment.

/// "Ask pi²": the message and the answer, or where the message is.
struct AskSnippet: View {
    let reply: AskOrchestrator.Reply

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let project = reply.project {
                IntentSnippetHeading(title: "\(project) · Orchestrator", systemImage: symbol, tint: tint)
            }
            if let message = reply.message, !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            switch reply.outcome {
            case .answered:
                Text(reply.answer ?? "")
                    .font(.body)
                    .lineLimit(24)
            case .stillWorking:
                Label("Still working on the answer. It will be in pi².", systemImage: "ellipsis.bubble")
                    .font(.callout)
            case .kept:
                Label("Waits in the mailbox for your Mac. The answer comes later, in pi².", systemImage: "tray.and.arrow.up")
                    .font(.callout)
            case .notSent:
                Text(reply.dialog)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private var symbol: String {
        switch reply.outcome {
        case .answered, .stillWorking: "bubble.left.and.text.bubble.right"
        case .kept: "moon.zzz"
        case .notSent: "exclamationmark.bubble"
        }
    }

    private var tint: Color {
        reply.outcome == .notSent ? .orange : .accentColor
    }
}

/// "What needs me": who asks, what, and where, as the Mac's menu bar item lists them.
struct NeedsSnippet: View {
    let reply: WhatNeedsMe.Reply

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let asOf = reply.asOf {
                Label(asOf, systemImage: "moon.zzz")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if reply.lines.isEmpty {
                IntentSnippetHeading(title: reply.dialog, systemImage: "checkmark.circle", tint: .green)
            }
            ForEach(reply.lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.who)
                        .font(.subheadline.weight(.semibold))
                    Text(line.what)
                        .font(.subheadline)
                        .lineLimit(2)
                    if !line.place.isEmpty {
                        Text(line.place)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if reply.more > 0 {
                Text("And \(reply.more) more in pi².")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

/// "Stop pi² in <project>": what came of it.
struct StopSnippet: View {
    let reply: StopProject.Reply

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let project = reply.project {
                IntentSnippetHeading(title: project, systemImage: symbol, tint: reply.refused > 0 ? .orange : .accentColor)
            }
            Text(reply.dialog)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private var symbol: String {
        if reply.refused > 0 { return "exclamationmark.octagon" }
        if reply.kept > 0 { return "moon.zzz" }
        return "stop.circle"
    }
}

/// A snippet's first line: a symbol and a title.
struct IntentSnippetHeading: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(title).font(.headline)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}
