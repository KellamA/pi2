import SwiftUI
import WidgetKit

/// Who is working: the agents at work and their projects (docs/design/iphone.md, "What a phone adds"), each with when
/// it started or what it waits for. A row opens the agent's conversation; the widget, the Dashboard.
struct WidgetsWorkingView: View {
    let snapshot: WidgetsSnapshot
    let family: WidgetFamily
    @Environment(\.dynamicTypeSize) private var typeSize

    private var working: [WidgetsSnapshot.Worker] { snapshot.working }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: WidgetsKind.working.symbol).font(.caption).widgetAccentable()
                    Text("\(snapshot.workingCount)").font(.title2.weight(.semibold)).monospacedDigit().widgetsPrivate()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.countWords(snapshot.workingCount))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("\(snapshot.workingCount) at work", systemImage: WidgetsKind.working.symbol)
                    .font(.headline).widgetAccentable().widgetsPrivate()
                ForEach(working.prefix(2)) { worker in
                    Text(Self.line(worker)).font(.caption).lineLimit(1).widgetsPrivate()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label(Self.countWords(snapshot.workingCount), systemImage: WidgetsKind.working.symbol).widgetsPrivate()
        case .systemSmall:
            small
        default:
            list(rows: WidgetsRows.count(family, typeSize))
        }
    }

    /// "No agent at work", "1 agent at work", "3 agents at work".
    static func countWords(_ count: Int) -> String {
        switch count {
        case 0: "No agent at work"
        case 1: "1 agent at work"
        default: "\(count) agents at work"
        }
    }

    /// "Atlas · Demo project".
    static func line(_ worker: WidgetsSnapshot.Worker) -> String {
        [worker.agentName, worker.projectName].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Since 14:02", "Waits for you", "Waits for a limit", with how many runs when more than one.
    static func state(_ worker: WidgetsSnapshot.Worker) -> String {
        let state = switch worker.state {
        case .working: "Since \(WidgetsUpdated.words(worker.since))"
        case .waitsForLimit: "Waits for a limit"
        case .waitsForYou: "Waits for you"
        }
        return worker.runs > 1 ? "\(state) · \(worker.runs) runs" : state
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetsHeader(kind: .working, title: "Working")
            if working.isEmpty {
                Spacer(minLength: 0)
                nothing
            } else {
                WidgetsFigure(text: "\(snapshot.workingCount)")
                ForEach(working.prefix(2)) { worker in
                    HStack(spacing: 5) {
                        WidgetsMark(name: worker.agentName, color: worker.agentColor, size: 16)
                        Text(worker.agentName).font(.caption.weight(.medium)).lineLimit(1)
                    }
                    .widgetsPrivate()
                }
            }
            Spacer(minLength: 0)
            WidgetsUpdated(heardAt: snapshot.heardAt)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetsKind.working.link.url)
    }

    private var nothing: some View {
        Label("No agent is at work.", systemImage: "moon.zzz")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func list(rows: Int) -> some View {
        let shown = Array(working.prefix(rows))
        HStack(alignment: .top, spacing: 14) {
            if family == .systemMedium {
                VStack(alignment: .leading, spacing: 4) {
                    WidgetsHeader(kind: .working, title: "Working")
                    WidgetsFigure(text: "\(snapshot.workingCount)")
                    Spacer(minLength: 0)
                    WidgetsUpdated(heardAt: snapshot.heardAt)
                }
                .frame(width: 92, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 8) {
                if family == .systemLarge {
                    HStack(alignment: .firstTextBaseline) {
                        WidgetsHeader(kind: .working)
                        Spacer()
                        Text(Self.countWords(snapshot.workingCount)).font(.caption).foregroundStyle(.secondary).widgetsPrivate()
                    }
                }
                if shown.isEmpty {
                    if family == .systemLarge { Spacer(minLength: 0) }
                    nothing
                } else {
                    ForEach(shown) { worker in
                        Link(destination: WidgetsLink.conversation(worker.conversationID).url) { row(worker) }
                    }
                }
                Spacer(minLength: 0)
                if family == .systemLarge {
                    WidgetsUpdated(heardAt: snapshot.heardAt)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .widgetURL(WidgetsKind.working.link.url)
    }

    private func row(_ worker: WidgetsSnapshot.Worker) -> some View {
        HStack(spacing: 8) {
            WidgetsMark(name: worker.agentName, color: worker.agentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.line(worker)).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary).lineLimit(1)
                HStack(spacing: 3) {
                    if worker.state != .working {
                        Image(systemName: worker.state == .waitsForYou ? "hand.raised.fill" : "hourglass")
                            .imageScale(.small)
                    }
                    Text(Self.state(worker))
                }
                .font(.caption)
                .foregroundStyle(worker.state == .working ? Color.secondary : Color.orange)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .widgetsPrivate()
        .accessibilityElement(children: .combine)
    }
}
