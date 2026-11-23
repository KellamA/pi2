import Foundation
import PiModels

/// What the engine says about each signed-in subscription's allowance: its `limits` event, as sent (engine/src/limits.ts;
/// docs/limits.md). The Mac reads the same event as `PlanLimits` (app/Sources/pi2/LimitsView.swift), which is in the Mac
/// app's target rather than `PiModels`; this reads the providers' part of it the same way, field for field, until that
/// type is shared.
enum UsageLimits {
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

        /// "Anthropic Max", or the name alone.
        var title: String { plan.map { "\(name) \($0)" } ?? name }
    }

    private struct Payload: Decodable {
        let providers: [Provider]
    }

    /// The subscriptions of a `limits` event; none when there is no event yet or it cannot be read.
    static func providers(_ value: JSONValue?) -> [Provider] {
        guard let value, let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return decoded.providers
    }

    /// How old a subscription's figures can be when Usage opens before they are checked again (the Mac's
    /// `LimitsSection.staleAfter`).
    static let staleAfter: TimeInterval = 60 * 60

    /// The subscriptions pi² can ask whose last check, good or failed, was more than `staleAfter` ago, or never happened:
    /// asked about again as Usage opens, as the Mac's `LimitsSection.stale` does.
    static func stale(_ providers: [Provider], now: Date = .now) -> [String] {
        providers.filter { provider in
            guard provider.reports == "usage", provider.refreshing != true else { return false }
            guard let last = [provider.fetchedAt, provider.errorAt].compactMap({ $0 }).max() else { return true }
            return now.timeIntervalSince(UsageTime.date(last)) > staleAfter
        }.map(\.id)
    }

    /// What a card says before it has any windows to show (the Mac's `LimitsSection.emptyText`); nil when the error says it.
    static func emptyText(_ provider: Provider, asking: Bool) -> String? {
        if provider.fetchedAt != nil { return provider.note ?? "No limits reported right now." }
        if provider.error != nil { return nil }
        if provider.reports == "responses" { return "Shows after the next request on this subscription." }
        return provider.refreshing == true || asking ? "Checking…" : "Not checked yet."
    }

    /// "Could not read the limits (Thu 12 Nov, 14:02). Showing what was read Thu 12 Nov, 13:40." (the Mac's
    /// `LimitsSection.failure`).
    static func failureText(_ error: String, provider: Provider) -> String {
        let sentence = error.hasSuffix(".") ? String(error.dropLast()) : error
        let at = provider.errorAt.map { " (\(UsageTime.exact(UsageTime.date($0))))" } ?? ""
        let kept = provider.fetchedAt.map { " Showing what was read \(UsageTime.exact(UsageTime.date($0)))." } ?? ""
        return "\(sentence)\(at).\(kept)"
    }

    /// "checked 5 min ago", and how: from the provider, or from the answer to a request.
    static func checkedText(_ provider: Provider, now: Date) -> String? {
        provider.fetchedAt.map { "checked \(UsageTime.ago(UsageTime.date($0), now: now))" }
    }
}

/// How full one window of a subscription is, in the words and marks the Mac's Usage gives it (`LimitsSection.row`).
struct UsageWindowState: Equatable {
    enum Level: Equatable { case normal, high, full }

    let label: String
    /// 0–100.
    let used: Double
    let level: Level
    /// "62%", or "Used up".
    let percentText: String
    /// "resets in 2 h 14 min", "reset 5 min ago", or empty when the provider did not say.
    let resetText: String
    /// Its reset has passed since it was read, so the figures are old: drawn dimmed until read again.
    let stale: Bool
    /// What VoiceOver reads: "5-hour window: 62 percent used, resets in 2 h 14 min".
    let spoken: String

    init(_ window: UsageLimits.Window, now: Date) {
        let used = min(max(window.usedPercent, 0), 100)
        let reset = window.resetsAt.map(UsageTime.date)
        self.label = window.label
        self.used = used
        level = used >= 100 ? .full : used >= 80 ? .high : .normal
        percentText = used >= 100 ? "Used up" : "\(UsageTime.percent(used))%"
        resetText = reset.map { $0 > now ? "resets in \(UsageTime.duration($0.timeIntervalSince(now)))" : "reset \(UsageTime.ago($0, now: now))" } ?? ""
        stale = reset.map { $0 <= now } ?? false
        let amount = used >= 100 ? "used up" : "\(UsageTime.percent(used)) percent used"
        spoken = "\(window.label): \(amount)\(resetText.isEmpty ? "" : ", \(resetText)")"
    }
}

/// Times and amounts as the Mac's limits section words them (`LimitsFormat`).
enum UsageTime {
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
