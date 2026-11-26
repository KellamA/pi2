import ActivityKit
import SwiftUI
import WidgetKit

/// A followed project's Live Activity, as the widgets extension draws it (`PiWidgets`): the Lock Screen's view and the
/// Dynamic Island's compact, minimal and expanded forms (`ProjectActivityViews.swift`). A tap anywhere opens the
/// project's hub (`ProjectActivityLink`).
struct ProjectActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ProjectActivityAttributes.self) { context in
            ProjectActivityLockView(name: context.attributes.projectName, state: context.state)
                .widgetURL(ProjectActivityLink(projectID: context.attributes.projectID).url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ProjectActivityExpandedLeading(name: context.attributes.projectName)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ProjectActivityExpandedTrailing(state: context.state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProjectActivityExpandedBottom(state: context.state)
                }
            } compactLeading: {
                ProjectActivityCompactLeading(name: context.attributes.projectName)
            } compactTrailing: {
                ProjectActivityCompactTrailing(state: context.state)
            } minimal: {
                ProjectActivityMinimal(state: context.state)
            }
            .widgetURL(ProjectActivityLink(projectID: context.attributes.projectID).url)
            .keylineTint(WidgetsColor.accent)
        }
    }
}
