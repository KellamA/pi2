import SwiftUI
import WidgetKit

/// pi²'s widgets (docs/iphone.md 12.2, P31): Needs you, Who is working and Today's spending, on the Home Screen, the
/// Lock Screen and in StandBy, drawn from the widgets' file the app writes (`WidgetsFile`, in `Shared/`, with the
/// views), their content `privacySensitive` on the Lock Screen and in StandBy (`WidgetsPrivacy`). #700 (P30) adds the
/// Live Activity and the Dynamic Island in `LiveActivity/`, and its widget to this bundle. How the extensions are put
/// together is "The extensions" in docs/iphone-app.md.
@main
struct PiWidgets: WidgetBundle {
    var body: some Widget {
        NeedsWidget()
        WorkingWidget()
        SpendingWidget()
    }
}

struct NeedsWidget: Widget {
    var body: some WidgetConfiguration { WidgetsConfiguration.make(.needs) }
}

struct WorkingWidget: Widget {
    var body: some WidgetConfiguration { WidgetsConfiguration.make(.working) }
}

struct SpendingWidget: Widget {
    var body: some WidgetConfiguration { WidgetsConfiguration.make(.spending) }
}

enum WidgetsConfiguration {
    static func make(_ kind: WidgetsKind) -> some WidgetConfiguration {
        StaticConfiguration(kind: kind.kind, provider: WidgetsTimeline()) { entry in
            WidgetsEntryView(kind: kind, entry: entry)
        }
        .configurationDisplayName(kind.name)
        .description(kind.summary)
        .supportedFamilies(WidgetsKind.families)
    }
}
