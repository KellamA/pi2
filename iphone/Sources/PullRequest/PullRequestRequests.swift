import EngineKit
import Foundation
import PiModels

/// One request the pull request's screens send, made exactly as the Mac's Work tab makes it
/// (`ProjectWorkGitHub` in app/Sources/pi2/ProjectWorkGitHub.swift), through the session's client, so that it works as it
/// is the day a Mac answers it. Each of these a phone may send in an open session (docs/iphone.md, 4.2): `github.diff` and
/// `github.refresh` are reading; `github.sendBack` and `github.settle` with `happened: true` are the person's ordinary
/// acts; `github.merge` and `github.settle` with `happened: false` widen or cannot be undone, and the Mac notifies the
/// person of them.
struct PullRequestRequest: Equatable {
    let method: String
    let params: [String: JSONValue]

    /// The listing read again now (the Mac's Refresh, `ProjectWorkGitHub.refresh`).
    static func refresh(project: String) -> PullRequestRequest {
        PullRequestRequest(method: "github.refresh", params: ["projectId": .string(project)])
    }

    /// The pull request's whole diff (`ProjectWorkGitHub.showDiff`), which answers `{ diff }`.
    static func diff(project: String, number: Int) -> PullRequestRequest {
        PullRequestRequest(method: "github.diff", params: ["projectId": .string(project), "number": .number(Double(number))])
    }

    /// Reads it whole into the listing (`ProjectWorkGitHub.fill`): a closed pull request is listed without its checks
    /// and findings. 4.2 does not name it, so an engine refuses it from a phone today (`answers.ts` lists it as the
    /// Mac's alone, "not named"); the screen says so where the checks would be, with the engine's words.
    static func show(project: String, number: Int) -> PullRequestRequest {
        PullRequestRequest(method: "github.show", params: [
            "projectId": .string(project), "number": .number(Double(number)), "pull": .bool(true),
        ])
    }

    /// Merges it into its base (`ProjectWorkGitHub.merge`), past the merge question.
    static func merge(project: String, number: Int) -> PullRequestRequest {
        PullRequestRequest(method: "github.merge", params: ["projectId": .string(project), "number": .number(Double(number))])
    }

    /// Posts the reason on it and hands it to the conversation that opened it (`ProjectWorkGitHub.sendBack`).
    static func sendBack(project: String, number: Int, reason: String) -> PullRequestRequest {
        PullRequestRequest(method: "github.sendBack", params: [
            "projectId": .string(project), "number": .number(Double(number)), "reason": .string(reason),
        ])
    }

    /// Says whether a write whose outcome pi² could not tell happened (`ProjectWorkGitHub.settle`).
    static func settle(project: String, intent: String, happened: Bool) -> PullRequestRequest {
        PullRequestRequest(method: "github.settle", params: [
            "projectId": .string(project), "intent": .string(intent), "happened": .bool(happened),
        ])
    }

    /// The parameters as the client takes them.
    var arguments: [String: Any] {
        params.mapValues { value -> Any in
            switch value {
            case .string(let text): text
            case .number(let number): number == number.rounded() ? Int(number) as Any : number as Any
            case .bool(let flag): flag
            default: NSNull()
            }
        }
    }

    /// Sends it through the session's client: the answer, or the engine's own words when it refused it or could not be
    /// reached. Nothing here answers for the engine.
    @MainActor
    func send(through engine: EngineSession<MessageField>) async -> Result<JSONValue, PullRequestRefusal> {
        do {
            return .success(try await engine.call(method, arguments))
        } catch {
            return .failure(PullRequestRefusal(words: error.localizedDescription))
        }
    }
}

/// The engine's words when it did not do what was asked, for the screen to show where it was asked.
struct PullRequestRefusal: Error, Equatable {
    let words: String
}
