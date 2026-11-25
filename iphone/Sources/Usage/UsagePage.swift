import EngineKit
import PiModels
import SwiftUI

/// The Usage page's list, drawn from a reading of the engine's state (`UsageReading`), in the Mac's order: what was spent,
/// the plans' windows, the daily budget, the last fourteen days, and the spend by project, model, agent and conversation.
/// Its two controls send the Mac's requests (`UsageRequests`) and say beside themselves what the engine answered.
struct UsagePage: View {
    let reading: UsageReading
    let engine: EngineSession<MessageField>
    /// What the connection bar says. While the Mac is out of reach or being reached, the page shows what the phone kept
    /// of its last state, and a change could only be refused: its controls wait, as Settings' do.
    var connection: AppSession.Connection = .connected(.home)

    @Environment(\.openRoute) private var openRoute

    @State private var budgetText = ""
    @State private var budgetProblem: String?
    @State private var budgetSending = false
    @FocusState private var budgetFocused: Bool
    /// Subscriptions this page is asking about right now, and what the engine said when it could not.
    @State private var asking: Set<String> = []
    @State private var refreshProblems: [String: String] = [:]

    var body: some View {
        // Drawn again every half minute so "resets in" and "checked" stay true, as on the Mac.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollViewReader { scroller in
                list(now: context.date)
                    #if DEBUG
                    .task { await UsageDebug.scroll(scroller) }
                    #endif
            }
        }
        .onAppear {
            budgetText = Self.budgetField(reading.usage?.budget.daily)
        }
        // The stale subscriptions are asked about once the Mac can be reached: asked from the phone's last state, the
        // request is refused, and nothing would ask again when the channel comes.
        .onChange(of: canSend, initial: true) { _, live in
            if live { refreshStale() }
        }
        .onChange(of: reading.usage?.budget.daily) { _, daily in
            if !budgetFocused { budgetText = Self.budgetField(daily) }
        }
        #if DEBUG
        .task(id: canSend) { if canSend { await act() } }
        #endif
    }

    private var canSend: Bool { Self.canSend(connection, engineConnected: engine.status == .connected) }

    /// Whether a change can reach the Mac now: the client connected on a live channel (or the demo). While the bar says
    /// the Mac is out of reach or being reached, the client shows the phone's last state, which refuses every change.
    static func canSend(_ connection: AppSession.Connection, engineConnected: Bool) -> Bool {
        switch connection {
        case .outOfReach, .connecting, .notPaired: false
        case .demo, .connected: engineConnected
        }
    }

    private func list(now: Date) -> some View {
        List {
            #if DEBUG
            if UsageSample.isOn {
                Section {
                    Label("Sample values for a debug build's pictures, not your Mac's. Its buttons still ask the engine.", systemImage: "testtube.2")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            #endif
            if !canSend {
                Section {
                    SettingsConnectionLine(connected: false, connection: connection)
                }
            }
            Section("Spending") {
                ForEach(reading.amounts(now: now), id: \.title) { amount in
                    UsageAmountRow(amount: amount)
                }
            }
            .id("spending")

            plans(now: now)
            budget
            Section {
                UsageDaysChart(days: reading.chartDays(now: now))
                    .id("days")
            } header: {
                Text("Last 14 days")
            }

            bars("By project, today", reading.projectRows, id: "projects",
                 footer: "Today's spend in each project's conversations, sub-chats included, against its daily limit where it has one.")
            bars("By model", reading.modelRows, id: "models")
            bars("By agent", reading.agentRows, id: "agents")
            bars("Conversations that used the most", reading.conversationRows, id: "conversations")

            Section {
            } footer: {
                Text("Cost is an estimate for models you pay for by use, such as an API key. Subscriptions, local models and use with no known price count tokens only and do not count towards the budget. Your provider can still charge for pictures whose price pi² does not know.")
                    .id("note")
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Plan limits

    private func plans(now: Date) -> some View {
        Section {
            if reading.providers.isEmpty {
                UsageQuietLine(text: "No subscription is signed in on your Mac, so there are no plan windows to show. Sign-ins are made on the Mac.")
            }
            ForEach(reading.providers) { provider in
                UsagePlanCard(
                    provider: provider, now: now, asking: asking.contains(provider.id), problem: refreshProblems[provider.id],
                    canCheck: canSend, check: { refresh(provider.id) }
                )
            }
        } header: {
            Text("Plan limits")
        } footer: {
            if !reading.providers.isEmpty {
                Text("How much of each subscription's allowance is used, as the provider reports it. Windows above 80% are marked.")
            }
        }
        .id("plans")
    }

    /// Asks about each subscription whose figures are more than an hour old, as the Mac's Usage does each time it opens.
    /// A failure shows on its card through the `limits` event, so it is not said again here.
    private func refreshStale() {
        for id in UsageLimits.stale(reading.providers) where !asking.contains(id) {
            refresh(id, quietly: true)
        }
    }

    private func refresh(_ id: String, quietly: Bool = false) {
        asking.insert(id)
        refreshProblems[id] = nil
        Task {
            let problem = await UsageRequests.refreshLimits(engine, provider: id)
            asking.remove(id)
            if let problem, !quietly { refreshProblems[id] = "Could not check now: \(problem)" }
        }
    }

    // MARK: - The daily budget

    private var budget: some View {
        Section {
            if let budget = reading.budget {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: budget.fraction)
                        .tint(budget.over ? .red : .pi2Accent)
                        .accessibilityHidden(true)
                    Group {
                        if budget.over {
                            Label {
                                Text(budget.line)
                            } icon: {
                                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                            }
                        } else {
                            Text(budget.line)
                        }
                    }
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 6) {
                Text("$").foregroundStyle(.secondary)
                TextField("No limit", text: $budgetText)
                    .keyboardType(.decimalPad)
                    .focused($budgetFocused)
                    .accessibilityLabel("Daily budget in dollars")
            }
            Button(budgetSending ? "Setting…" : "Set Budget", action: saveBudget)
                .disabled(budgetSending || !canSend || budgetText.trimmingCharacters(in: .whitespaces).isEmpty)
            if reading.budget != nil {
                Button("Remove Limit", role: .destructive, action: removeBudget)
                    .disabled(budgetSending || !canSend)
            }
            if let budgetProblem {
                UsageProblem(text: budgetProblem)
                    .id("budget-problem")
            }
        } header: {
            Text("Daily budget")
        } footer: {
            if reading.budget == nil {
                Text("With a limit, new messages and scheduled runs are held once the day's spend reaches it.")
            }
        }
        .id("budget")
    }

    /// "5.00" for a budget of five dollars; empty for none.
    static func budgetField(_ daily: Double?) -> String {
        daily.map { String(format: "%.2f", $0) } ?? ""
    }

    private func saveBudget() {
        switch UsageRequests.budgetAmount(budgetText) {
        case .failure(let problem):
            budgetProblem = problem.message
        case .success(let value):
            send(value)
        }
    }

    private func removeBudget() {
        send(nil)
    }

    private func send(_ daily: Double?) {
        budgetFocused = false
        budgetProblem = nil
        budgetSending = true
        Task {
            let problem = await UsageRequests.setBudget(engine, daily: daily)
            budgetSending = false
            if let problem {
                // Not taken: the field goes back to the budget the engine still has.
                budgetProblem = "The budget was not changed: \(problem)"
                budgetText = Self.budgetField(reading.usage?.budget.daily)
            } else if daily == nil {
                budgetText = ""
            }
        }
    }

    // MARK: - The lists

    private func bars(_ title: String, _ rows: [UsageReading.Row], id: String, footer: String? = nil) -> some View {
        let most = max(rows.map(\.value).max() ?? 1, 1)
        return Section {
            if rows.isEmpty {
                UsageQuietLine(text: "Nothing yet.")
            }
            ForEach(rows) { row in
                if let route = row.route {
                    Button { openRoute(route) } label: {
                        UsageBarRow(row: row, most: most, opens: true)
                    }
                    .tint(.primary)
                } else {
                    UsageBarRow(row: row, most: most, opens: false)
                }
            }
        } header: {
            Text(title)
        } footer: {
            if let footer, !rows.isEmpty { Text(footer) }
        }
        .id(id)
    }

    #if DEBUG
    /// What `PI2_USAGE_ACT` asked for, sent once as the page shows, as a tap would send it.
    private func act() async {
        if let amount = UsageDebug.take("budget") {
            budgetText = amount
            saveBudget()
        }
        if UsageDebug.take("remove") != nil { removeBudget() }
        if let id = UsageDebug.take("refresh") {
            refresh(id.isEmpty ? reading.providers.first?.id ?? "" : id)
        }
    }
    #endif
}
