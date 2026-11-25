import CryptoKit
import Foundation
import PiModels
import SwiftUI
import Testing
@testable import pi2

/// What needs the person (#686): the requests each card's buttons make, the whole call a card shows, the mark of a call
/// partly hidden from the phone, and the order cards are listed in.
@MainActor
struct NeedsTests {
    private func need(_ json: String) throws -> NeedItem {
        try JSONDecoder().decode(NeedItem.self, from: Data(json.utf8))
    }

    private func inboxItem(_ json: String) throws -> InboxItem {
        try JSONDecoder().decode(InboxItem.self, from: Data(json.utf8))
    }

    private func need(id: String, kind: String = "question", project: String? = "p-1", at: Double) throws -> NeedItem {
        let projectField = project.map { "\"\($0)\"" } ?? "null"
        return try need("""
        {"id":"\(id)","projectId":\(projectField),"kind":"\(kind)","conversationId":9,"rootConversationId":9,"title":"T","rootTitle":"T",
         "agentId":null,"agentName":"Atlas","blocking":false,"createdAt":\(at),"question":"Q?"}
        """)
    }

    /// A request's parameters as JSON with sorted keys, to compare with what the Mac sends.
    private func json(_ params: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]), as: UTF8.self)
    }

    // MARK: - The requests, as the Mac makes them

    @Test func approvalsTheInboxHoldsAreDecidedAsTheInboxCardDecidesThem() throws {
        for decision in [NeedReply.Decision.once, .always, .rule, .deny] {
            let request = NeedReply.decide(decision).request(for: "134")
            #expect(request.method == "inbox.decide")
            #expect(try json(request.params) == #"{"decision":"\#(decision.rawValue)","id":"134"}"#)
        }
    }

    @Test func everyOtherAnswerIsANeedAnswer() throws {
        let cases: [(NeedReply, String)] = [
            (.switchApproval(.once), #"{"answer":{"decision":"once","kind":"approval"},"id":"n"}"#),
            (.switchApproval(.deny), #"{"answer":{"decision":"deny","kind":"approval"},"id":"n"}"#),
            (.question("Everyone"), #"{"answer":{"kind":"question","text":"Everyone"},"id":"n"}"#),
            (.choice("c1"), #"{"answer":{"choice":"c1","kind":"decision"},"id":"n"}"#),
            (.decisionWords("Neither"), #"{"answer":{"kind":"decision","text":"Neither"},"id":"n"}"#),
            (.reach(allow: true), #"{"answer":{"allow":true,"kind":"reach"},"id":"n"}"#),
            (.reach(allow: false), #"{"answer":{"allow":false,"kind":"reach"},"id":"n"}"#),
            (.refuseRule, #"{"answer":{"accept":false,"kind":"rule"},"id":"n"}"#),
            (.acceptRule(), #"{"answer":{"accept":true,"kind":"rule"},"id":"n"}"#),
            (.acceptRule(text: "Be brief.", binds: .orchestrator), #"{"answer":{"accept":true,"binds":"orchestrator","kind":"rule","text":"Be brief."},"id":"n"}"#),
            (.limit(start: true), #"{"answer":{"kind":"limit","start":true},"id":"n"}"#),
            (.limit(start: false), #"{"answer":{"kind":"limit","start":false},"id":"n"}"#),
        ]
        for (reply, expected) in cases {
            let request = reply.request(for: "n")
            #expect(request.method == "needs.answer", "\(reply)")
            #expect(try json(request.params) == expected, "\(reply)")
        }
    }

    @Test func aHeldQuestionIsAnsweredAsTheInboxCardAnswersIt() throws {
        let request = NeedReply.answerInbox("Mention it").request(for: "q-1")
        #expect(request.method == "inbox.answer")
        #expect(try json(request.params) == #"{"id":"q-1","text":"Mention it"}"#)
    }

    @Test func theRecordingRefusesAnAnswerAndTheCardIsGivenItsWords() async throws {
        let session = AppSession()
        session.start(try #require(ReplayTransport.recording()), as: .connected(.home))
        let end = Date(timeIntervalSinceNow: 30)
        while session.engine.needs.isEmpty || session.engine.status != .connected {
            #expect(Date() < end, "the recording's needs arrive")
            if Date() > end { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let approval = try #require(session.engine.needs.first { $0.kind == "approval" })
        let refused = await NeedAnswering.send(.decide(.once), to: approval.id, through: session.engine)
        #expect(refused?.contains("inbox.decide") == true)
        let question = try #require(session.engine.needs.first { $0.kind == "question" })
        let refusedToo = await NeedAnswering.send(.question("Everyone"), to: question.id, through: session.engine)
        #expect(refusedToo?.contains("needs.answer") == true)
        // Nothing answered in the engine's place: the cards still wait.
        #expect(session.engine.needs.contains { $0.id == approval.id })
        #expect(session.engine.needs.contains { $0.id == question.id })
    }

    @Test func withNoEngineAnAnswerIsRefusedNotLost() async {
        let session = AppSession()
        let refused = await NeedAnswering.send(.reach(allow: true), to: "n", through: session.engine)
        #expect(refused != nil)
    }

    /// Against a copy, an answer pressed between Face ID and the channel's attaching went to the Outbox, and the card
    /// said "Answered" although the Mac had not seen it and then refused it. The card is told it was kept, not taken.
    @Test func anAnswerTheOutboxKeptIsNotTakenAsAnswered() async throws {
        let folder = StoreFolder(FileManager.default.temporaryDirectory.appending(path: "pi2-test-\(UUID().uuidString)", directoryHint: .isDirectory))
        defer { try? folder.remove() }
        let store = PhoneStore(folder: folder)
        store.open(key: SymmetricKey(size: .bits256))
        let outbox = Outbox(store: store)
        let session = AppSession()
        session.start(CachedTransport(store.cache, outbox: outbox), as: .outOfReach(lastSeen: nil))
        let end = Date(timeIntervalSinceNow: 30)
        while session.engine.status != .connected, Date() < end { try await Task.sleep(for: .milliseconds(20)) }

        #expect(await NeedAnswering.deliver(.decide(.once), to: "134", through: session.engine) == .kept)
        #expect(outbox.items.map(\.method) == ["inbox.decide"])
        // The answer the cards of the older form read: no refusal, as before.
        #expect(await NeedAnswering.send(.question("Everyone"), to: "n1", through: session.engine) == nil)
        #expect(outbox.items.count == 2)

        // With no Outbox to keep it, it is refused in the cache's words.
        let alone = AppSession()
        alone.start(CachedTransport(store.cache), as: .outOfReach(lastSeen: nil))
        while alone.engine.status != .connected, Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await NeedAnswering.deliver(.decide(.deny), to: "134", through: alone.engine) == .refused(CachedTransport.needsTheMac))
        store.close()
    }

    /// Against a copy, Start anyway on a limit card whose project had spent more since was answered by the engine with
    /// no refusal, and the card kept with its new reading; the phone's card said "Answered" and stayed so, its buttons
    /// off, though nothing had started. A start still waiting after the engine took it is held again.
    @Test func aStartTheEngineHeldAgainIsNotAnswered() throws {
        let limit = try need("""
        {"id":"n4","projectId":"p-1","kind":"limit","conversationId":9,"rootConversationId":9,"title":"T","rootTitle":"T",
         "agentId":null,"agentName":"Orchestrator","blocking":false,"createdAt":1,
         "start":{"agentName":"Atlas","title":null,"task":"Check the build"},"limit":{"reason":"the project has spent $3.00 today"}}
        """)
        #expect(NeedHeldAgain.isHeldAgain(.limit(start: true), need: "n4", waiting: [limit]))
        // Started: the engine took it off the list.
        #expect(!NeedHeldAgain.isHeldAgain(.limit(start: true), need: "n4", waiting: []))
        // Left unstarted, or another kind's answer, is never held again.
        #expect(!NeedHeldAgain.isHeldAgain(.limit(start: false), need: "n4", waiting: [limit]))
        #expect(!NeedHeldAgain.isHeldAgain(.reach(allow: true), need: "n4", waiting: [limit]))
        #expect(!NeedHeldAgain.isHeldAgain(.limit(start: true), need: "n5", waiting: [limit]))
    }

    /// `PI2_NEEDS_PRESS=<need id>:<answer>`: the answer named, as the card's own button sends it, for each kind.
    @Test func aPressNamesTheAnswerItsCardWouldSend() throws {
        let approval = try need(id: "134", kind: "approval", at: 1)
        #expect(NeedsSamples.reply("134:once", to: approval, held: false) == .decide(.once))
        #expect(NeedsSamples.reply("134:always", to: approval, held: false) == .decide(.always))
        #expect(NeedsSamples.reply("134:rule", to: approval, held: false) == .decide(.rule))
        #expect(NeedsSamples.reply("134:deny", to: approval, held: false) == .decide(.deny))
        #expect(NeedsSamples.reply("135:deny", to: approval, held: false) == nil)
        #expect(NeedsSamples.reply("134", to: approval, held: false) == nil)
        #expect(NeedsSamples.reply("134:start", to: approval, held: false) == nil)
        let switched = try need("""
        {"id":"257","projectId":"p-1","kind":"approval","conversationId":9,"rootConversationId":9,"title":"T","rootTitle":"T",
         "agentId":null,"agentName":"Orchestrator","blocking":true,"createdAt":1,"tool":"project_agents","arguments":{},"projectSwitch":"makeAgents"}
        """)
        #expect(NeedsSamples.reply("257:once", to: switched, held: false) == .switchApproval(.once))
        let question = try need(id: "n1", kind: "question", at: 1)
        #expect(NeedsSamples.reply("n1:text:Everyone: the team", to: question, held: false) == .question("Everyone: the team"))
        #expect(NeedsSamples.reply("n1:text:Mention it", to: question, held: true) == .answerInbox("Mention it"))
        #expect(NeedsSamples.reply("n1:text:", to: question, held: false) == nil)
        let decision = try need(id: "n2", kind: "decision", at: 1)
        #expect(NeedsSamples.reply("n2:choice:c2", to: decision, held: false) == .choice("c2"))
        #expect(NeedsSamples.reply("n2:text:Both", to: decision, held: false) == .decisionWords("Both"))
        #expect(NeedsSamples.reply("n5:allow", to: try need(id: "n5", kind: "reach", at: 1), held: false) == .reach(allow: true))
        #expect(NeedsSamples.reply("n5:refuse", to: try need(id: "n5", kind: "reach", at: 1), held: false) == .reach(allow: false))
        #expect(NeedsSamples.reply("n3:accept", to: try need(id: "n3", kind: "rule", at: 1), held: false) == .acceptRule())
        #expect(NeedsSamples.reply("n3:refuse", to: try need(id: "n3", kind: "rule", at: 1), held: false) == .refuseRule)
        #expect(NeedsSamples.reply("n4:start", to: try need(id: "n4", kind: "limit", at: 1), held: false) == .limit(start: true))
        #expect(NeedsSamples.reply("n4:leave", to: try need(id: "n4", kind: "limit", at: 1), held: false) == .limit(start: false))
    }

    // MARK: - The whole call

    @Test func aCommandComesFirstAndEveryOtherArgumentFollowsWhole() {
        let long = String(repeating: "x", count: 5_000)
        let call = NeedCall(tool: "bash", arguments: .object([
            "timeout": .number(900),
            "command": .string("npm test && \(long)"),
            "background": .bool(true),
            "env": .object(["A": .string("1")]),
        ]))
        #expect(call.parts.first == NeedCall.Part(label: nil, text: "npm test && \(long)", code: true))
        #expect(call.parts.map(\.label) == [nil, "background", "env", "timeout"])
        #expect(call.parts[1].text == "true")
        #expect(call.parts[3].text == "900")
        #expect(call.parts[2].text.contains("\"A\" : \"1\""))
        // Nothing cut: every byte of the command is in what is shown and read.
        #expect(call.wholeText.contains(long))
    }

    @Test func aPathKeepsItsNameAndAFilesContentFollowsIt() {
        let call = NeedCall(tool: "write", arguments: .object(["path": .string("docs/a.md"), "content": .string("# A\n\nLine")]))
        #expect(call.parts == [
            NeedCall.Part(label: "path", text: "docs/a.md", code: true),
            NeedCall.Part(label: "content", text: "# A\n\nLine", code: true),
        ])
    }

    @Test func argumentsThatAreNotAnObjectAreShownToo() {
        #expect(NeedCall(tool: "x", arguments: .null).parts.isEmpty)
        #expect(NeedCall(tool: "x", arguments: .array([.string("a")])).parts.count == 1)
    }

    // MARK: - A call partly hidden from the phone

    @Test func thePlaceholderSaysAKeyWasHiddenWhereverItSits() {
        #expect(!NeedHiddenCall.isPartlyHidden(arguments: nil))
        #expect(!NeedHiddenCall.isPartlyHidden(arguments: .object(["command": .string("ls -la")])))
        #expect(NeedHiddenCall.isPartlyHidden(arguments: .object(["command": .string("curl -H 'Bearer [key hidden]' x")])))
        #expect(NeedHiddenCall.isPartlyHidden(arguments: .object(["env": .object(["TOKEN": .array([.string("[key hidden]")])])])))
        #expect(NeedHiddenCall.isPartlyHidden(arguments: .object(["[key hidden]": .string("v")])))
    }

    @Test func theEnginesMarkAloneMakesACallPartlyHidden() {
        // A value too deep to send leaves no placeholder the phone could see: the field is the only way to know of it.
        #expect(NeedHiddenCall.isPartlyHidden(mark: true, arguments: .object(["command": .string("echo plain")])))
        #expect(NeedHiddenCall.isPartlyHidden(mark: true, arguments: nil))
        // The placeholder of a value too deep, without the mark, still says so.
        #expect(NeedHiddenCall.isPartlyHidden(arguments: .object(["args": .string("[too deep to show]")])))
        #expect(NeedHiddenCall.isPartlyHidden(arguments: .object(["nested": .array([.object(["deep": .string("[too deep to show]")])])])))
        // Neither the mark nor a placeholder: the call can be answered from the phone.
        #expect(!NeedHiddenCall.isPartlyHidden(mark: false, arguments: .object(["command": .string("ls")])))
        // As with a key, a call whose own words hold the placeholder is treated as hidden, and can be allowed on the Mac.
        #expect(NeedHiddenCall.isPartlyHidden(arguments: .object(["command": .string("echo [too deep to show] as words")])))
    }

    @Test func theMarkDecodesAndItsAbsenceDecodesAsBefore() throws {
        // Without the key, as every recording before the mark: not hidden, whichever of the two objects carried it.
        let plainNeed = try need(id: "n", kind: "approval", at: 1)
        #expect(plainNeed.partHidden == nil && plainNeed.isPartlyHidden == false)
        #expect(try inboxItem("""
        {"id":"7","kind":"approval","conversationId":9,"callId":"c","tool":"bash","arguments":{"command":"ls"},"question":null,
         "title":"T","agentName":"Atlas","rootConversationId":9}
        """).isPartlyHidden == false)
        // With the mark.
        #expect(try need("""
        {"id":"n","projectId":null,"kind":"approval","conversationId":9,"rootConversationId":9,"title":"T","rootTitle":"T",
         "agentId":null,"agentName":"Atlas","blocking":false,"createdAt":1,"tool":"bash","arguments":{"command":"ls"},"partHidden":true}
        """).isPartlyHidden == true)
        #expect(try inboxItem("""
        {"id":"7","kind":"approval","conversationId":9,"callId":"c","tool":"bash","arguments":{"command":"ls"},"question":null,
         "title":"T","agentName":"Atlas","rootConversationId":9,"partHidden":true}
        """).isPartlyHidden == true)
        // Explicitly unmarked.
        #expect(try inboxItem("""
        {"id":"7","kind":"approval","conversationId":9,"callId":"c","tool":"bash","arguments":{"command":"ls"},"question":null,
         "title":"T","agentName":"Atlas","rootConversationId":9,"partHidden":false}
        """).partHidden == false)
        #expect(try inboxItem("""
        {"id":"7","kind":"approval","conversationId":9,"callId":"c","tool":"bash","arguments":{"command":"ls"},"question":null,
         "title":"T","agentName":"Atlas","rootConversationId":9,"partHidden":false}
        """).isPartlyHidden == false)
        // A value of the wrong type fails the item's decoding, as every other field does.
        #expect(throws: DecodingError.self) {
            try inboxItem("""
            {"id":"7","kind":"approval","conversationId":9,"callId":"c","tool":"bash","arguments":{"command":"ls"},"question":null,
             "title":"T","agentName":"Atlas","rootConversationId":9,"partHidden":"yes"}
            """)
        }
    }

    @Test func eitherObjectsMarkAloneMakesACallPartlyHidden() throws {
        // `NeedCard.hidden` is private to the view: it combines the two marks as this does, with
        // `(item?.isPartlyHidden ?? false) || need.isPartlyHidden`, and passes them to `isPartlyHidden`, which this tests.
        let markedItem = try inboxItem("""
        {"id":"7","kind":"approval","conversationId":9,"callId":"c","tool":"bash","arguments":{"command":"ls"},"question":null,
         "title":"T","agentName":"Atlas","rootConversationId":9,"partHidden":true}
        """)
        let markedNeed = try need("""
        {"id":"n","projectId":null,"kind":"approval","conversationId":9,"rootConversationId":9,"title":"T","rootTitle":"T",
         "agentId":null,"agentName":"Atlas","blocking":false,"createdAt":1,"tool":"bash","arguments":{"command":"ls"},"partHidden":true}
        """)
        let plainItem = try inboxItem("""
        {"id":"7","kind":"approval","conversationId":9,"callId":"c","tool":"bash","arguments":{"command":"ls"},"question":null,
         "title":"T","agentName":"Atlas","rootConversationId":9}
        """)
        let plainNeed = try need(id: "n", kind: "approval", at: 1)
        #expect(NeedHiddenCall.isPartlyHidden(mark: markedItem.isPartlyHidden || plainNeed.isPartlyHidden, arguments: plainItem.arguments))
        #expect(NeedHiddenCall.isPartlyHidden(mark: plainItem.isPartlyHidden || markedNeed.isPartlyHidden, arguments: plainItem.arguments))
        #expect(!NeedHiddenCall.isPartlyHidden(mark: plainItem.isPartlyHidden || plainNeed.isPartlyHidden, arguments: plainItem.arguments))
    }

    @Test func aHiddenKeyIsAPieceOfItsOwnNotTheCommandsText() {
        #expect(NeedHiddenCall.pieces(of: "a [key hidden] b[key hidden]") == [.text("a "), .hidden, .text(" b"), .hidden])
        #expect(NeedHiddenCall.pieces(of: "plain") == [.text("plain")])
        #expect(NeedHiddenCall.pieces(of: "") == [])
        #expect(!NeedHiddenCall.spoken("Bearer [key hidden] x").contains("["))
        #expect(NeedHiddenCall.spoken("Bearer [key hidden] x").contains("hidden key"))
    }

    // MARK: - Which cards, in which order

    @Test func cardsAreListedNewestFirstAndByProject() throws {
        let source = NeedsSource(
            needs: [
                try need(id: "a", at: 1_000),
                try need(id: "b", project: "p-2", at: 3_000),
                try need(id: "c", at: 2_000),
                try need(id: "d", at: 2_000),
                try need(id: "e", project: nil, at: 4_000),
            ],
            inbox: [],
            projects: []
        )
        #expect(source.shown(in: nil).map(\.id) == ["e", "b", "c", "d", "a"])
        #expect(source.shown(in: "p-1").map(\.id) == ["c", "d", "a"])
        #expect(source.shown(in: "p-3").isEmpty)
    }

    @Test func anApprovalFindsItsInboxItemAndOtherKindsDoNot() throws {
        let item = try inboxItem("""
        {"id":"7","kind":"approval","conversationId":9,"callId":"c","tool":"bash","arguments":{"command":"ls"},"question":null,
         "title":"T","agentName":"Atlas","rootConversationId":9}
        """)
        let source = NeedsSource(needs: [], inbox: [item], projects: [])
        #expect(source.item(for: try need(id: "7", kind: "approval", at: 1)) == item)
        #expect(source.item(for: try need(id: "7", kind: "reach", at: 1)) == nil)
        #expect(source.item(for: try need(id: "8", kind: "approval", at: 1)) == nil)
    }

    // MARK: - What an approval offers

    @Test func theWiderAnswersAreTheMacCardsAndNoneForASwitchOrASchedule() throws {
        func item(_ tool: String, extra: String = "") throws -> InboxItem {
            try inboxItem("""
            {"id":"1","kind":"approval","conversationId":9,"callId":"c","tool":"\(tool)","arguments":{"command":"npm test","app":"Notes"},
             "question":null,"title":"T","agentName":"Atlas","rootConversationId":9\(extra)}
            """)
        }
        let withRule = try item("bash", extra: #","rule":{"words":["npm","test"],"folder":"/x/site"}"#)
        #expect(NeedApprovalWords.always(item: withRule, agent: "Atlas").map(\.decision) == [.rule, .always])
        #expect(NeedApprovalWords.always(item: withRule, agent: "Atlas").first?.title == "Always allow “npm test” Here")
        #expect(NeedApprovalWords.always(item: try item("bash"), agent: nil).map(\.decision) == [.always])
        #expect(NeedApprovalWords.always(item: try item("bash", extra: #","projectSwitch":"merge""#), agent: nil).isEmpty)
        #expect(NeedApprovalWords.always(item: try item("schedule_task"), agent: nil).isEmpty)
        #expect(NeedApprovalWords.always(item: try item("browser"), agent: nil).isEmpty)
        #expect(NeedApprovalWords.always(item: try item("browser", extra: #","site":"example.com""#), agent: nil).map(\.title) == ["Always allow on example.com"])
        #expect(NeedApprovalWords.always(item: try item("computer"), agent: nil).map(\.title) == ["Always allow in Notes"])
        #expect(NeedApprovalWords.always(item: nil, agent: nil).isEmpty)
    }

    // MARK: - Inline, in a list's row

    /// A list sizes the row that holds Needs you inline by offering it no limit of height, then lays it out in the height
    /// that gave. Drawn in less than that, the cards sat in the middle of the row, a gap above the first (#830): so
    /// Needs you inline, every project's and each project's, must be as tall offered its own height as offered no limit,
    /// at the default size and the largest.
    @Test func inlineNeedsAreAsTallOfferedTheirHeightAsOfferedNoLimit() async throws {
        let transport = try #require(DemoTransport.recorded())
        transport.world.pace = 0.02
        let session = AppSession()
        session.start(transport, as: .demo)
        let end = Date(timeIntervalSinceNow: 30)
        while session.engine.needs.count < 2 || session.engine.inbox.isEmpty {
            #expect(Date() < end, "the demo's needs arrive")
            if Date() > end { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let projects = Set(session.engine.needs.compactMap(\.projectId)).sorted()
        #expect(!projects.isEmpty)
        for route in [Route.needs()] + projects.map({ Route.needs(project: $0) }) {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let probe = NeedsHeightProbe()
                let page = UIHostingController(rootView: NeedsHeightProbe.Measure(probe: probe) {
                    RouteView(route, placement: .inline)
                }
                .environment(session)
                .environment(\.dynamicTypeSize, size))
                _ = page.sizeThatFits(in: CGSize(width: 370, height: 20_000))
                let unlimited = try #require(probe.unlimited, "\(route) was measured")
                let offered = try #require(probe.offered)
                #expect(unlimited > 300, "\(route) at \(size) holds cards")
                #expect(abs(unlimited - offered) < 0.5, "\(route) at \(size): \(unlimited) offered no limit, \(offered) offered that")
            }
        }
    }
}

/// What a list's row does to what it holds: measures it offered no limit of height, then offered the height that gave.
@MainActor
final class NeedsHeightProbe {
    var unlimited: CGFloat?
    var offered: CGFloat?

    struct Measure: Layout {
        let probe: NeedsHeightProbe

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let row = subviews.first else { return .zero }
            let width = proposal.width ?? 370
            let unlimited = row.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let offered = row.sizeThatFits(ProposedViewSize(width: width, height: unlimited.height))
            MainActor.assumeIsolated {
                probe.unlimited = unlimited.height
                probe.offered = offered.height
            }
            return unlimited
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
