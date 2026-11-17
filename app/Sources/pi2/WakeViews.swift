import SwiftUI

// What will wake a conversation's agent when it ends, above its message field: sub-chats handed work without waiting,
// and background commands started with `wake`. Each with Don't Wake, and the whole strip too; after the person's Stop,
// a way to let the agent be woken again without sending a message. See docs/wakes.md.

struct WakeStrip: View {
    let engine: EngineClient
    let id: Int
    var inset: CGFloat = 28

    private var items: [WakeItem] { engine.wakes.filter { $0.conversationId == id } }
    private var hold: WakeHold? { engine.wakeHolds.first { $0.conversationId == id } }

    /// Why the agent is not woken for now, in words; nil when it will be.
    private func held(_ hold: WakeHold?) -> String? {
        switch hold?.why {
        case "stopped": return "Paused because you stopped the agent: it is woken after your next message."
        case "budget": return "Waiting: today's budget is used up."
        case "cap":
            let until = hold?.until.map { " until \(Date(timeIntervalSince1970: $0 / 1000).formatted(date: .omitted, time: .shortened))" } ?? ""
            return "Woken as often as it may be this hour: what ends waits\(until), or until your next message."
        default: return nil
        }
    }

    var body: some View {
        let items = items
        if !items.isEmpty {
            let hold = hold
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(items.count == 1 ? "Wakes the agent when it ends" : "Wakes the agent when these end")
                        .font(Theme.label).foregroundStyle(Theme.tx3)
                        .textCase(.uppercase)
                    Spacer()
                    if hold?.why == "stopped" {
                        Button("Wake When Done") { engine.perform("wakes.resume", ["conversationId": id]) }
                            .buttonStyle(PiButtonStyle(kind: .secondary, compact: true))
                            .help("Let the agent be woken again without sending a message")
                    }
                    if items.count > 1 {
                        Button("Don't Wake") { engine.perform("wakes.cancel", ["conversationId": id]) }
                            .buttonStyle(PiButtonStyle(kind: .secondary, compact: true))
                            .help("The agent is not woken for any of these. They keep running; what a sub-chat answers stays in it.")
                    }
                }
                if let note = held(hold) {
                    Text(note).font(.system(size: 12)).foregroundStyle(Theme.warn)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items) { item in WakeStripRow(engine: engine, item: item) }
                    }
                }
                .frame(maxHeight: 96)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .panel(radius: 10, fill: Theme.card, border: Theme.line2)
            .padding(.horizontal, inset).padding(.top, 8)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: items)
        }
    }
}

private struct WakeStripRow: View {
    let engine: EngineClient
    let item: WakeItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind == "subchat" ? "bubble.left.and.bubble.right" : "terminal")
                .font(.system(size: 11)).foregroundStyle(Theme.tx2)
            Text(item.label)
                .foregroundStyle(Theme.tx)
                .lineLimit(1).truncationMode(.tail)
                .help(item.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.state == "arrived" {
                Tag("ended", .acc).fixedSize()
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(runningTime(since: item.startedAt, until: context.date))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.tx2)
                        .frame(minWidth: 40, alignment: .trailing)
                }
                .fixedSize()
            }
            Button("Don't Wake", systemImage: "bell.slash") {
                engine.perform("wakes.cancel", ["conversationId": item.conversationId, "key": item.key])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(PiButtonStyle(kind: .secondary, compact: true))
            .fixedSize()
            .help(item.kind == "subchat"
                ? "Don't wake the agent when this sub-chat answers. It keeps working, and its answer stays in it."
                : "Don't wake the agent when this command ends. It keeps running.")
        }
        .font(.system(size: 12.5))
    }
}
