import PiModels
import SwiftUI

/// One card that needs the person, answered in place (docs/design/iphone.md, "A card that needs the person"): who asks,
/// in which project and conversation, what, in full, and its buttons, which send what the Mac's card sends for the same
/// button (`NeedReply`). Every kind the engine sends has a card: an approval (with the Inbox's choices, or Allow once and
/// Deny when a project's switch asked), a question, a decision, more reach, a proposed rule, a start held back by a
/// limit; a kind this build does not know opens its conversation.
struct NeedCard: View {
    let need: NeedItem
    /// The Inbox's own item for an approval or a held question, which says what the Inbox offers (a rule, Always);
    /// nil when the Inbox has not sent it.
    let item: InboxItem?
    /// The project's name, for the line that says where it was asked.
    let projectName: String?
    /// Whether the card is shown on a screen of its own, with the whole call and no box that scrolls.
    var opened = false
    /// Opens the card on a screen of its own: given where the card is in a list.
    var open: (() -> Void)? = nil

    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The answer is on its way: a second press while it goes does nothing.
    @State private var sending = false
    /// The engine took the answer; the card stays, saying so, until the engine's list no longer holds it.
    @State private var answered = false
    /// The answer was kept in the Outbox, the Mac out of reach or not attached yet: it has not seen it.
    @State private var kept = false
    /// Why the engine did not take the answer, in its words.
    @State private var problem: String?
    /// A start allowed past a limit that the engine held again, its limit having moved on since the card was drawn.
    @State private var heldAgain = false
    /// An answer in words being typed.
    @State private var words = ""
    /// A proposed rule being changed before it is accepted.
    @State private var editingRule = false
    @State private var ruleText = ""
    @State private var ruleBinds = ProjectRule.Binds.everyone

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NeedCardHeader(need: need, kind: kindWords, projectName: projectName, agent: session.engine.agent(need.agentId)) {
                openRoute(.conversation(need.conversationId))
            }
            content
            outcome
        }
        // As tall as what it holds, whatever height it is offered. A list sizes a row by offering it no limit, then lays
        // it out in the height that gave: a card that came out shorter there (a line cut to one where it had wrapped)
        // sat in the middle of a row taller than its cards, a gap above the first (#830).
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if isApproval {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color(.systemOrange).opacity(0.45), lineWidth: 1)
            }
        }
        .disabled(sending || answered || kept)
        .accessibilityElement(children: .contain)
        .onChange(of: need.limit?.reason) {
            // The engine took Start anyway and kept the card with its new reading: the card is to be answered again.
            if answered, need.kind == "limit" { holdAgain() }
        }
        #if DEBUG
        .onAppear(perform: pressForPicture)
        .onChange(of: reachesTheMac) { pressForPicture() }
        #endif
    }

    #if DEBUG
    /// Whether an answer goes to the Mac now, on an attached channel (or the demo's, or the recording's), rather than to
    /// the Outbox.
    private var reachesTheMac: Bool {
        guard session.engine.status == .connected else { return false }
        switch session.connection {
        case .connected, .demo: return true
        case .notPaired, .connecting, .outOfReach: return false
        }
    }

    /// `PI2_NEEDS_PRESS` (`NeedsSamples`): presses this card's first answer once, for a picture of what follows. It waits
    /// until the answer would reach the Mac, so that it is the engine that takes or refuses it, unless
    /// `PI2_NEEDS_PRESS_WHEN=now` asks for it at once (to the Outbox, before the channel has attached). With
    /// `PI2_NEEDS_OPEN`, it is the opened card that is pressed, so that the picture shows what follows: the list draws
    /// only the cards on screen, and a card further down would not be pressed at all.
    private func pressForPicture() {
        guard let press = NeedsSamples.press, !NeedsSamples.pressed, reachesTheMac || NeedsSamples.pressNow,
              opened == (NeedsSamples.open != nil) else { return }
        if press == "\(need.id):edit", need.kind == "rule" {
            NeedsSamples.pressed = true
            ruleText = need.text ?? ""
            ruleBinds = need.binds ?? .everyone
            editingRule = true
        } else if press == need.id, let reply = firstReply {
            NeedsSamples.pressed = true
            send(reply)
        } else if let reply = NeedsSamples.reply(press, to: need, held: need.blocking && item != nil) {
            NeedsSamples.pressed = true
            send(reply)
        }
    }

    private var firstReply: NeedReply? {
        switch need.kind {
        case "approval": hidden ? denyReply : onceReply
        case "question": need.blocking && item != nil ? .answerInbox("Mention it") : .question("Everyone on the team")
        case "decision": need.choices?.first.map { .choice($0.id) }
        case "reach": .reach(allow: true)
        case "rule": .acceptRule()
        case "limit": .limit(start: true)
        default: nil
        }
    }
    #endif

    // MARK: - Kinds

    private var isApproval: Bool { need.kind == "approval" }

    /// What kind of card it is, in the words of the line above it.
    private var kindWords: String {
        switch need.kind {
        case "approval": need.projectSwitch != nil ? "approval · asks each time" : "approval"
        case "question": "question"
        case "decision": "decision"
        case "reach": "more reach"
        case "rule": "proposed rule"
        case "limit": "held back by a limit"
        default: need.named
        }
    }

    @ViewBuilder
    private var content: some View {
        switch need.kind {
        case "approval":
            if need.projectSwitch != nil || item != nil {
                approval
            } else {
                // The Inbox has not sent its item (or it belongs to a version of a chat not shown): the call, whole,
                // and the conversation that answers it, as the Mac's card does.
                plain(call: true)
            }
        case "question":
            question
        case "decision":
            decision
        case "reach":
            reach
        case "rule":
            rule
        case "limit":
            limit
        default:
            plain(call: false)
        }
    }

    // MARK: Approval

    private var call: NeedCall {
        NeedCall(tool: item?.tool ?? need.tool ?? "", arguments: item?.arguments ?? need.arguments ?? .null)
    }

    private var hidden: Bool {
        NeedHiddenCall.isPartlyHidden(mark: (item?.isPartlyHidden ?? false) || need.isPartlyHidden, arguments: item?.arguments ?? need.arguments)
    }

    @ViewBuilder
    private var approval: some View {
        Text(NeedApprovalWords.request(tool: call.tool, agent: need.agentName, arguments: item?.arguments ?? need.arguments, background: item?.background, site: item?.site))
            .font(.headline)
        if let described = NeedApprovalWords.described(item: item, need: need) {
            // What the app or the engine said the action would do, in words, before the call itself.
            Text(described)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        NeedCallView(call: call, limited: !opened, showAll: open)
        if call.tool == "bash", item?.background == true {
            footnote("It is started and left running, with no time limit, until it ends, the agent or you stop it, this conversation is archived, or pi² stops.")
        }
        if call.tool == "schedule_task" {
            footnote("Each run starts a new conversation with this agent and works with no one watching. You can turn the schedule off or delete it on the project's Settings tab, or on the template's page for a template.")
        }
        if let switchWords = need.switchWords {
            footnote("One of the project's switches is off, so it asks each time: \(switchWords). Only Allow once or Deny answer it.")
        }
        if hidden {
            hiddenNotice
            buttons {
                Button(role: .destructive) { send(denyReply) } label: { Text("Deny").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Refuses the call. Allowing it is possible only on your Mac")
            }
        } else {
            buttons {
                Button { send(onceReply) } label: { Text("Allow once").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Lets the agent make this call, this time")
                Button(role: .destructive) { send(denyReply) } label: { Text("Deny").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            alwaysMenu
        }
    }

    private var onceReply: NeedReply { need.projectSwitch != nil ? .switchApproval(.once) : .decide(.once) }
    private var denyReply: NeedReply { need.projectSwitch != nil ? .switchApproval(.deny) : .decide(.deny) }

    /// Part of the call was kept from the phone: say so plainly, and where it can be allowed.
    private var hiddenNotice: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Image(systemName: "eye.slash")
                .foregroundStyle(Color(.systemOrange))
                .accessibilityHidden(true)
            Text("Part of this call is hidden from your iPhone, so you cannot see all of it here. Allow it on your Mac, where it shows whole; from here you can only deny it.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemOrange).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    /// The Inbox's wider answers, as its card on the Mac offers them: a rule for commands that start the same way, and
    /// Always for this tool in this conversation. None when a project's switch asked, or for a schedule.
    @ViewBuilder
    private var alwaysMenu: some View {
        let offers = NeedApprovalWords.always(item: item, agent: need.agentName)
        if need.projectSwitch == nil, !offers.isEmpty {
            Menu {
                ForEach(offers, id: \.title) { offer in
                    Button { send(.decide(offer.decision)) } label: {
                        Text(offer.title)
                        Text(offer.detail)
                    }
                }
            } label: {
                Label("Always allow…", systemImage: "checkmark.seal")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Choices that stop asking about calls like this one")
        }
    }

    // MARK: Question and decision

    @ViewBuilder
    private var question: some View {
        Text(need.question ?? "")
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        if need.blocking {
            footnote("\(need.agentName ?? "The agent") waits for your answer before it goes on.")
        }
        // An agent held on its question is answered as the Inbox's card answers it; a question put with needs_you, as
        // the Now tab's card does.
        wordsField(placeholder: "Type an answer…") { text in
            need.blocking && item != nil ? .answerInbox(text) : .question(text)
        }
    }

    @ViewBuilder
    private var decision: some View {
        Text(need.question ?? "")
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        if let choices = need.choices {
            VStack(spacing: 8) {
                ForEach(choices, id: \.id) { choice in
                    Button { send(.choice(choice.id)) } label: {
                        Text(choice.label)
                            .frame(maxWidth: .infinity)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        if need.words == true {
            wordsField(placeholder: "Or answer in your own words…") { .decisionWords($0) }
        }
    }

    /// A field for an answer in words, with its Send.
    private func wordsField(placeholder: String, reply: @escaping (String) -> NeedReply) -> some View {
        let empty = words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // At the accessibility sizes the field takes the card's width, and Send goes under it.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: 8))
        return layout {
            field(placeholder)
            sendButton(empty: empty, reply: reply)
        }
    }

    private func field(_ placeholder: String) -> some View {
        TextField(placeholder, text: $words, axis: .vertical)
            .lineLimit(1...6)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 160)
    }

    private func sendButton(empty: Bool, reply: @escaping (String) -> NeedReply) -> some View {
        Button("Send") { send(reply(words)) }
            .buttonStyle(.borderedProminent)
            .disabled(empty)
    }

    // MARK: Reach, rule, limit

    @ViewBuilder
    private var reach: some View {
        Text(need.change?.summary ?? "")
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        if let why = need.why {
            Text("Why: \(why)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        buttons {
            Button { send(.reach(allow: true)) } label: { Text("Allow").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Gives the agents the reach it asks for")
            Button(role: .destructive) { send(.reach(allow: false)) } label: { Text("Refuse").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var rule: some View {
        if editingRule {
            TextField("The rule", text: $ruleText, axis: .vertical)
                .lineLimit(2...8)
                .textFieldStyle(.roundedBorder)
            Text("Would bind")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("Would bind", selection: $ruleBinds) {
                ForEach(ProjectRule.Binds.allCases) { binds in
                    Text(binds.title).tag(binds)
                }
            }
            .pickerStyle(.segmented)
            buttons {
                Button {
                    send(.acceptRule(text: ruleText.trimmingCharacters(in: .whitespacesAndNewlines), binds: ruleBinds))
                } label: { Text("Save").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(ruleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button { editingRule = false } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
        } else {
            Text("“\(need.text ?? "")”")
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let why = need.why {
                Text("Why: \(why)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Would bind: \(need.binds?.title ?? "every agent")")
                .font(.footnote)
                .foregroundStyle(.secondary)
            buttons {
                Button { send(.acceptRule()) } label: { Text("Accept").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button {
                    ruleText = need.text ?? ""
                    ruleBinds = need.binds ?? .everyone
                    editingRule = true
                } label: { Text("Edit…").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Change the rule, or whom it binds, before accepting it")
                Button(role: .destructive) { send(.refuseRule) } label: { Text("Refuse").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var limit: some View {
        if let start = need.start {
            let what = [start.title, start.task].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            if !what.isEmpty {
                Text("\(start.agentName ?? "An agent") wants to start “\(what)”")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Text("Past the project's limit: \(need.limit?.reason ?? "the project's limit stops new work"). You can start it anyway from here, or raise the limit in the project's settings.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        buttons {
            Button { send(.limit(start: true)) } label: { Text("Start anyway").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Starts it past the limit")
            Button { send(.limit(start: false)) } label: { Text("Leave it").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
                .accessibilityHint("Drops the start; the orchestrator hears of it")
        }
    }

    /// A kind this build does not answer, or an approval whose Inbox item has not come: what it says, and its
    /// conversation, which answers it.
    @ViewBuilder
    private func plain(call shown: Bool) -> some View {
        if shown {
            Text(NeedApprovalWords.request(tool: call.tool, agent: need.agentName, arguments: need.arguments, background: nil, site: nil))
                .font(.headline)
            NeedCallView(call: call, limited: !opened, showAll: open)
        } else {
            Text(need.short)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        Button {
            openRoute(.conversation(need.rootConversationId))
        } label: {
            Label("Answer it in its conversation", systemImage: "bubble.left.and.text.bubble.right")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Pieces

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A card's buttons side by side, or one above another when they do not fit (the largest text).
    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content() }
            VStack(spacing: 8) { content() }
        }
        .controlSize(.large)
    }

    /// The answer's state: on its way, taken, or refused with the engine's words.
    @ViewBuilder
    private var outcome: some View {
        if sending {
            HStack(spacing: 8) {
                ProgressView()
                Text("Sending…").font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if answered {
            Label("Answered", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color(.systemGreen))
        } else if kept {
            Label {
                Text("Kept in the Outbox. It goes to your Mac once it can be reached, and the Outbox says if your Mac did not take it.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "tray.and.arrow.up")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else if heldAgain {
            Label {
                Text("Still held: the limit's reading moved on since this was shown, so nothing was started. Read it again above, and start it anyway again if you still want it.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else if let problem {
            Label {
                Text("Not sent. \(problem)")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.footnote)
            .foregroundStyle(Color(.systemRed))
            .accessibilityElement(children: .combine)
        }
    }

    private func send(_ reply: NeedReply) {
        guard !sending, !answered, !kept else { return }
        sending = true
        problem = nil
        heldAgain = false
        Task {
            let sent = await NeedAnswering.deliver(reply, to: need.id, through: session.engine)
            sending = false
            switch sent {
            case .refused(let why):
                problem = why
                UIAccessibility.post(notification: .announcement, argument: "Not sent. \(why)")
            case .taken, .kept:
                answered = sent == .taken
                kept = sent == .kept
                words = ""
                editingRule = false
                if kept { UIAccessibility.post(notification: .announcement, argument: "Kept in the Outbox, for when your Mac can be reached.") }
                // Start anyway past a limit that moved on: the engine answers it and keeps the card, with its new
                // reading, rather than refusing it (`onAnswer("limit")`, engine/src/projectlimitstarts.ts). An engine
                // from before #953 does not say so, but the card is still waiting.
                if answered, NeedHeldAgain.isHeldAgain(reply, need: need.id, waiting: session.engine.needs) { holdAgain() }
            case .held:
                holdAgain()
            }
        }
    }

    private func holdAgain() {
        answered = false
        heldAgain = true
        UIAccessibility.post(notification: .announcement, argument: "Still held: the limit moved on. Read it again before starting it anyway.")
    }
}

/// The line over a card: the agent that asks, the kind of card, and where and when it was asked. The place opens the
/// conversation that asks.
struct NeedCardHeader: View {
    let need: NeedItem
    let kind: String
    let projectName: String?
    let agent: AgentProfile?
    let openConversation: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // At the accessibility sizes the mark gives its width to the words, which then never break inside a name.
            if !typeSize.isAccessibilitySize {
                NeedAgentMark(name: need.agentName, color: agent?.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                let name = Text(need.agentName ?? "An agent").font(.subheadline.weight(.semibold))
                let kind = Text(kind).font(.caption.weight(.medium)).foregroundStyle(.tint)
                if typeSize.isAccessibilitySize {
                    name
                    kind
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        name
                        kind
                    }
                }
                Button(action: openConversation) {
                    Text(placeLine)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Asked \(placeLine)")
                .accessibilityHint("Opens the conversation")
            }
            Spacer(minLength: 0)
        }
    }

    /// "Demo project · in “Verify the preview” · 5 minutes ago".
    private var placeLine: String {
        let asked = Date(timeIntervalSince1970: need.createdAt / 1000).formatted(.relative(presentation: .named))
        let place = need.fromSubChat ? "in \(need.placeWords)" : "in “\(need.placeWords)”"
        return [projectName, place, asked].compactMap { $0 }.joined(separator: " · ")
    }
}

/// An agent's mark beside its card: its initial on its colour. Decoration: VoiceOver reads the name beside it.
struct NeedAgentMark: View {
    let name: String?
    let color: String?
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 28

    var body: some View {
        Text(String((name ?? "?").prefix(1)).uppercased())
            .font(.system(size: side * 0.5, weight: .semibold))
            .foregroundStyle(.black.opacity(0.75))
            .frame(width: side, height: side)
            .background(AgentColor.color(color), in: Circle())
            .accessibilityHidden(true)
    }
}
