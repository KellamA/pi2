import Foundation

/// Usage's requests in the demo (#697), answered as the engine answers them: the day's budget set or removed
/// (`engine/src/settingsrequests.ts`, `usage.setBudget`, then the `usage` event again with the budget and whether today is
/// over it, as `usage.ts` counts it), and a subscription's limits checked (`engine/src/limits.ts`, `limits.refresh`). The
/// demo has no subscription signed in, so a check of one is refused as the engine refuses it, and a check of all answers
/// the `limits` event as it stands.
extension DemoScript {
    static let usage: [String: DemoAnswer] = [
        // `{ daily }`: an amount above zero, or null for none; answers `{}`.
        "usage.setBudget": { request, world in
            let given = request.params["daily"]
            let daily: Double?
            if given is NSNull {
                daily = nil
            } else if let number = given as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue > 0 {
                daily = number.doubleValue
            } else {
                throw DemoRefusal("The budget must be an amount above zero, or off")
            }
            world.change("usage") { usage in
                let spent = ((usage["today"] as? [String: Any])?["cost"] as? NSNumber)?.doubleValue ?? 0
                usage["budget"] = ["daily": daily.map { $0 as Any } ?? NSNull()]
                usage["overBudget"] = daily.map { spent >= $0 } ?? false
            }
            return [:]
        },
        // `{ id? }`: asks one signed-in subscription, or all of them; answers the `limits` event.
        "limits.refresh": { request, world in
            let limits = world.event("limits") ?? ["event": "limits", "providers": [Any](), "notices": [Any]()]
            let signedIn = (limits["providers"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            if let id = request.params["id"] as? String, !signedIn.contains(id) {
                throw DemoRefusal("That subscription is not signed in.")
            }
            world.change("limits") { _ in }
            return limits
        },
    ]
}
