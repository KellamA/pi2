import SwiftUI

/// The Outbox (docs/design/iphone.md, "The phone when the Mac is asleep or out of reach"): what the person wrote while
/// the Mac was out of reach, each saying whether it went. The entry view for the route `.outbox` (to be added to
/// `Route`, #680): `OutboxView()`. It reads the Outbox from the environment (`.environment(outbox)` at the root, beside
/// the session); without one, as before Face ID opens the session, it says the Outbox opens with Face ID.
///
/// Drawn `.inline` (`RouteView(.outbox, placement: .inline)`, for the projects list or a conversation), it is one line
/// that counts what waits, and nothing when nothing does.
struct OutboxView: View {
    @Environment(Outbox.self) private var outbox: Outbox?
    @Environment(\.placement) private var placement

    var body: some View {
        if let outbox {
            if placement == .inline {
                OutboxLine(outbox: outbox)
            } else {
                OutboxScreen(outbox: outbox)
            }
        } else if placement == .screen {
            ContentUnavailableView("The Outbox opens with Face ID", systemImage: "tray.and.arrow.up", description: Text("What you write while your Mac can't be reached is kept here until it takes it."))
                .navigationTitle("Outbox")
        }
    }
}

/// The Outbox as a screen of its own.
struct OutboxScreen: View {
    let outbox: Outbox
    /// An error from the last thing the person did here, in their words.
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Written while your Mac couldn't be reached. Each goes, oldest first, once it can be: answers and short messages through pi²'s relay while your Mac sleeps, the rest when it wakes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let problem {
                    Text(problem)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                if outbox.items.isEmpty {
                    ContentUnavailableView("Nothing waits for your Mac", systemImage: "tray", description: Text("What you write while it can't be reached waits here."))
                        .padding(.top, 40)
                } else {
                    ForEach(outbox.items) { item in
                        OutboxCard(item: item, problem: $problem, outbox: outbox)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Outbox")
    }
}

/// One item: what it is, what it says, and whether it went.
struct OutboxCard: View {
    let item: OutboxItem
    @Binding var problem: String?
    let outbox: Outbox

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(kindTitle, systemImage: kindSymbol)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(item.writtenAt, format: .dateTime.hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Written at \(item.writtenAt, format: .dateTime.hour().minute())"))
            }
            Text(item.summary)
                .font(.body)
                .lineLimit(item.kind == .message ? 6 : 2)
                .textSelection(.enabled)
            OutboxStateLine(state: item.state, widens: item.widens)
            if case .notSent = item.state {
                HStack(spacing: 12) {
                    Button("Send again") { act { try outbox.sendAgain(item.id) } }
                        .buttonStyle(.borderedProminent)
                    Button("Remove", role: .destructive) { act { try outbox.remove(item.id) } }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
            } else if item.state == .waiting {
                Button("Remove", role: .destructive) { act { try outbox.remove(item.id) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private var kindTitle: String {
        switch item.kind {
        case .message: "Message"
        case .stop: "Stop"
        case .answer: "Answer"
        }
    }

    private var kindSymbol: String {
        switch item.kind {
        case .message: "text.bubble"
        case .stop: "stop.circle"
        case .answer: "checkmark.bubble"
        }
    }

    private func act(_ change: () throws -> Void) {
        do {
            try change()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Whether an item went, in a line.
struct OutboxStateLine: View {
    let state: OutboxItem.State
    let widens: Bool

    var body: some View {
        switch state {
        case .waiting:
            Label(widens ? "Waiting for your Mac. It can take this for an hour after you wrote it." : "Waiting for your Mac. It can take this for a day after you wrote it.", systemImage: "clock")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .sending:
            Label("Sending…", systemImage: "arrow.up.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .inMailbox(let since):
            Label {
                Text("In pi²'s relay since \(since, format: .dateTime.hour().minute()): your Mac takes it when it wakes.")
            } icon: {
                Image(systemName: "tray.and.arrow.up")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .notSent(let why):
            Label(why, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }
}

/// The Outbox drawn inside another screen: one line counting what waits, or nothing.
struct OutboxLine: View {
    let outbox: Outbox

    var body: some View {
        let waiting = outbox.waitingCount
        let notSent = outbox.items.filter { if case .notSent = $0.state { true } else { false } }.count
        if waiting > 0 || notSent > 0 {
            HStack(spacing: 8) {
                Image(systemName: notSent > 0 ? "exclamationmark.triangle" : "tray.and.arrow.up")
                    .foregroundStyle(notSent > 0 ? .orange : .secondary)
                    .accessibilityHidden(true)
                Text(Self.words(waiting: waiting, notSent: notSent))
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
        }
    }

    static func words(waiting: Int, notSent: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append(waiting == 1 ? "1 waits for your Mac" : "\(waiting) wait for your Mac") }
        if notSent > 0 { parts.append("\(notSent) not sent") }
        return "Outbox: " + parts.joined(separator: ", ")
    }
}
