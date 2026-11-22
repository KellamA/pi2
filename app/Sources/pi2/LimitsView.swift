import PiModels
import SwiftUI

/// What the engine says about each signed-in subscription's allowance: its `limits` event, as sent. See
/// engine/src/limits.ts for the shape and docs/limits.md for where each provider's figures come from.
struct PlanLimits: Decodable, Equatable {
    struct Window: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
        /// 0–100.
        let usedPercent: Double
        /// Milliseconds since 1970.
        let resetsAt: Double?
    }

    struct Provider: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let plan: String?
        let note: String?
        /// "usage": pi² can ask the provider; "responses": only its answers carry the figures; "none": it does not report them.
        let reports: String
        let windows: [Window]?
        let fetchedAt: Double?
        /// "usage" or "responses".
        let source: String?
        let error: String?
        let errorAt: Double?
        let refreshing: Bool?
    }

    /// A subscription's window on the Dashboard, one story in up to three stages (engine/src/limits.ts): it passed 90% while
    /// runs on it were going (`nearly`), the provider refused runs for its limit and they wait (`reached`), and it
    /// answered again so they carry on (`carried_on`).
    struct Notice: Decodable, Equatable, Identifiable {
        struct Run: Decodable, Equatable {
            let conversationId: Int
            /// The conversation in the sidebar it belongs to; differs from `conversationId` for a sub-chat.
            let rootConversationId: Int
            let title: String
            let agentName: String?
            let subChat: Bool
        }

        let id: String
        let provider: String
        let name: String
        let plan: String?
        /// Empty for a provider that reports no windows.
        let label: String
        /// 0–100; nil for a provider that reports no windows.
        let usedPercent: Double?
        /// Milliseconds since 1970.
        let resetsAt: Double?
        /// When it was first noticed.
        let at: Double
        /// "nearly", "reached" or "carried_on"; nil from an engine older than the stages, which meant "nearly".
        let stage: String?
        let nearlyAt: Double?
        let reachedAt: Double?
        let carriedOnAt: Double?
        /// While reached: how many runs wait, until when (ms since 1970), and whether the provider named that time.
        let waiting: Int?
        let until: Double?
        let told: Bool?
        /// The runs it is about: going when it passed 90%, waiting once reached, that waited once carried on; `more`
        /// counts those left out.
        let runs: [Run]
        let more: Int?

        var currentStage: String { stage ?? "nearly" }

        /// "Anthropic Max", "Anthropic Max, 5-hour window", "Stand-in".
        var subject: String {
            let name = "\(self.name)\(plan.map { " \($0)" } ?? "")"
            return label.isEmpty ? name : "\(name), \(label.prefix(1).lowercased() + label.dropFirst())"
        }

        /// "Passed 90% at 16:02 · refused at 16:35 · carried on at 18:20": how the story went, as far as it has.
        var history: String {
            func time(_ ms: Double) -> String { LimitsFormat.date(ms).formatted(date: .omitted, time: .shortened) }
            let story = [
                nearlyAt.map { "passed 90% at \(time($0))" },
                reachedAt.map { "limit reached at \(time($0))" },
                carriedOnAt.map { "carried on at \(time($0))" },
            ].compactMap { $0 }.joined(separator: " · ")
            return story.prefix(1).uppercased() + story.dropFirst()
        }

        /// What a notification says at this stage: nil for `nearly`, which is quiet (#232).
        var notification: (title: String, body: String)? {
            let count = runs.count + (more ?? 0)
            switch currentStage {
            case "reached":
                let when = until.map { LimitsFormat.date($0).formatted(date: .omitted, time: .shortened) }
                let waits = (waiting ?? count) == 1 ? "1 run waits" : "\(waiting ?? count) runs wait"
                let body = told == true && when != nil
                    ? "\(waits) until \(when!), then \((waiting ?? count) == 1 ? "carries" : "carry") on by \((waiting ?? count) == 1 ? "itself" : "themselves")."
                    : "\(waits) and \((waiting ?? count) == 1 ? "asks" : "ask") again by \((waiting ?? count) == 1 ? "itself" : "themselves"); \(name) named no time."
                return ("\(subject): limit reached", body)
            case "carried_on":
                return ("\(subject): carrying on", "\(name) answers again. \(count == 1 ? "The run that waited carries" : "The \(count) runs that waited carry") on by \(count == 1 ? "itself" : "themselves").")
            default:
                return nil
            }
        }
    }

    let providers: [Provider]
    let notices: [Notice]

    /// Nil when there is no event yet or it cannot be read.
    init?(_ value: JSONValue?) {
        guard let value, let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        providers = decoded.providers
        notices = decoded.notices ?? []
    }

    private struct Payload: Decodable {
        let providers: [Provider]
        let notices: [Notice]?
    }
}

/// A window nearly used up while runs on its subscription were going, under the Dashboard's line across all projects
/// (#645). Information, not a request: a run the provider refuses waits for the reset and carries on by itself, so the
/// card is calm and only offers to put it away. It is one line with Dismiss and Show Usage until Details unfolds the
/// rest.
struct LimitNoticeCard: View {
    let engine: EngineClient
    let notice: PlanLimits.Notice
    /// Show a conversation, by its id in the sidebar.
    let open: (Int) -> Void
    let showUsage: () -> Void
    @State private var unfolded = false

    var body: some View {
        // Re-drawn every half minute so "in 2 h" and "noticed" stay true.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            folded(now: context.date)
        }
    }

    /// The headline on one line, the time it was noticed while it fits, and the card's buttons; Details unfolds what the
    /// card says below it.
    private func folded(now: Date) -> some View {
        let words = words(now: now)
        let noticed = Text("noticed \(LimitsFormat.ago(LimitsFormat.date(notice.at), now: now))")
            .font(.system(size: 11)).foregroundStyle(Theme.tx3)
            .fixedSize()
            .help(LimitsFormat.exact(LimitsFormat.date(notice.at)))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: words.icon).foregroundStyle(words.color)
                Text(words.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .help(words.title)
                    .layoutPriority(1)
                ViewThatFits(in: .horizontal) {
                    noticed
                    Color.clear.frame(width: 0, height: 0)
                }
                Spacer(minLength: 6)
                Button(unfolded ? "Hide Details" : "Details") { unfolded.toggle() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.acc)
                    .fixedSize()
                    .help(unfolded ? "Fold the notice to its line" : "Show which runs it is about, and what happens next")
                Button("Show Usage") { showUsage() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.acc)
                    .fixedSize()
                Button("Dismiss") { engine.perform("limits.dismiss", ["id": notice.id]) }
                    .buttonStyle(PiButtonStyle(kind: .secondary, compact: true))
                    .fixedSize()
                    .help("Put this notice away. It is not shown again for this window before it resets.")
            }
            if unfolded {
                details(words)
            }
        }
        .font(.system(size: 12.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .panel(fill: Theme.panel, border: Theme.line2)
        .accessibilityElement(children: .contain)
    }

    /// The headline, its icon and colour, and what the card says before the runs, at each stage.
    private func words(now: Date) -> (icon: String, color: Color, title: String, intro: String, footer: String) {
        let count = notice.runs.count + (notice.more ?? 0)
        switch notice.currentStage {
        case "reached":
            let waiting = notice.waiting ?? count
            let runs = waiting == 1 ? "One run waits" : "\(waiting) runs wait"
            let intro: String
            if let until = notice.until.map(LimitsFormat.date), notice.told == true {
                intro = "\(notice.name) refused \(waiting == 1 ? "it" : "them") for its limit. \(runs) until \(LimitsFormat.exact(until)), in \(LimitsFormat.duration(until.timeIntervalSince(now))), the time \(notice.name) named, then \(waiting == 1 ? "carries" : "carry") on by \(waiting == 1 ? "itself" : "themselves"):"
            } else {
                let next = notice.until.map { ", next at \(LimitsFormat.date($0).formatted(date: .omitted, time: .shortened))" } ?? ""
                intro = "\(notice.name) refused \(waiting == 1 ? "it" : "them") for its limit and named no time. \(runs) and \(waiting == 1 ? "asks" : "ask") again by \(waiting == 1 ? "itself" : "themselves")\(next):"
            }
            return ("hourglass", Theme.warn, "\(notice.subject): limit reached", intro, "Nothing needs doing: \(waiting == 1 ? "it carries" : "they carry") on when the limit resets. Stop on a run ends its wait.")
        case "carried_on":
            let waited = notice.reachedAt.flatMap { start in notice.carriedOnAt.map { " after \(LimitsFormat.duration(($0 - start) / 1000))" } } ?? ""
            let intro = "\(notice.name) answers again\(waited). \(count == 1 ? "The run that waited carries" : "The \(count) runs that waited carry") on by \(count == 1 ? "itself" : "themselves"):"
            return ("checkmark.circle", Theme.ok, "\(notice.subject): carrying on", intro, "Nothing needs doing.")
        default:
            let reset = notice.resetsAt.map { LimitsFormat.date($0) }
            let when = reset.map { "It resets \(LimitsFormat.exact($0)), in \(LimitsFormat.duration($0.timeIntervalSince(now)))." } ?? "\(notice.name) did not say when it resets."
            let used = notice.usedPercent.map { " \(LimitsFormat.percent($0))% used" } ?? ""
            return ("gauge.with.dots.needle.67percent", Theme.acc, "\(notice.name)\(notice.plan.map { " \($0)" } ?? ""): \(notice.label)\(used)",
                    "\(when) \(count == 1 ? "One run was" : "\(count) runs were") going on this subscription when it passed 90%:",
                    "If \(notice.name) refuses a request before then, that run waits for the reset and carries on by itself. Nothing needs doing.")
        }
    }

    /// What the card says under its headline: the stage, the runs it is about, what came before, and what happens next.
    @ViewBuilder
    private func details(_ words: (icon: String, color: Color, title: String, intro: String, footer: String)) -> some View {
        Text(words.intro)
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(notice.runs, id: \.conversationId) { run in
                Button { open(run.rootConversationId) } label: {
                    HStack(spacing: 6) {
                        Text("“\(run.title.isEmpty ? "New conversation" : run.title)”").foregroundStyle(Theme.acc).lineLimit(1)
                        Text([run.agentName, run.subChat ? "sub-chat" : nil].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(Theme.tx3).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("Open the conversation")
            }
            if let more = notice.more, more > 0 {
                Text("and \(more) more").foregroundStyle(Theme.tx3)
            }
        }
        .padding(.leading, 4)
        // One story, not three alarms: what came before this stage, in one quiet line.
        if notice.currentStage != "nearly", !notice.history.isEmpty {
            Text(notice.history)
                .font(.system(size: 11.5)).foregroundStyle(Theme.tx3)
        }
        Text(words.footer)
            .font(.system(size: 11.5)).foregroundStyle(Theme.tx3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// How much of each subscription's allowance is used, at the top of Usage: a card per signed-in subscription, a bar per
/// window. Not shown when no subscription is signed in.
struct LimitsSection: View {
    let engine: EngineClient
    /// Subscriptions this view is asking about right now.
    @State private var asking: Set<String> = []

    var body: some View {
        let providers = PlanLimits(engine.extras["limits"])?.providers ?? []
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Plan limits").font(.system(size: 13, weight: .semibold))
                // Re-drawn every half minute so "resets in" and "checked" stay true.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(providers) { provider in
                            card(provider, now: context.date)
                        }
                    }
                }
                Text("How much of each subscription's allowance is used, as the provider reports it. Windows above 80% are marked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Each time Usage opens, figures more than an hour old are checked again without waiting for Check Now.
            .onAppear { refreshStale(providers) }
        }
    }

    /// How old a subscription's figures can be when Usage opens before they are checked again.
    static let staleAfter: TimeInterval = 60 * 60

    /// The subscriptions pi² can ask whose last check, good or failed, was more than `staleAfter` ago, or never happened.
    static func stale(_ providers: [PlanLimits.Provider], now: Date = .now) -> [String] {
        providers.filter { provider in
            guard provider.reports == "usage", provider.refreshing != true else { return false }
            guard let last = [provider.fetchedAt, provider.errorAt].compactMap({ $0 }).max() else { return true }
            return now.timeIntervalSince(LimitsFormat.date(last)) > staleAfter
        }.map(\.id)
    }

    /// Asks about each stale subscription. A failure shows on its card, so it is not reported again here.
    private func refreshStale(_ providers: [PlanLimits.Provider]) {
        for id in Self.stale(providers) where !asking.contains(id) {
            refresh(id, quietly: true)
        }
    }

    // MARK: - A subscription

    @ViewBuilder
    private func card(_ provider: PlanLimits.Provider, now: Date) -> some View {
        if provider.reports == "none" {
            HStack(spacing: 8) {
                Text(provider.name).font(.system(size: 13, weight: .medium))
                Text("Does not report its limits.").font(.callout).foregroundStyle(Theme.tx3)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .panel()
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                header(provider, now: now)
                let windows = provider.windows ?? []
                ForEach(windows) { window in
                    row(window, now: now)
                }
                if windows.isEmpty, let empty = emptyText(provider) {
                    Text(empty).font(.callout).foregroundStyle(Theme.tx3)
                }
                if let error = provider.error {
                    failure(error, provider: provider)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .panel()
        }
    }

    private func header(_ provider: PlanLimits.Provider, now: Date) -> some View {
        HStack(spacing: 8) {
            Text(provider.name).font(.system(size: 13, weight: .semibold))
            if let plan = provider.plan { Tag(plan) }
            Spacer()
            if let fetched = provider.fetchedAt.map({ LimitsFormat.date($0) }) {
                Text("checked \(LimitsFormat.ago(fetched, now: now))")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tx3)
                    .help(checkedHelp(provider, at: fetched))
            }
            if provider.reports == "usage" {
                if asking.contains(provider.id) || provider.refreshing == true {
                    Spinner().frame(width: 22)
                } else {
                    Button("Check Now", systemImage: "arrow.clockwise") { refresh(provider.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(PiButtonStyle(kind: .ghost, compact: true))
                        .help("Check now. pi² asks each provider at most about once a minute.")
                        .accessibilityLabel("Check \(provider.name)'s limits now")
                }
            }
        }
    }

    private func row(_ window: PlanLimits.Window, now: Date) -> some View {
        let used = min(max(window.usedPercent, 0), 100)
        let tint = used >= 100 ? Theme.bad : used >= 80 ? Theme.warn : Theme.acc
        let reset = window.resetsAt.map { LimitsFormat.date($0) }
        // A window whose reset has passed since it was read shows old figures: dimmed until it is read again.
        let stale = reset.map { $0 <= now } ?? false
        let percentText = used >= 100 ? "Used up" : "\(LimitsFormat.percent(used))%"
        let resetText = reset.map { $0 > now ? "resets in \(LimitsFormat.duration($0.timeIntervalSince(now)))" : "reset \(LimitsFormat.ago($0, now: now))" } ?? ""
        return HStack(spacing: 10) {
            Text(window.label).lineLimit(1).frame(width: 190, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Theme.line)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(tint)
                        .frame(width: used > 0 ? max(4, geometry.size.width * used / 100) : 0)
                }
            }
            .frame(height: 10)
            .opacity(stale ? 0.45 : 1)
            Text(percentText)
                .font(.callout.monospacedDigit().weight(used >= 80 ? .semibold : .regular))
                .foregroundStyle(used >= 80 ? tint : Theme.tx2)
                .frame(width: 62, alignment: .trailing)
            Text(resetText)
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .trailing)
        }
        .help(reset.map { $0 > now ? "Resets \(LimitsFormat.exact($0))" : "Reset \(LimitsFormat.exact($0)); these figures are from before that." } ?? "The provider did not say when this window resets.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label): \(used >= 100 ? "used up" : "\(LimitsFormat.percent(used)) percent used")\(resetText.isEmpty ? "" : ", \(resetText)")")
    }

    /// "Could not read the limits (Thu 12 Nov, 14:02). Showing what was read Thu 12 Nov, 13:40."
    private func failure(_ error: String, provider: PlanLimits.Provider) -> some View {
        let sentence = error.hasSuffix(".") ? String(error.dropLast()) : error
        let at = provider.errorAt.map { " (\(LimitsFormat.exact(LimitsFormat.date($0))))" } ?? ""
        let kept = provider.fetchedAt.map { " Showing what was read \(LimitsFormat.exact(LimitsFormat.date($0)))." } ?? ""
        return Label {
            Text("\(sentence)\(at).\(kept)")
                .font(.callout).foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
        }
        .accessibilityElement(children: .combine)
    }

    /// What a card says before it has any windows to show.
    private func emptyText(_ provider: PlanLimits.Provider) -> String? {
        if provider.fetchedAt != nil { return provider.note ?? "No limits reported right now." }
        if provider.error != nil { return nil }
        if provider.reports == "responses" { return "Shows after the next request on this subscription." }
        return provider.refreshing == true || asking.contains(provider.id) ? "Checking…" : "Not checked yet."
    }

    private func checkedHelp(_ provider: PlanLimits.Provider, at date: Date) -> String {
        let how = provider.source == "responses" ? "read from the answer to a request" : "asked \(provider.name)"
        return "Checked \(LimitsFormat.exact(date)), \(how)."
    }

    private func refresh(_ id: String, quietly: Bool = false) {
        asking.insert(id)
        Task {
            defer { asking.remove(id) }
            do {
                _ = try await engine.call("limits.refresh", ["id": id])
            } catch {
                if !quietly { engine.lastError = error.localizedDescription }
            }
        }
    }
}

/// Times and amounts as the limits section words them.
enum LimitsFormat {
    static func date(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// "62", "97.1": whole numbers without a decimal.
    static func percent(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    /// "less than a minute", "14 min", "2 h 14 min", "3 d 4 h".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded(.up))
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days) d" : "\(days) d \(hours % 24) h"
    }

    /// "just now", "5 min ago", "3 h ago", "2 d ago".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 24 * 60 { return "\(minutes / 60) h ago" }
        return "\(minutes / (24 * 60)) d ago"
    }

    /// "Tue 14 Nov, 14:00" in the person's own format.
    static func exact(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
