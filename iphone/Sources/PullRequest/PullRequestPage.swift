import EngineKit
import PiModels
import SwiftUI

/// One pull request's page (docs/design/iphone.md, "The Work tab, and a pull request with its diff"): its title, state
/// and branches; its checks; what reviewing agents found; its files, each opening its diff; and, while it is open, Merge
/// and Send back at the foot. What the Mac's Work tab shows of it (`ProjectWorkGitHub.pullPage`), and the same requests.
struct PullRequestPage: View {
    let key: PullRequestStore.Key
    let pull: PullRequestInfo
    let listing: PullRequestListing
    let diff: PullRequestStore.DiffState?
    /// Drawn from a debug build's sample, which the page says.
    let sample: Bool

    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @State private var confirmingMerge = false
    @State private var sendingBack = false
    @State private var reason = ""
    @State private var unfolded: Set<String> = []

    private static let end = "end"
    private var store: PullRequestStore { .shared }
    private var pending: String? { store.pending[key] }
    private var problem: String? { store.problems[key] }
    /// Whether Merge and Send back can be pressed: the read went well, nothing is on its way, and the Mac is there.
    private var canAct: Bool {
        pull.isOpen && !listing.troubled && pending == nil && session.engine.status == .connected
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                heading
                notices
                if !listing.unknown.isEmpty { unknownWrites }
                checks
                findings
                files
                Color.clear.frame(height: 1).listRowBackground(Color.clear).id(Self.end)
            }
            .listStyle(.insetGrouped)
            #if DEBUG
            .task {
                // `PI2_PR_SCROLL=bottom`: the files, for a picture, once the list is drawn.
                guard PullRequestSamples.bottom else { return }
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo(Self.end, anchor: .bottom)
            }
            #endif
        }
        .refreshable {
            await store.refresh(key, through: session.engine)
            store.readDiff(key, through: session.engine, again: true)
        }
        .safeAreaInset(edge: .bottom) {
            if pull.isOpen { actions }
        }
        // An alert rather than a confirmation dialog: its words scroll at the largest text sizes, and it sits in the middle
        // of the screen whatever opened it.
        .alert("Merge #\(pull.number) into \(pull.base)?", isPresented: $confirmingMerge) {
            Button("Merge") { merge() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(mergeWords)
        }
        .sheet(isPresented: $sendingBack) {
            PullRequestSendBack(pull: pull, reason: $reason, send: sendBack)
        }
        #if DEBUG
        .onAppear { PullRequestSamples.press(merge: { confirmingMerge = true }, sendBack: { sendingBack = true }, mergeNow: merge) }
        #endif
    }

    // MARK: - Heading

    private var heading: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(pull.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    PullRequestStateTag(pull: pull)
                    if case .read(let read)? = diff {
                        PullRequestCounts(additions: read.additions, removals: read.removals)
                    }
                }
                Text("\(pull.head) → \(pull.base)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("From \(pull.head) into \(pull.base)")
                if !pull.author.isEmpty {
                    Text("Opened by \(pull.author)\(pull.openedBy.map { " through pi², in sub-chat \($0)" } ?? "")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            if let work = pull.work {
                Button {
                    openRoute(.work(project: key.project, item: work))
                } label: {
                    PullRequestRowLabel(title: "Fixes #\(work)", systemImage: "checklist")
                }
                .accessibilityHint("Opens the work it fixes")
            }
            if let url = URL(string: pull.url), !pull.url.isEmpty {
                Link(destination: url) {
                    Label("Open on GitHub", systemImage: "arrow.up.forward.square")
                }
            }
        }
    }

    // MARK: - What the person should know first

    @ViewBuilder
    private var notices: some View {
        let lines = noticeLines
        if !lines.isEmpty || pending != nil || problem != nil {
            Section {
                if let pending {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("\(pending)…")
                    }
                    .accessibilityElement(children: .combine)
                }
                if let problem {
                    Label {
                        Text(problem).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    .textSelection(.enabled)
                }
                ForEach(lines, id: \.self) { line in
                    Label {
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    /// The plain facts that change what can be done: merged or closed, a conflict, a read that went wrong, a sample.
    private var noticeLines: [String] {
        var lines: [String] = []
        if sample {
            lines.append("Debug build: a sample pull request (PI2_PR_SAMPLE), not one your Mac sent. Its buttons send their requests to the engine like any other.")
        }
        if let trouble = listing.troubleWords() { lines.append(trouble) }
        switch pull.state {
        case "merged": lines.append("GitHub merged it into \(pull.base). Nothing here can merge or send it back again.")
        case "closed": lines.append("GitHub closed it without merging. Nothing here can merge or send it back again.")
        default:
            if pull.mergeable == "no" { lines.append("GitHub says it conflicts with \(pull.base), so it cannot be merged as it is.") }
            if pull.draft { lines.append("It is a draft: GitHub will not merge it until it is marked ready, on GitHub.") }
        }
        if session.engine.status != .connected, !sample {
            lines.append("Your Mac is not connected: nothing can be merged or sent back until it is.")
        }
        return lines
    }

    // MARK: - Writes whose outcome is not known

    private var unknownWrites: some View {
        Section {
            ForEach(listing.unknown) { write in
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your Mac's gh was cut off while it was \(write.summary), \(write.at.formatted(.relative(presentation: .named))). Look at the repository: say whether it happened. Nothing is written again until you do; if you say it did not, pi² tries the write again.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack { settleButtons(write) }
                        VStack(alignment: .leading) { settleButtons(write) }
                    }
                    .disabled(store.settling.contains(write.intent))
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Not known whether it reached GitHub")
        }
    }

    @ViewBuilder
    private func settleButtons(_ write: PullRequestUnknownWrite) -> some View {
        Button("It happened") { store.settle(write.intent, happened: true, for: key, through: session.engine) }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(write.summary): it happened")
        Button("It did not") { store.settle(write.intent, happened: false, for: key, through: session.engine) }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(write.summary): it did not happen")
    }

    // MARK: - Checks

    private var checks: some View {
        Section("Checks") {
            if pull.partial {
                Text("Not read: your Mac lists a closed pull request without its checks. The Mac reads them when it is opened there, and GitHub has them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label {
                    Text(pull.checksWords)
                } icon: {
                    Image(systemName: PullRequestLook.checksIcon(pull.checks)).foregroundStyle(PullRequestLook.checksColor(pull.checks))
                }
                if pull.checks == "failing", pull.failingChecks.isEmpty {
                    Text("GitHub shows which under the pull request; your Mac knows only that some failed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(pull.failingChecks) { check in
                    if let url = URL(string: check.url), !check.url.isEmpty {
                        Link(destination: url) {
                            PullRequestRowLabel(title: check.name, systemImage: "xmark.circle", tint: .red, outward: true)
                        }
                        .accessibilityLabel("Failing check \(check.name)")
                        .accessibilityHint("Opens its page on GitHub")
                    } else {
                        PullRequestRowLabel(title: check.name, systemImage: "xmark.circle", tint: .red)
                            .accessibilityLabel("Failing check \(check.name)")
                    }
                }
            }
        }
    }

    // MARK: - Findings

    private var findings: some View {
        Section("What reviewing agents found") {
            if pull.partial {
                Text("Not read: a closed pull request is listed without what reviewing agents found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if pull.findings.isEmpty {
                Text("No agent has posted a finding on it yet.")
                    .foregroundStyle(.secondary)
            }
            if !pull.partial {
                ForEach(pull.findingsNewestFirst) { finding in
                    PullRequestFindingRow(
                        finding: finding,
                        agent: session.engine.allAgents.first { $0.name == finding.agentName },
                        unfolded: unfolded.contains(finding.id),
                        toggle: {
                            if unfolded.contains(finding.id) { unfolded.remove(finding.id) } else { unfolded.insert(finding.id) }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Files

    private var files: some View {
        Section {
            switch diff {
            case nil, .reading?:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading the diff from your Mac…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .refused(let words)?:
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Your Mac did not send the diff: \(words)").fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Button("Try again") { store.readDiff(key, through: session.engine, again: true) }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            case .read(let read)?:
                if read.files.isEmpty {
                    Text("It changes no files.").foregroundStyle(.secondary)
                }
                ForEach(read.files) { file in
                    Button {
                        openRoute(.pullRequest(project: key.project, number: pull.number, file: file.path))
                    } label: {
                        PullRequestFileRow(file: file)
                    }
                }
                if let cut = read.cutNote {
                    Text(cut)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            if case .read(let read)? = diff {
                Text("Files · \(read.files.count)")
            } else {
                Text("Files")
            }
        }
    }

    // MARK: - Merge and Send back

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actionButtons }
            VStack(spacing: 8) { actionButtons }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            confirmingMerge = true
        } label: {
            Text("Merge").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        // As on the Mac, a conflict does not hold the button back: the notice says so, and GitHub answers for itself.
        .disabled(!canAct)
        .accessibilityHint("Asks first, then merges it into \(pull.base) on GitHub")
        Button {
            sendingBack = true
        } label: {
            Text("Send back").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!canAct)
        .accessibilityHint("Asks what to put right")
    }

    private var mergeWords: String {
        var words = "“\(pull.title)” goes from \(pull.head) into \(pull.base) on GitHub. It cannot be undone here: merging closes it and may close the work it fixes. Your Mac notes that it came from this iPhone."
        if pull.checks == "failing" { words += " Its checks are failing, and GitHub may refuse it for that." }
        if pull.checks == "pending" { words += " Its checks are still running." }
        return words
    }

    private func merge() {
        store.send(.merge(project: key.project, number: pull.number), for: key, shown: "Merging", through: session.engine)
    }

    private func sendBack() {
        let words = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        reason = ""
        store.send(.sendBack(project: key.project, number: pull.number, reason: words), for: key, shown: "Sending back",
                   through: session.engine, failed: { _ in
                       // What was typed comes back to the field, so nothing is lost.
                       if reason.isEmpty { reason = words }
                   })
    }
}

/// Send back's sheet: what to put right, and who is told.
struct PullRequestSendBack: View {
    let pull: PullRequestInfo
    @Binding var reason: String
    let send: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var empty: Bool { reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What to put right", text: $reason, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                        .accessibilityLabel("What to put right on pull request #\(pull.number)")
                } footer: {
                    Text(pull.openedBy.map { "The reason is posted on the pull request and given to sub-chat \($0), which opened it." }
                        ?? "The reason is posted on the pull request. Nobody opened it through pi², so no agent is told.")
                }
            }
            .navigationTitle("Send back #\(pull.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        send()
                        dismiss()
                    }
                    .disabled(empty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

/// One finding: who, the verdict and when, then its words, a long one folded to a few lines.
struct PullRequestFindingRow: View {
    let finding: PullRequestInfo.Finding
    let agent: AgentProfile?
    let unfolded: Bool
    let toggle: () -> Void

    private var long: Bool { finding.text.count > 280 || finding.text.components(separatedBy: "\n").count > 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                AgentMark(name: finding.agentName, color: agent?.color, size: 22, relativeTo: .subheadline)
                    .accessibilityHidden(true)
                Text("\(Text(finding.agentName).bold()) \(Text(PullRequestInfo.verdictWords(finding.verdict)).foregroundStyle(PullRequestLook.verdictColor(finding.verdict)))")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(finding.at, format: .relative(presentation: .named))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !finding.text.isEmpty {
                Text(PullRequestLook.markdown(finding.text))
                    .font(.subheadline)
                    .lineLimit(long && !unfolded ? 4 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                if long {
                    Button(unfolded ? "Show less" : "Show all", action: toggle)
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                        .accessibilityLabel(unfolded ? "Show less of \(finding.agentName)'s finding" : "Show all of \(finding.agentName)'s finding")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A file's row: its path, and what it adds and removes.
struct PullRequestFileRow: View {
    let file: PullRequestDiff.File

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // Colours, not `.primary` and `.secondary`, which a button's label would draw in its tint.
                Text(file.path)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let words = PullRequestLook.changeWords(file) {
                    Text(words)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if !file.binary {
                PullRequestCounts(additions: file.additions, removals: file.removals)
            }
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PullRequestLook.fileLabel(file))
        .accessibilityHint("Opens its diff")
        .accessibilityAddTraits(.isButton)
    }
}

/// "+132 −30", coloured; nothing for a side with none.
struct PullRequestCounts: View {
    let additions: Int
    let removals: Int

    var body: some View {
        HStack(spacing: 4) {
            if additions > 0 { Text("+\(additions)").foregroundStyle(PullRequestLook.added) }
            if removals > 0 { Text("−\(removals)").foregroundStyle(PullRequestLook.removed) }
        }
        .font(.footnote.monospacedDigit())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(additions == 0 && removals == 0 ? "No lines changed" : "\(additions) added, \(removals) removed")
    }
}

/// "Open", "Draft", "Merged" or "Closed", in a capsule of its colour.
struct PullRequestStateTag: View {
    let pull: PullRequestInfo

    var body: some View {
        let color = PullRequestLook.stateColor(pull)
        HStack(spacing: 4) {
            Image(systemName: PullRequestLook.stateIcon(pull))
            Text(pull.stateWords)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("State: \(pull.stateWords)")
    }
}

/// A row that opens something: an icon, its words, and a mark saying where it goes.
struct PullRequestRowLabel: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    /// It opens outside the app (GitHub, in the browser).
    var outward = false

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(title).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            Spacer(minLength: 4)
            Image(systemName: outward ? "arrow.up.forward" : "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

/// The colours, icons and words the pull request's screens share, the Mac's (`ProjectWorkGitHub`) in system colours.
enum PullRequestLook {
    static let added = Color.green
    static let removed = Color.red

    static func checksIcon(_ checks: String) -> String {
        switch checks {
        case "passing": "checkmark.circle.fill"
        case "failing": "xmark.circle.fill"
        case "pending": "clock.fill"
        default: "circle.dashed"
        }
    }

    static func checksColor(_ checks: String) -> Color {
        switch checks {
        case "passing": .green
        case "failing": .red
        case "pending": .orange
        default: .secondary
        }
    }

    static func verdictColor(_ verdict: String) -> Color {
        switch verdict {
        case "approve": .green
        case "changes": .orange
        default: .secondary
        }
    }

    static func stateColor(_ pull: PullRequestInfo) -> Color {
        switch pull.state {
        case "merged": .purple
        case "closed": .red
        default: pull.draft ? .secondary : .green
        }
    }

    static func stateIcon(_ pull: PullRequestInfo) -> String {
        switch pull.state {
        case "merged": "arrow.triangle.merge"
        case "closed": "xmark.circle"
        default: pull.draft ? "pencil.circle" : "arrow.triangle.pull"
        }
    }

    /// "Added", "Deleted", "Renamed from …", "Binary"; nil for a file changed in place.
    static func changeWords(_ file: PullRequestDiff.File) -> String? {
        var words: [String] = []
        switch file.change {
        case .added: words.append("Added")
        case .deleted: words.append("Deleted")
        case .renamed: words.append("Renamed from \(file.oldPath ?? "another path")")
        case .modified: break
        }
        if file.binary { words.append(words.isEmpty ? "Binary" : "binary") }
        return words.isEmpty ? nil : words.joined(separator: ", ")
    }

    /// What VoiceOver says of a file's row.
    static func fileLabel(_ file: PullRequestDiff.File) -> String {
        var label = file.path
        if let words = changeWords(file) { label += ", \(words)" }
        if !file.binary { label += ", \(file.additions) added, \(file.removals) removed" }
        return label
    }

    /// A finding's words with their inline Markdown, as the Mac shows them; the plain words if they are not Markdown.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
