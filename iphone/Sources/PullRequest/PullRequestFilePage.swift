import EngineKit
import PiModels
import SwiftUI

/// One file's diff, the pull request's sub-page (docs/design/iphone.md, "The Work tab, and a pull request with its
/// diff"): its lines wrapped, additions and removals coloured, with the previous and next file a tap away. **Wrap** off,
/// long lines scroll sideways inside the diff instead; either way nothing is cut off, at the largest text size too. A
/// very large file shows its first lines and more at each tap, and a very long line its first characters
/// (`PullRequestDiffBounds`).
struct PullRequestFilePage: View {
    let key: PullRequestStore.Key
    let number: Int
    let diff: PullRequestStore.DiffState?
    let sample: Bool

    @Environment(AppSession.self) private var session
    /// The file shown: the route's, then whichever the person moved to with the previous and next buttons.
    @State private var path: String
    @State private var wrap = true
    @State private var shownLines = PullRequestDiffBounds.firstLines

    init(key: PullRequestStore.Key, number: Int, path: String, diff: PullRequestStore.DiffState?, sample: Bool) {
        self.key = key
        self.number = number
        self.diff = diff
        self.sample = sample
        _path = State(initialValue: path)
        #if DEBUG
        _wrap = State(initialValue: PullRequestSamples.wrap)
        #endif
    }

    var body: some View {
        Group {
            switch diff {
            case nil, .reading?:
                ProgressView("Reading the diff from your Mac…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .refused(let words)?:
                PullRequestUnavailable {
                    ContentUnavailableView {
                        Label("Your Mac did not send the diff", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(words)
                    } actions: {
                        Button("Try again") { PullRequestStore.shared.readDiff(key, through: session.engine, again: true) }
                            .buttonStyle(.bordered)
                    }
                }
            case .read(let read)?:
                if let file = read.file(path) {
                    page(file, in: read)
                } else {
                    PullRequestUnavailable {
                        ContentUnavailableView(
                            "Not in the diff", systemImage: "doc.questionmark",
                            description: Text(read.cutNote != nil
                                ? "\(path) is not in the part of the diff your Mac sent: the diff is longer than 2 MB, and was cut. The Mac and GitHub show all of it."
                                : "Pull request #\(number) no longer changes \(path).")
                        )
                    }
                }
            }
        }
        .navigationTitle(PullRequestDiff.File.name(of: path))
        .onChange(of: path) { _, _ in shownLines = PullRequestDiffBounds.firstLines }
    }

    private func page(_ file: PullRequestDiff.File, in diff: PullRequestDiff) -> some View {
        let index = diff.files.firstIndex { $0.path == file.path } ?? 0
        return lines(file)
            .toolbar {
                if !file.binary, !file.lines.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            wrap.toggle()
                        } label: {
                            Label(wrap ? "Scroll long lines sideways" : "Wrap long lines",
                                  systemImage: wrap ? "arrow.left.and.right.text.vertical" : "text.justify.left")
                        }
                        .accessibilityLabel(wrap ? "Lines wrapped. Scroll long lines sideways instead" : "Long lines scroll sideways. Wrap them instead")
                    }
                }
                // With one file there is nowhere else to go.
                if diff.files.count > 1 {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            path = diff.files[index - 1].path
                        } label: {
                            Label("Previous file", systemImage: "chevron.backward")
                        }
                        .disabled(index == 0)
                        Spacer()
                        Text("\(index + 1) of \(diff.files.count)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("File \(index + 1) of \(diff.files.count)")
                        Spacer()
                        Button {
                            path = diff.files[index + 1].path
                        } label: {
                            Label("Next file", systemImage: "chevron.forward")
                        }
                        .disabled(index + 1 >= diff.files.count)
                    }
                }
            }
    }

    /// The file's path and what it adds and removes, at the top of what scrolls, so that at the largest text sizes it
    /// scrolls away rather than taking the screen.
    private func header(_ file: PullRequestDiff.File) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if sample {
                Text("Debug build: a sample diff (PI2_PR_SAMPLE), not one your Mac sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(file.path)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let words = PullRequestLook.changeWords(file) {
                    Text(words).font(.footnote).foregroundStyle(.secondary)
                }
                if !file.binary { PullRequestCounts(additions: file.additions, removals: file.removals) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func lines(_ file: PullRequestDiff.File) -> some View {
        if file.binary || file.lines.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    header(file)
                    Divider()
                    if file.binary {
                        ContentUnavailableView(
                            "A binary file", systemImage: "doc",
                            description: Text("Its change is not lines of text, so there is nothing to show here. GitHub shows it.")
                        )
                    } else {
                        ContentUnavailableView(
                            "No lines changed", systemImage: "doc.text",
                            description: Text(file.change == .renamed ? "It was renamed, and its lines are as they were." : "Only the file's mode changed.")
                        )
                    }
                }
            }
        } else {
            PullRequestDiffLines(file: file, wrap: wrap, shown: $shownLines) {
                header(file)
                Divider()
            }
        }
    }
}

/// A file's lines, in a scrolling column: wrapped to the screen's width, or each on one line with the whole diff
/// scrolling sideways. Drawn lazily, so a long file costs only the lines on screen.
struct PullRequestDiffLines<Header: View>: View {
    let file: PullRequestDiff.File
    let wrap: Bool
    @Binding var shown: Int
    /// What is above the lines, which scrolls with them, and stays the screen's width when they scroll sideways.
    @ViewBuilder let header: () -> Header

    @State private var width: CGFloat = 0

    var body: some View {
        let lines = file.lines.prefix(shown)
        let left = file.lines.count - lines.count
        ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) { header() }
                    .frame(width: wrap ? nil : width)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    PullRequestDiffLine(line: line, wrap: wrap)
                }
                if left > 0 {
                    Button("Show \(min(left, PullRequestDiffBounds.firstLines).formatted()) more of \(left.formatted()) lines") {
                        shown += PullRequestDiffBounds.firstLines
                    }
                    .buttonStyle(.bordered)
                    .padding(16)
                }
                if file.cut {
                    Text("Your Mac cut the diff here: it is longer than 2 MB. The Mac and GitHub show the rest.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                        .frame(width: wrap ? nil : width, alignment: .leading)
                }
            }
            // Sideways, the column is as wide as its widest line, and never narrower than the screen, so that each line's
            // colour reaches the edge.
            .frame(minWidth: wrap ? nil : width, alignment: .leading)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// One line of a diff: its mark (`+`, `−`, or none) in a column of its own, so that a wrapped line's continuation stays
/// under its text, then the text in a monospaced face that grows with the text size.
struct PullRequestDiffLine: View {
    let line: PullRequestDiff.Line
    let wrap: Bool

    var body: some View {
        let (text, left) = PullRequestDiffBounds.shown(line.text.replacingOccurrences(of: "\t", with: "    "))
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(mark)
                .foregroundStyle(markColor)
                .frame(minWidth: 10, alignment: .leading)
            Group {
                if left > 0 {
                    Text("\(Text(text))\(Text(" … \(left.formatted()) more characters, on the Mac").foregroundStyle(.secondary))")
                } else {
                    Text(text.isEmpty ? " " : text)
                }
            }
            .foregroundStyle(line.kind == .hunk || line.kind == .note ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .italic(line.kind == .note)
            .fixedSize(horizontal: !wrap, vertical: true)
        }
        .font(.footnote.monospaced())
        .padding(.horizontal, 8)
        .padding(.vertical, line.kind == .hunk ? 4 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PullRequestDiffLine.label(line))
    }

    private var mark: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private var markColor: Color {
        switch line.kind {
        case .added: PullRequestLook.added
        case .removed: PullRequestLook.removed
        default: .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: PullRequestLook.added.opacity(0.14)
        case .removed: PullRequestLook.removed.opacity(0.14)
        case .hunk: Color(.secondarySystemBackground)
        default: .clear
        }
    }

    /// What VoiceOver says of a line: what happened to it, its number, and its text.
    static func label(_ line: PullRequestDiff.Line) -> String {
        let text = PullRequestDiffBounds.shown(line.text).text.trimmingCharacters(in: .whitespaces)
        let words = text.isEmpty ? "empty" : text
        switch line.kind {
        case .added: return "Added, line \(line.new ?? 0): \(words)"
        case .removed: return "Removed, line \(line.old ?? 0): \(words)"
        case .context: return "Line \(line.new ?? 0): \(words)"
        case .hunk: return "Changes from line \(line.new ?? 0)"
        case .note: return words
        }
    }
}
