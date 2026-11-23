import EngineKit
import Foundation
import PiModels

/// The requests Usage sends, each made as the Mac's Usage window makes it, through the same client (`session.engine`), so
/// that they work as they are the day a Mac answers them. Each answers nil once the engine has taken the request, or the
/// engine's own words when it refused it or could not be reached, for the page to say beside the control that sent it.
/// Nothing here answers for the engine.
///
/// Both may be sent from a phone in an open session (docs/iphone.md 4.2): `limits.refresh` is a reading request, and
/// `usage.setBudget` a change that widens, which the Mac notifies the person of.
@MainActor
enum UsageRequests {
    /// Sets the day's budget in dollars, or removes it with nil, as the Mac's Usage does (`UsageView.saveBudget` and
    /// Remove Limit: `usage.setBudget`). The `usage` event then says the new budget.
    static func setBudget(_ engine: EngineSession<MessageField>, daily: Double?) async -> String? {
        await failure { try await engine.call("usage.setBudget", ["daily": daily.map { $0 as Any } ?? NSNull()]) }
    }

    /// Asks a subscription's provider for its windows now, as the Mac's Check Now does (`LimitsSection.refresh`:
    /// `limits.refresh`). The `limits` event then says what it answered, or why it could not.
    static func refreshLimits(_ engine: EngineSession<MessageField>, provider: String) async -> String? {
        await failure { try await engine.call("limits.refresh", ["id": provider]) }
    }

    /// The amount typed for the budget, or what to say when it is not one: at least a cent, as the Mac takes it. A
    /// comma for the decimal point, as a phone's keypad types it in many places, is taken too.
    static func budgetAmount(_ text: String) -> Result<Double, BudgetProblem> {
        var cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        if !cleaned.contains("."), cleaned.filter({ $0 == "," }).count == 1 {
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        }
        guard let value = Double(cleaned), value.isFinite, value >= 0.01 else { return .failure(BudgetProblem()) }
        return .success(value)
    }

    struct BudgetProblem: Error, Equatable {
        let message = "Enter an amount of at least $0.01, or use Remove Limit."
    }

    /// The engine's words when `request` fails, nil when it is answered.
    private static func failure(_ request: () async throws -> Void) async -> String? {
        do {
            try await request()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
