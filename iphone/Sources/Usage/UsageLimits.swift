import Foundation
import PiModels

/// Usage's wording of the plan limits, as the Mac's Usage gives it (`LimitsSection` in app/Sources/pi2/LimitsView.swift):
/// what a subscription's card says and when its figures are checked again. The event itself is read once for both apps,
/// as the shared `PlanLimits` (#861); a time or an amount is worded by the shared `LimitsFormat`.
extension PlanLimits.Provider {
    /// "Anthropic Max", or the name alone.
    var title: String { plan.map { "\(name) \($0)" } ?? name }
}

enum UsageLimits {
    /// How old a subscription's figures can be when Usage opens before they are checked again (the Mac's
    /// `LimitsSection.staleAfter`).
    static let staleAfter: TimeInterval = 60 * 60

    /// The subscriptions pi² can ask whose last check, good or failed, was more than `staleAfter` ago, or never happened:
    /// asked about again as Usage opens, as the Mac's `LimitsSection.stale` does.
    static func stale(_ providers: [PlanLimits.Provider], now: Date = .now) -> [String] {
        providers.filter { provider in
            guard provider.reports == "usage", provider.refreshing != true else { return false }
            guard let last = [provider.fetchedAt, provider.errorAt].compactMap({ $0 }).max() else { return true }
            return now.timeIntervalSince(LimitsFormat.date(last)) > staleAfter
        }.map(\.id)
    }

    /// What a card says before it has any windows to show (the Mac's `LimitsSection.emptyText`); nil when the error says it.
    static func emptyText(_ provider: PlanLimits.Provider, asking: Bool) -> String? {
        if provider.fetchedAt != nil { return provider.note ?? "No limits reported right now." }
        if provider.error != nil { return nil }
        if provider.reports == "responses" { return "Shows after the next request on this subscription." }
        return provider.refreshing == true || asking ? "Checking…" : "Not checked yet."
    }

    /// "Could not read the limits (Thu 12 Nov, 14:02). Showing what was read Thu 12 Nov, 13:40." (the Mac's
    /// `LimitsSection.failure`).
    static func failureText(_ error: String, provider: PlanLimits.Provider) -> String {
        let sentence = error.hasSuffix(".") ? String(error.dropLast()) : error
        let at = provider.errorAt.map { " (\(LimitsFormat.exact(LimitsFormat.date($0))))" } ?? ""
        let kept = provider.fetchedAt.map { " Showing what was read \(LimitsFormat.exact(LimitsFormat.date($0)))." } ?? ""
        return "\(sentence)\(at).\(kept)"
    }

    /// "checked 5 min ago", and how: from the provider, or from the answer to a request.
    static func checkedText(_ provider: PlanLimits.Provider, now: Date) -> String? {
        provider.fetchedAt.map { "checked \(LimitsFormat.ago(LimitsFormat.date($0), now: now))" }
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

    init(_ window: PlanLimits.Window, now: Date) {
        let used = min(max(window.usedPercent, 0), 100)
        let reset = window.resetsAt.map(LimitsFormat.date)
        self.label = window.label
        self.used = used
        level = used >= 100 ? .full : used >= 80 ? .high : .normal
        percentText = used >= 100 ? "Used up" : "\(LimitsFormat.percent(used))%"
        resetText = reset.map { $0 > now ? "resets in \(LimitsFormat.duration($0.timeIntervalSince(now)))" : "reset \(LimitsFormat.ago($0, now: now))" } ?? ""
        stale = reset.map { $0 <= now } ?? false
        let amount = used >= 100 ? "used up" : "\(LimitsFormat.percent(used)) percent used"
        spoken = "\(window.label): \(amount)\(resetText.isEmpty ? "" : ", \(resetText)")"
    }
}
