import Foundation
import PiModels

extension ProjectActivityAttributes.ContentState {
    /// A project's numbers as the app counts them from what its client holds, the same way the Mac counts the ones it
    /// pushes (docs/iphone-app.md, "The Live Activity"): `working`, the runs in the Activity list that are the project's
    /// and not a chat's; `needs`, its items in Needs you; `finished`, given, since only the Mac sees runs end while the
    /// app is closed (the activity's own number, or 0 at its start). `at` is when the client last heard from the Mac.
    static func counted(
        projectID: String, activity: [ActivityRun], needs: [NeedItem], finished: Int, at: Date
    ) -> Self {
        Self(
            working: activity.filter { $0.projectId == projectID && $0.chat != true }.count,
            needs: needs.filter { $0.projectId == projectID }.count,
            finished: finished,
            at: at
        )
    }
}
