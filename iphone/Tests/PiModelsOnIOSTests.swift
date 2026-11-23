import Foundation
import PiModels
import Testing

/// The shared models are decoded on iOS as the engine sends them (docs/iphone.md section 8): a conversation's summary,
/// as `conversations` and `conversation.created` carry it, with a value of every JSON kind in `JSONValue`.
struct PiModelsOnIOSTests {
    @Test func conversationSummaryDecodes() throws {
        let json = Data("""
            {"id": 42, "title": "Sidebar badges", "updatedAt": 1763740800000, "busy": true, "agentId": "orchestrator",
             "createdAt": 1763737200000, "parent": 7, "projectId": "pi2", "orchestrator": "current", "someLaterField": [1, 2]}
            """.utf8)
        let summary = try JSONDecoder().decode(ConversationSummary.self, from: json)
        #expect(summary.id == 42)
        #expect(summary.title == "Sidebar badges")
        #expect(summary.updatedAt == 1_763_740_800_000)
        #expect(summary.busy)
        #expect(summary.agentId == "orchestrator")
        #expect(summary.parent == 7)
        #expect(summary.projectId == "pi2")
        #expect(summary.orchestrator == "current")
        #expect(summary.chat == nil)
    }

    @Test func jsonValueKeepsEveryKind() throws {
        let json = Data(#"{"s": "π²", "n": 1.5, "b": false, "z": null, "a": [1, "two"], "o": {"k": true}}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: json)
        let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(value == again)
    }
}
