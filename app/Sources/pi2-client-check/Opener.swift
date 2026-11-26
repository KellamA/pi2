import EngineKit
import Foundation
import PiModels

// What the Send Back field on a pull request's page calls the conversation that opened it (`PullRequestOpener.words`,
// #1005): the six results it can give, from the library's rows and the agents' profiles. Made the way
// `checkPresented` makes its records, by reading the engine's JSON as it is sent.

func checkOpener() {
    let agents = """
        [{"id":"worker","name":"Ada","description":"Does the work","color":"blue","instructions":"","access":"full",
          "delegates":[],"createdAt":1760000000000}]
        """
    let conversations = """
        [
          {"id":8,"title":"Fix the field","updatedAt":1760000000000,"busy":false,"parent":2},
          {"id":9,"title":"Demo site","updatedAt":1760000000000,"busy":false,"orchestrator":"current"},
          {"id":10,"title":"Start over","updatedAt":1760000000000,"busy":false,"orchestrator":"earlier"},
          {"id":11,"title":"Read the logs","updatedAt":1760000000000,"busy":false,"agentId":"worker"},
          {"id":12,"title":"Gone","updatedAt":1760000000000,"busy":false,"runsAs":"ghost"}
        ]
        """
    let agentList: [AgentProfile], conversationList: [ConversationSummary]
    do {
        agentList = try JSONDecoder().decode([AgentProfile].self, from: Data(agents.utf8))
        conversationList = try JSONDecoder().decode([ConversationSummary].self, from: Data(conversations.utf8))
    } catch { fail("opener: the fixtures cannot be read: \(error)") }
    func expect(_ id: Int, _ want: String, _ what: String) {
        let got = PullRequestOpener.words(id, conversations: conversationList, agents: agentList)
        if got != want { fail("opener: \(what): expected \"\(want)\", got \"\(got)\"") }
    }
    expect(7, "conversation 7", "a pull request whose opener is not in the library")
    expect(8, "sub-chat 8", "a sub-chat")
    expect(9, "the orchestrator's conversation", "the conversation with the project's orchestrator")
    expect(10, "an earlier conversation with the orchestrator", "an earlier one with the orchestrator")
    expect(11, "Ada's conversation", "an agent's own conversation, by its agent")
    expect(12, "conversation 12", "one whose agent is not among the profiles")
    print("pi2-client-check: the pull request opener's six words are as the iPhone's PullRequestLook.opener says them")
}
