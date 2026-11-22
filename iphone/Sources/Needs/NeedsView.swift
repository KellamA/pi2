import EngineKit
import PiModels
import SwiftUI

/// What needs the person: every card waiting, newest first, answered in place (docs/design/iphone.md, "A card that needs
/// the person"; docs/iphone.md P17). Drawn as a screen of its own, and inline at the top of the projects list
/// (`RouteView(.needs(), placement: .inline)`), where it draws its own header and nothing at all when nothing waits.
/// A card whose call is taller than its box opens on a screen of its own, with the whole call.
struct NeedsView: View {
    /// The project whose cards it shows, as `ProjectRow.id`; nil for every project's.
    let projectID: String?

    init(projectID: String? = nil) {
        self.projectID = projectID
    }

    @Environment(AppSession.self) private var session
    @Environment(\.placement) private var placement
    /// The card opened on a screen of its own, by its need's id.
    @State private var opened: OpenedNeed?

    private var source: NeedsSource { NeedsSource(session.engine) }
    private var needs: [NeedItem] { source.shown(in: projectID) }
    private var projectName: String? { projectID.flatMap { id in session.engine.projects.first { $0.id == id }?.name } }

    var body: some View {
        Group {
            if placement == .screen {
                screen
            } else {
                inline
            }
        }
        .sheet(item: $opened) { opened in
            NeedOpenedCard(needID: opened.id)
                .environment(session)
        }
        #if DEBUG
        .onChange(of: needs.map(\.id), initial: true) { _, ids in
            // `PI2_NEEDS_OPEN` (`NeedsSamples`): that card on a screen of its own, once it is shown.
            guard placement == .screen, !NeedsSamples.opened, let id = NeedsSamples.open, ids.contains(id) else { return }
            NeedsSamples.opened = true
            opened = OpenedNeed(id: id)
        }
        #endif
    }

    // MARK: - A screen of its own

    private var screen: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                NeedsConnectionLine(status: session.engine.status, connection: session.connection)
                #if DEBUG
                NeedsSamples.note
                #endif
                cards
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .overlay {
            if needs.isEmpty {
                ContentUnavailableView {
                    Label("Nothing needs you", systemImage: "checkmark.circle")
                } description: {
                    Text(projectName.map { "Nothing in \($0) waits for an answer." } ?? "No agent waits for an answer.")
                }
            }
        }
        .navigationTitle("Needs you")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if let projectName {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Needs you").font(.headline)
                        Text(projectName).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Inline, at the top of another screen

    @ViewBuilder
    private var inline: some View {
        if !needs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Needs you · \(needs.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel("Needs you, \(needs.count)")
                cards
            }
        }
    }

    private var cards: some View {
        ForEach(needs) { need in
            NeedCard(
                need: need,
                item: source.item(for: need),
                projectName: projectID == nil ? source.projectName(need.projectId) : nil,
                open: { opened = OpenedNeed(id: need.id) }
            )
        }
    }
}

/// The card opened on a screen of its own: given by its need's id, so that it shows the need as the engine has it now,
/// and says so when it no longer waits (answered here, on the Mac, or on another device).
struct OpenedNeed: Identifiable, Hashable {
    let id: String
}

struct NeedOpenedCard: View {
    let needID: String

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let source = NeedsSource(session.engine)
        NavigationStack {
            ScrollView {
                if let need = source.need(needID) {
                    NeedCard(need: need, item: source.item(for: need), projectName: source.projectName(need.projectId), opened: true)
                        .padding(16)
                } else {
                    ContentUnavailableView("This is no longer waiting", systemImage: "checkmark.circle", description: Text("It was answered or withdrawn."))
                        .padding(.top, 60)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Needs you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// A line over the cards when answers cannot reach the Mac now: the connection bar itself is the projects list's.
struct NeedsConnectionLine: View {
    let status: EngineSession<MessageField>.Status
    let connection: AppSession.Connection

    var body: some View {
        if let words {
            Label(words, systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var words: String? {
        switch connection {
        case .outOfReach:
            return "Your Mac cannot be reached: an answer cannot be sent until it can."
        case .connecting:
            return "Reaching your Mac: an answer can be sent once it is connected."
        default:
            return status == .connected ? nil : "Not connected to the engine: an answer cannot be sent yet."
        }
    }
}
