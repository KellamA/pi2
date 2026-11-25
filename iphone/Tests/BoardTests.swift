
import EngineKit
import Foundation
import PiModels
import Testing
@testable import pi2

/// The board's pages (#696): what they read of the engine's state, as the Mac's board tabs read it, and the requests they
/// send, each as the Mac app makes it, with what a device may not send left out (docs/iphone.md, 4.2).
@MainActor
struct BoardTests {
    /// Waits for `condition`, polling, for at most `seconds`.
    private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func replaySession() async throws -> AppSession {
        let session = AppSession()
        session.start(try #require(ReplayTransport.recording()), as: .connected(.home))
        #expect(try await eventually {
            session.engine.projects.count == 2 && !session.engine.allAgents.isEmpty && !session.engine.projectRules.isEmpty
                && session.engine.extras["memory"] != nil
        })
        return session
    }

    /// Records every request the client sends and refuses each, but those `answers` holds a result for, so that a test
    /// can see what was sent; it answers nothing else.
    private final class RecordingTransport: EngineTransport {
        var sent: [(method: String, params: [String: Any])] = []
        var answers: [String: Any] = [:]
        private var handler: (@MainActor (EngineTransportEvent) -> Void)?

        func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
            self.handler = handler
            Task { @MainActor [weak self] in self?.handler?(.ready) }
        }

        func send(_ data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? Int, let method = object["method"] as? String else { return }
            sent.append((method, object["params"] as? [String: Any] ?? [:]))
            let answer: [String: Any] = answers[method].map { ["id": id, "result": $0] } ?? ["id": id, "error": "Refused in the test."]
            var reply = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
            reply.append(0x0A)
            Task { @MainActor [weak self] in self?.handler?(.received(reply)) }
        }

        func cancel() { handler = nil }
    }

    private func recordingEngine() async throws -> (EngineSession<MessageField>, RecordingTransport) {
        let engine = EngineSession<MessageField>()
        let transport = RecordingTransport()
        engine.connect(transport)
        #expect(try await eventually { engine.status == .connected })
        return (engine, transport)
    }

    private func agent(_ fields: [String: Any]) throws -> AgentProfile {
        var object: [String: Any] = ["id": "a", "name": "A", "description": "", "color": "blue", "instructions": "", "access": "ask",
                                     "delegates": [String](), "createdAt": 1]
        for (key, value) in fields { object[key] = value }
        return try JSONDecoder().decode(AgentProfile.self, from: JSONSerialization.data(withJSONObject: object))
    }

    // MARK: - Reading

    @Test func readsTheRecordedBoardAsTheMacDoes() async throws {
        let session = try await replaySession()
        let data = BoardData(session.engine)
        #expect(data.connected && data.loaded)
        let project = try #require(data.projects.first { $0.name == "Demo project" })
        #expect(data.project(project.id) == project)
        #expect(data.project("no-such-project") == nil)

        // The orchestrator apart, the others in the order they were made; the templates are the agents of no project.
        #expect(data.agent(project.orchestratorId)?.role == "orchestrator")
        #expect(data.projectAgents(project).map(\.name) == ["Atlas", "Forge", "Scout", "Beacon"])
        #expect(data.removedAgents(project).isEmpty)
        #expect(data.templates.map(\.name) == ["Atlas", "Forge", "Scout"])
        #expect(data.shortModelName(data.agent(project.orchestratorId)?.model) != "")
        #expect(project.allows("startAgents") && !project.allows("merge"))
        #expect(data.memoryEnabled(project.orchestratorId))
        #expect(!data.builtInTools.isEmpty)

        // The rules in their order, each added by the person, and what they cost.
        let rules = data.rules(project.id)
        #expect(rules.map(\.id) == ["r1", "r2", "r3"])
        #expect(rules[1].binds == .orchestrator)
        #expect(data.origin(rules[0]).hasPrefix("Added by you, "))
        #expect(BoardData.ruleCost(project.ruleTokens)?.hasPrefix("About 115 tokens") == true)
        #expect(data.proposals(project.id).isEmpty)

        // The notes, newest first; one is for one agent alone.
        let notes = data.notes(project.id)
        #expect(notes.map(\.id) == ["n2", "n1"])
        let atlas = try #require(data.projectAgents(project).first { $0.name == "Atlas" })
        #expect(notes[0].audience == atlas.id)
        #expect(data.writer(atlas.id, of: notes[0]) == "Atlas")
        #expect(data.origin(notes[1]).hasPrefix("Added by you, "))

        // The recording's conversations work in no git repository.
        #expect(data.branchGroups(project.id).isEmpty)
        #expect(data.leftBehind(project.id).isEmpty)
        #expect(data.branchSummary(project.id) == "0 conversations in git")
    }

    @Test func aRequestTheRecordingDoesNotAnswerSaysSo() async throws {
        let session = try await replaySession()
        let engine = session.engine
        let project = try #require(engine.projects.first)
        let problem = await BoardRequests.addRule(engine, project: project.id, text: "Keep it short.", binds: .everyone)
        #expect(problem?.contains("projects.rules.add") == true)
        // The rules are as the engine sent them: nothing pretends the change was made.
        #expect(BoardData(engine).rules(project.id).count == 3)
    }

    // MARK: - Requests, as the Mac makes them

    @Test func eachRequestIsTheMacs() async throws {
        let (engine, transport) = try await recordingEngine()
        #expect(await BoardRequests.setSwitch(engine, project: "p", name: "merge", on: true) == "Refused in the test.")
        #expect(await BoardRequests.newAgent(engine, project: "p", named: "New Agent") == .failure(BoardFailure("Refused in the test.")))
        _ = await BoardRequests.copyTemplate(engine, project: "p", template: "forge")
        _ = await BoardRequests.makeOrchestrator(engine, project: "p", agent: "forge-1")
        _ = await BoardRequests.newConversation(engine, agent: "forge-1")
        _ = await BoardRequests.allowEverythingOff(engine, agent: "forge-1")
        _ = await BoardRequests.setMemory(engine, agent: "forge-1", on: false)
        _ = await BoardRequests.allowCommand(engine, agent: "forge-1", folder: "/f", command: "npm test")
        _ = await BoardRequests.moveRule(engine, project: "p", rule: "r2", to: 0)
        _ = await BoardRequests.answerProposal(engine, need: "n9", accept: true, text: "Run the tests.", binds: .orchestrator)
        _ = await BoardRequests.shareNote(engine, project: "p", note: "n2")
        _ = await BoardRequests.createWorktree(engine, conversation: 17, branch: "  ")
        _ = await BoardRequests.removeWorktree(engine, conversation: 17, force: false, deleteBranch: true)

        // What the client says by itself as it connects is not the board's.
        let sent = transport.sent.filter { $0.method != "conversations.shown" }
        #expect(sent.map(\.method) == [
            "projects.set", "projects.addAgent", "projects.addAgent", "projects.setOrchestrator", "conversation.create",
            "agents.allowEverything", "memory.setEnabled", "rules.add", "projects.rules.move", "needs.answer", "memory.edit",
            "worktree.create", "worktree.remove",
        ])
        #expect((sent[0].params["settings"] as? [String: Any])?["withoutAsking"] as? [String: Bool] == ["merge": true])
        #expect((sent[1].params["agent"] as? [String: Any])?["access"] as? String == "none")
        #expect(sent[2].params["template"] as? String == "forge")
        #expect(sent[3].params["agentId"] as? String == "forge-1")
        #expect(sent[4].params["agentId"] as? String == "forge-1")
        // Allow everything is only ever turned off from a phone: on is the Mac's alone (4.2, question 5).
        #expect(sent[5].params["on"] as? Bool == false)
        #expect(sent[6].params["enabled"] as? Bool == false)
        #expect(sent[7].params["command"] as? String == "npm test" && sent[7].params["folder"] as? String == "/f")
        #expect(sent[8].params["to"] as? Int == 0)
        let answer = try #require(sent[9].params["answer"] as? [String: Any])
        #expect(answer["kind"] as? String == "rule" && answer["accept"] as? Bool == true && answer["binds"] as? String == "orchestrator")
        #expect(sent[10].params["audience"] is NSNull)
        // An empty branch name leaves the choice to the engine.
        #expect(sent[11].params["branch"] == nil)
        #expect(sent[12].params["deleteBranch"] as? Bool == true && sent[12].params["force"] as? Bool == false)
        #expect(!sent.contains { $0.method.hasPrefix("variables.") })
    }

    @Test func theDemoAnswersTheBoardAsTheEngineDoes() async throws {
        let transport = try #require(DemoTransport.recorded())
        transport.world.pace = 0.02
        let session = AppSession()
        session.start(transport, as: .demo)
        let engine = session.engine
        #expect(try await eventually { !engine.projects.isEmpty && !engine.projectRules.isEmpty && engine.extras["memory"] != nil })
        let project = try #require(engine.projects.first { $0.name == "Demo project" })
        let before = BoardData(engine).rules(project.id)

        // A rule added, moved to the top, rebound, then removed: each comes back in the `projectRules` event.
        #expect(await BoardRequests.addRule(engine, project: project.id, text: "Say what you checked.", binds: .everyone) == nil)
        #expect(try await eventually { BoardData(engine).rules(project.id).count == before.count + 1 })
        let added = try #require(BoardData(engine).rules(project.id).last)
        #expect(added.text == "Say what you checked." && added.addedBy == .person)
        #expect(await BoardRequests.moveRule(engine, project: project.id, rule: added.id, to: 0) == nil)
        #expect(await BoardRequests.bindRule(engine, project: project.id, rule: added.id, binds: .orchestrator) == nil)
        #expect(try await eventually { BoardData(engine).rules(project.id).first.map { $0.id == added.id && $0.binds == .orchestrator } == true })
        #expect(await BoardRequests.moveRule(engine, project: project.id, rule: added.id, to: 99)?.hasPrefix("to must be a whole number") == true)
        #expect(await BoardRequests.removeRule(engine, project: project.id, rule: added.id) == nil)
        #expect(try await eventually { BoardData(engine).rules(project.id) == before })

        // A note added, shared and deleted.
        let notes = BoardData(engine).notes(project.id)
        #expect(await BoardRequests.addNote(engine, project: project.id, text: "Friday at ten.") == nil)
        #expect(try await eventually { BoardData(engine).notes(project.id).count == notes.count + 1 })
        if let shared = notes.first(where: { $0.audience != nil }) {
            #expect(await BoardRequests.shareNote(engine, project: project.id, note: shared.id) == nil)
            #expect(try await eventually { BoardData(engine).notes(project.id).first { $0.id == shared.id }?.audience == nil })
        }
        #expect(await BoardRequests.addNote(engine, project: project.id, text: "  ") == "Write the note first")

        // The memory switch, and Allow everything: off is answered, on is the Mac's alone.
        #expect(await BoardRequests.setMemory(engine, agent: project.orchestratorId, on: false) == nil)
        #expect(try await eventually { !BoardData(engine).memoryEnabled(project.orchestratorId) })
        #expect(await BoardRequests.allowEverythingOff(engine, agent: project.orchestratorId) == nil)
        let on = try? await engine.call("agents.allowEverything", ["id": project.orchestratorId, "on": true])
        #expect(on == nil)
        #expect(transport.world.unanswered.isEmpty)
    }

    @Test func aRequestWithNoConnectionSaysSo() async {
        let engine = EngineSession<MessageField>()
        #expect(await BoardRequests.deleteNote(engine, project: "p", note: "n1") == "The engine is not running yet.")
    }

    // MARK: - An agent's page

    @Test func saveSendsOnlyWhatWasChanged() throws {
        let base = try agent(["instructions": "Be brief."])
        var draft = base
        draft.description = "Writes the docs"
        let edited = BoardAgentDraft.edited(draft, from: base)
        #expect(edited == ["description"])
        let payload = BoardAgentDraft.payload(draft, edited: edited)
        #expect(Set(payload.keys) == ["id", "name", "description"])
        #expect(payload["description"] as? String == "Writes the docs")
        // A setting the engine only fills in on save is not a change.
        var filled = base
        filled.worktree = false
        filled.codeMode = false
        #expect(BoardAgentDraft.edited(filled, from: base).isEmpty)
    }

    @Test func aChangeSavedElsewhereKeepsThePersonsEdits() throws {
        let base = try agent(["delegates": ["scout"]])
        var draft = base
        draft.description = "Mine"
        draft.delegates = ["scout", "atlas"]
        var latest = base
        latest.instructions = "Saved on the Mac"
        latest.delegates = ["scout", "forge"]
        let rebased = BoardAgentDraft.rebase(draft, from: base, onto: latest)
        #expect(rebased.description == "Mine")
        #expect(rebased.instructions == "Saved on the Mac")
        #expect(Set(rebased.delegates) == ["scout", "forge", "atlas"])
        #expect(BoardAgentDraft.edited(rebased, from: latest) == ["description", "delegates"])
    }

    @Test func aNewAgentGetsANameNoneHas() throws {
        #expect(BoardAgentDraft.uniqueName(among: []) == "New Agent")
        let taken = [try agent(["name": "New Agent"]), try agent(["id": "b", "name": "new agent 2"])]
        #expect(BoardAgentDraft.uniqueName(among: taken) == "New Agent 3")
    }

    @Test func theTemplatesMarksAreRead() throws {
        var data = BoardData()
        let template = try agent(["id": "forge", "name": "Forge", "updatedAt": 50])
        let copy = try agent(["id": "forge-1", "name": "Forge", "projectId": "p", "template": ["id": "forge", "copiedAt": 1, "templateUpdatedAt": 40]])
        let current = try agent(["id": "forge-2", "name": "Forge", "projectId": "p", "template": ["id": "forge", "copiedAt": 1, "templateUpdatedAt": 50]])
        let orphan = try agent(["id": "forge-3", "name": "Forge", "projectId": "p", "template": ["id": "gone", "copiedAt": 1, "templateUpdatedAt": 1]])
        data.allAgents = [template, copy, current, orphan]
        #expect(data.templateChanged(copy) && !data.templateGone(copy))
        #expect(!data.templateChanged(current))
        #expect(data.templateGone(orphan) && !data.templateChanged(orphan))
        #expect(data.delegateCandidates(copy).map(\.id) == ["forge-2", "forge-3"])
        #expect(data.templates.map(\.id) == ["forge"])
    }

    @Test func templateChangesReadAsThePagesWords() {
        #expect(BoardTemplateChange.title("access") == "Tool access")
        #expect(BoardTemplateChange.words("access", .string("full")) == "Full access")
        #expect(BoardTemplateChange.words("model", .null) == "App default")
        #expect(BoardTemplateChange.words("browser", .object(["enabled": .bool(true), "ask": .bool(false)])) == "On, without asking")
        #expect(BoardTemplateChange.words("files", .array([.object(["path": .string("/a/notes.md")])])) == "/a/notes.md")
        #expect(BoardTemplateChange(.object(["setting": .string("color"), "now": .string("blue"), "template": .string("pink")]))?.setting == "color")
    }

    @Test func theSwitchesAreTheEnginesWithTheirConfirmations() {
        let names = BoardSwitch.all.map(\.name)
        #expect(names == ["startAgents", "fileWork", "closeWork", "makeAgents", "addRules", "merge", "release", "passLimits"])
        #expect(BoardSwitch.all.first { $0.name == "merge" }?.confirmation == "The orchestrator may then merge a pull request through work without asking you.")
        #expect(BoardSwitch.all.first { $0.name == "release" }?.confirmation.hasPrefix("The orchestrator may then release what it has made") == true)
    }

    // MARK: - Branches

    @Test func branchesAreGroupedAsTheMacsTrackerGroupsThem() throws {
        var data = BoardData()
        func conversation(_ id: Int, parent: Int? = nil, updated: Double) throws -> ConversationSummary {
            var object: [String: Any] = ["id": id, "title": "C\(id)", "updatedAt": updated, "busy": false, "projectId": "p", "createdAt": updated]
            if let parent { object["parent"] = parent }
            return try JSONDecoder().decode(ConversationSummary.self, from: JSONSerialization.data(withJSONObject: object))
        }
        data.conversations = [try conversation(1, updated: 10), try conversation(2, updated: 20), try conversation(3, parent: 1, updated: 30),
                              try conversation(4, updated: 5)]
        data.branches = [
            1: BoardSample.status(repo: "app", root: "/app", branch: "main", state: "clean", upstream: "origin/main"),
            2: BoardSample.status(repo: "app", root: "/wt/2", branch: "pi2/2", state: "changes", worktree: true, managed: true, changes: 3),
            3: BoardSample.status(repo: "app", root: "/app", branch: "main", state: "clean"),
            4: BoardSample.status(repo: "docs", root: "/docs", branch: "main", state: "ahead", upstream: "origin/main"),
        ]
        let groups = data.branchGroups("p")
        #expect(groups.map(\.repo) == ["app", "docs"])
        // Most pressing first; the sub-chat in its parent's checkout follows its parent, nested.
        #expect(groups[0].rows.map(\.id) == [2, 1, 3])
        #expect(groups[0].rows.map(\.nested) == [false, false, true])
        #expect(groups[0].rows[2].sharing?.id == 1)
        #expect(groups[0].worktrees == 1)
        #expect(data.branchSummary("p") == "4 conversations in git · 1 in a worktree of its own")
        #expect(data.branchGroups("other").isEmpty)
    }

    /// Against a copy, the branch the engine suggested came after the alert had opened, and the alert's field, which shows
    /// what it holds as it opens, stayed empty: the question now opens once the suggestion has come, with it in the field.
    @Test func aNewWorktreeIsAskedWithTheEnginesSuggestion() async throws {
        let (engine, transport) = try await recordingEngine()
        transport.answers["worktree.suggest"] = ["branch": "pi2/check-the-sample-build"]
        #expect(await BoardWorktreeAsk.opening(engine, conversation: 17) == BoardWorktreeAsk(conversation: 17, branch: "pi2/check-the-sample-build"))
        let asked = try #require(transport.sent.last)
        #expect(asked.method == "worktree.suggest" && asked.params["id"] as? Int == 17)
        // With no suggestion the field opens empty, which leaves the branch to the engine.
        transport.answers = [:]
        #expect(await BoardWorktreeAsk.opening(engine, conversation: 17) == BoardWorktreeAsk(conversation: 17, branch: ""))
    }

    /// A branch as a copy's engine sent it (#696, part 2), with the nulls the recording never had, reads as the Mac's.
    @Test func theEnginesBranchEventIsRead() throws {
        let status = try JSONDecoder().decode(BranchStatus.self, from: Data("""
            {"repo":"demo-project","root":"/tmp/demo-project","branch":"main","head":"8168b3a","worktree":false,"managed":false,
             "upstream":null,"ahead":0,"behind":0,"base":null,"unmerged":null,"defaultBranch":null,"unmergedDefault":null,
             "changes":0,"conflicts":0,"operation":null,"added":0,"removed":0,"state":"clean"}
            """.utf8))
        #expect(status.boardName == "main" && status.boardStateTitle == "clean")
        #expect(status.boardKind(shared: false) == "main checkout")
        #expect(status.boardFacts == ["Not pushed anywhere yet"])
    }

    @Test func branchStatesReadAsTheMacSaysThem() {
        let dirty = BoardSample.status(repo: "app", root: "/wt", branch: "pi2/2", state: "changes", worktree: true, managed: true, changes: 3)
        #expect(dirty.boardStateTitle == "3 changed")
        #expect(dirty.isDirty)
        #expect(dirty.boardFacts.contains("3 uncommitted changes"))
        #expect(dirty.boardKind(shared: false) == "own worktree")
        let stopped = BoardSample.status(repo: "app", root: "/wt", branch: nil, state: "conflict", conflicts: 1, operation: "rebase")
        #expect(stopped.boardStateTitle == "rebase stopped")
        #expect(stopped.boardName == "detached at 4f2c9e1")
        #expect(stopped.boardKind(shared: true) == "parent’s checkout")
        let pushed = BoardSample.status(repo: "app", root: "/app", branch: "main", state: "ahead", upstream: "origin/main")
        #expect(pushed.boardStateTitle == "2 to push")
        #expect(pushed.boardFacts == ["2 commits not pushed to origin/main"])
    }

    @Test func notesAreReadFromTheMemoryEvent() throws {
        var data = BoardData()
        data.memory = try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"projects": {"p": {"notes": [
              {"id": "a", "text": "Older", "agentId": "gone", "createdAt": 1000, "audience": null, "carriedFrom": {"agentName": "Scribe"}},
              {"id": "b", "text": "Newer", "agentId": null, "createdAt": 2000, "audience": "gone"}]}},
             "agents": {"x": {"enabled": true, "notes": []}}}
            """.utf8))
        let notes = data.notes("p")
        #expect(notes.map(\.text) == ["Newer", "Older"])
        #expect(data.writer("gone", of: notes[1]) == "Scribe")
        #expect(data.writer("gone", of: notes[0]) == "a deleted agent")
        #expect(data.origin(notes[1]).hasPrefix("Written by Scribe, "))
        #expect(data.memoryEnabled("x") && !data.memoryEnabled("y"))
        #expect(data.notes("q").isEmpty)
    }
}
