import EngineKit
import PiModels
import SwiftUI

/// The strip along the top of the Dashboard: a button for each page, by its project's name, with an orange mark on a
/// project where something needs the person and a spinner where agents work. The page shown is filled; tapping another
/// goes to it.
struct DashboardStrip: View {
    let pages: [ProjectRow]
    @Binding var page: String?

    @Environment(AppSession.self) private var session

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pages) { project in
                        chip(project)
                            .id(project.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            // Capped as the bars of the system are, so that the pages keep the screen; held down, a name shows large.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .onChange(of: page) { _, page in
                guard let page else { return }
                withAnimation { scroller.scrollTo(page, anchor: .center) }
            }
        }
        .background(.bar)
    }

    @ViewBuilder
    private func chip(_ project: ProjectRow) -> some View {
        let engine = session.engine
        let needs = engine.hubNeeds(project.id).count
        let working = engine.hubRuns(project.id).count
        let shown = page == project.id
        let button = Button {
            withAnimation { page = project.id }
        } label: {
            HStack(spacing: 6) {
                Text(project.name)
                    .lineLimit(1)
                if needs > 0 {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                } else if working > 0 {
                    Circle()
                        .fill(shown ? Color.white : Color.accentColor)
                        .frame(width: 8, height: 8)
                }
            }
            .font(.subheadline.weight(shown ? .semibold : .regular))
        }
        .buttonBorderShape(.capsule)
        .accessibilityShowsLargeContentViewer {
            Text(project.name)
        }
        .accessibilityLabel(project.name)
        .accessibilityValue([
            needs > 0 ? (needs == 1 ? "1 needs you" : "\(needs) need you") : nil,
            working > 0 ? "\(working) working" : nil,
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(shown ? .isSelected : [])
        .accessibilityHint("Shows the project's page.")
        if shown {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered).tint(.primary)
        }
    }
}
