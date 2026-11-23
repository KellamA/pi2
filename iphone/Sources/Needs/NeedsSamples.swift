#if DEBUG
import Foundation
import PiModels
import SwiftUI

/// A debug build's sample cards, for drawing and picturing the kinds the recorded session lacks (it holds a question, a
/// decision and an approval) before the demo mode (#684) or a Mac can send them. None of it is compiled into a release
/// build, and nothing here answers: a sample's buttons send their real request through the session's client, which the
/// recording refuses, and the card shows that refusal. The screen says the samples are there.
///
/// Read from the environment at launch (`xcrun simctl launch` passes `SIMCTL_CHILD_<NAME>` as `<NAME>`):
///
/// - `PI2_NEEDS_SAMPLES=all`, or a list of samples, `reach,rule,limit,switch,long,hidden,held,unknown,noinbox`; with
///   `only:` before it (`only:hidden,long`), the recording's own cards are left out.
/// - `PI2_NEEDS_OPEN=<need id>` opens that card on a screen of its own once it is shown.
/// - `PI2_NEEDS_PRESS=<need id>` presses the card's first answer once it is shown (`<need id>:edit` starts editing a
///   proposed rule instead), so that the card's state after it can be pictured with no tap.
/// - `PI2_NEEDS_SCROLL=bottom` opens the list scrolled to its end, for a picture of what is below the screen.
struct NeedsSamples {
    let only: Bool
    let needs: [NeedItem]
    let inbox: [InboxItem]

    static let current: NeedsSamples? = {
        let environment = ProcessInfo.processInfo.environment
        guard var value = environment["PI2_NEEDS_SAMPLES"], !value.isEmpty else { return nil }
        let only = value.hasPrefix("only:")
        if only { value.removeFirst("only:".count) }
        let names = value == "all" ? nil : Set(value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        return NeedsSamples(only: only, names: names, now: Date())
    }()

    static let open: String? = ProcessInfo.processInfo.environment["PI2_NEEDS_OPEN"]
    static let press: String? = ProcessInfo.processInfo.environment["PI2_NEEDS_PRESS"]
    static let bottom = ProcessInfo.processInfo.environment["PI2_NEEDS_SCROLL"] == "bottom"
    /// Whether `press` was done, and `open`: each once a launch.
    @MainActor static var pressed = false
    @MainActor static var opened = false

    /// What the screen says while samples are shown.
    @MainActor @ViewBuilder
    static var note: some View {
        if let current {
            Label("Debug build: \(current.needs.count) sample card\(current.needs.count == 1 ? "" : "s") drawn \(current.only ? "in place of" : "beside") the Mac's (PI2_NEEDS_SAMPLES). Their answers go to the engine like any other.", systemImage: "hammer")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let project = "p-bae6908c-84e6-4971-94f5-3a00f06625da"
    private static let orchestrator = "orchestrator-be192f55-07e3-4821-b600-b5e9b2f79b8d"
    private static let forge = "forge-ea0bf624-f304-4a74-9686-a8c1615b0b82"
    private static let scout = "scout-deca7112-30d6-4a22-9d40-eb3b3b3db534"

    init(only: Bool, names: Set<String>?, now: Date) {
        self.only = only
        let ms = now.timeIntervalSince1970 * 1000
        func ago(_ minutes: Double) -> Double { (ms - minutes * 60_000).rounded() }
        func wanted(_ name: String) -> Bool { names?.contains(name) ?? true }
        let p = Self.project

        var needs: [[String: Any]] = []
        var inbox: [[String: Any]] = []
        func place(_ id: String, _ conversation: Int, _ title: String, _ agent: String, _ name: String) -> [String: Any] {
            ["id": id, "projectId": p, "conversationId": conversation, "rootConversationId": conversation, "title": title, "rootTitle": title,
             "agentId": agent, "agentName": name, "blocking": false]
        }

        if wanted("hidden") {
            let arguments: [String: Any] = ["command": "curl -sS -H 'Authorization: Bearer \(NeedHiddenCall.keyHidden)' https://api.github.com/repos/demo/site/releases | jq '.[0].tag_name'"]
            needs.append(place("sample-hidden", 31, "Check the latest release", Self.forge, "Forge").merging(
                ["kind": "approval", "blocking": true, "createdAt": ago(1), "tool": "bash", "arguments": arguments], uniquingKeysWith: { $1 }))
            inbox.append(["id": "sample-hidden", "kind": "approval", "conversationId": 31, "callId": "sample-1", "tool": "bash", "arguments": arguments,
                          "title": "Check the latest release", "agentName": "Forge", "rootConversationId": 31])
        }
        if wanted("long") {
            let command = """
            cd site && npm ci && npm run build -- --base=/preview/ && \
            for page in index about pricing docs/getting-started docs/agents docs/projects docs/iphone; do \
              npx linkinator "dist/$page.html" --recurse --skip 'https://(twitter|x)\\.com' --timeout 20000 || exit 1; \
            done && rsync -av --delete dist/ ../preview/ && git -C ../preview add -A && \
            git -C ../preview commit -m "Preview of $(git rev-parse --short HEAD)" && git -C ../preview push origin preview && \
            rm -rf ~/Library/Caches/site-build
            """
            let arguments: [String: Any] = ["command": command, "timeout": 900]
            needs.append(place("sample-long", 32, "Publish the preview", Self.scout, "Scout").merging(
                ["kind": "approval", "blocking": true, "createdAt": ago(2), "tool": "bash", "arguments": arguments], uniquingKeysWith: { $1 }))
            inbox.append(["id": "sample-long", "kind": "approval", "conversationId": 32, "callId": "sample-2", "tool": "bash", "arguments": arguments,
                          "rule": ["words": ["cd", "site"], "folder": "/demo/site"], "title": "Publish the preview", "agentName": "Scout", "rootConversationId": 32])
        }
        if wanted("switch") {
            needs.append(place("sample-switch", 9, "Put together a short walkthrough for Friday.", Self.orchestrator, "Orchestrator").merging(
                ["kind": "approval", "blocking": true, "createdAt": ago(3), "tool": "project_agents", "projectSwitch": "makeAgents",
                 "arguments": ["action": "make", "name": "Quill", "template": "scout", "model": ["provider": "anthropic", "modelId": "claude-sonnet"]]],
                uniquingKeysWith: { $1 }))
        }
        if wanted("reach") {
            needs.append(place("sample-reach", 9, "Put together a short walkthrough for Friday.", Self.orchestrator, "Orchestrator").merging(
                ["kind": "reach", "createdAt": ago(4), "change": ["summary": "Let Forge merge its own pull requests"],
                 "why": "#612 to #618 were each held an hour waiting for a merge; the reviews all passed."], uniquingKeysWith: { $1 }))
        }
        if wanted("rule") {
            needs.append(place("sample-rule", 9, "Put together a short walkthrough for Friday.", Self.orchestrator, "Orchestrator").merging(
                ["kind": "rule", "createdAt": ago(5), "text": "Run the link checker before opening a pull request that touches the site.",
                 "binds": "everyone", "why": "Two pull requests this week broke links that the checker would have caught."], uniquingKeysWith: { $1 }))
        }
        if wanted("limit") {
            needs.append(place("sample-limit", 9, "Put together a short walkthrough for Friday.", Self.orchestrator, "Orchestrator").merging(
                ["kind": "limit", "createdAt": ago(6), "start": ["agentName": "Forge", "title": "Fix login", "task": "The login form loses its text when the password is wrong."],
                 "limit": ["reason": "at most 3 agents at once, and 3 are working"]], uniquingKeysWith: { $1 }))
        }
        if wanted("held") {
            needs.append(place("sample-held", 33, "Plan the release notes", Self.scout, "Scout").merging(
                ["kind": "question", "blocking": true, "createdAt": ago(7), "question": "Should the release notes mention the iPhone app, or wait until it is on TestFlight?"],
                uniquingKeysWith: { $1 }))
            inbox.append(["id": "sample-held", "kind": "question", "conversationId": 33, "callId": "sample-3", "tool": "ask_user",
                          "arguments": ["question": "Should the release notes mention the iPhone app, or wait until it is on TestFlight?"],
                          "question": "Should the release notes mention the iPhone app, or wait until it is on TestFlight?",
                          "title": "Plan the release notes", "agentName": "Scout", "rootConversationId": 33])
        }
        if wanted("noinbox") {
            needs.append(place("sample-noinbox", 34, "Tidy the docs", Self.scout, "Scout").merging(
                ["kind": "approval", "blocking": true, "createdAt": ago(8), "tool": "write",
                 "arguments": ["path": "docs/walkthrough.md", "content": "# The Friday walkthrough\n\n1. The board, folded.\n2. A card answered from the phone.\n"]],
                uniquingKeysWith: { $1 }))
        }
        if wanted("unknown") {
            needs.append(place("sample-unknown", 9, "Put together a short walkthrough for Friday.", Self.orchestrator, "Orchestrator").merging(
                ["kind": "survey", "createdAt": ago(9), "question": "How did the walkthrough go?"], uniquingKeysWith: { $1 }))
        }

        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ objects: [[String: Any]], as: T.Type) -> [T] {
            objects.compactMap { object in
                (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? decoder.decode(T.self, from: $0) }
            }
        }
        self.needs = decode(needs, as: NeedItem.self)
        self.inbox = decode(inbox, as: InboxItem.self)
    }
}
#endif
