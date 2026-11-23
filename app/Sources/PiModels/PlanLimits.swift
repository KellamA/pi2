import Foundation

// What the engine says about each signed-in subscription's allowance: its `limits` event, read the same way by both
// apps. See engine/src/limits.ts for the shape and docs/limits.md for where each provider's figures come from.

/// What the engine says about each signed-in subscription's allowance: its `limits` event, as sent.
public struct PlanLimits: Decodable, Equatable, Sendable {
    public struct Window: Decodable, Equatable, Identifiable, Sendable {
        public let id: String
        public let label: String
        /// 0–100.
        public let usedPercent: Double
        /// Milliseconds since 1970.
        public let resetsAt: Double?
    }

    public struct Provider: Decodable, Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let plan: String?
        public let note: String?
        /// "usage": pi² can ask the provider; "responses": only its answers carry the figures; "none": it does not report them.
        public let reports: String
        public let windows: [Window]?
        public let fetchedAt: Double?
        /// "usage" or "responses".
        public let source: String?
        public let error: String?
        public let errorAt: Double?
        public let refreshing: Bool?
    }

    /// A subscription's window on the Dashboard, one story in up to three stages (engine/src/limits.ts): it passed 90% while
    /// runs on it were going (`nearly`), the provider refused runs for its limit and they wait (`reached`), and it
    /// answered again so they carry on (`carried_on`).
    public struct Notice: Decodable, Equatable, Identifiable, Sendable {
        public struct Run: Decodable, Equatable, Sendable {
            public let conversationId: Int
            /// The conversation in the sidebar it belongs to; differs from `conversationId` for a sub-chat.
            public let rootConversationId: Int
            public let title: String
            public let agentName: String?
            public let subChat: Bool
        }

        public let id: String
        public let provider: String
        public let name: String
        public let plan: String?
        /// Empty for a provider that reports no windows.
        public let label: String
        /// 0–100; nil for a provider that reports no windows.
        public let usedPercent: Double?
        /// Milliseconds since 1970.
        public let resetsAt: Double?
        /// When it was first noticed.
        public let at: Double
        /// "nearly", "reached" or "carried_on"; nil from an engine older than the stages, which meant "nearly".
        public let stage: String?
        public let nearlyAt: Double?
        public let reachedAt: Double?
        public let carriedOnAt: Double?
        /// While reached: how many runs wait, until when (ms since 1970), and whether the provider named that time.
        public let waiting: Int?
        public let until: Double?
        public let told: Bool?
        /// The runs it is about: going when it passed 90%, waiting once reached, that waited once carried on; `more`
        /// counts those left out.
        public let runs: [Run]
        public let more: Int?

        public var currentStage: String { stage ?? "nearly" }

        /// "Anthropic Max", "Anthropic Max, 5-hour window", "Stand-in".
        public var subject: String {
            let name = "\(self.name)\(plan.map { " \($0)" } ?? "")"
            return label.isEmpty ? name : "\(name), \(label.prefix(1).lowercased() + label.dropFirst())"
        }

        /// "Passed 90% at 16:02 · refused at 16:35 · carried on at 18:20": how the story went, as far as it has.
        public var history: String {
            func time(_ ms: Double) -> String { LimitsFormat.date(ms).formatted(date: .omitted, time: .shortened) }
            let story = [
                nearlyAt.map { "passed 90% at \(time($0))" },
                reachedAt.map { "limit reached at \(time($0))" },
                carriedOnAt.map { "carried on at \(time($0))" },
            ].compactMap { $0 }.joined(separator: " · ")
            return story.prefix(1).uppercased() + story.dropFirst()
        }

        /// What a notification says at this stage: nil for `nearly`, which is quiet (#232).
        public var notification: (title: String, body: String)? {
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

    public let providers: [Provider]
    public let notices: [Notice]

    /// Nil when there is no event yet or it cannot be read.
    public init?(_ value: JSONValue?) {
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

/// Times and amounts as the limits section words them.
public enum LimitsFormat: Sendable {
    public static func date(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// "62", "97.1": whole numbers without a decimal.
    public static func percent(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    /// "less than a minute", "14 min", "2 h 14 min", "3 d 4 h".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded(.up))
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days) d" : "\(days) d \(hours % 24) h"
    }

    /// "just now", "5 min ago", "3 h ago", "2 d ago".
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 24 * 60 { return "\(minutes / 60) h ago" }
        return "\(minutes / (24 * 60)) d ago"
    }

    /// "Tue 14 Nov, 14:00" in the person's own format.
    public static func exact(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
