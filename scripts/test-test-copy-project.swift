import Foundation

@main
struct CheckProjectCopyView {
    static func main() throws {
        let launch = try ProjectCopyView(show: "project:Demo project#now", hub: "conversation-folded")
        precondition(ProjectCopyView.launch == launch)
        precondition(launch.project == "Demo project" && launch.tab == .now && launch.hub == .conversationFolded)
        for tab in ["now", "work", "agents", "rules", "notes", "branches", "settings"] {
            let view = try ProjectCopyView(show: "project:p-123#\(tab)", hub: "both")
            precondition(view.project == "p-123" && view.tab?.rawValue == tab && view.hub == .both && view.agent == nil)
        }
        let project = try ProjectCopyView(show: "project:Demo project", hub: nil)
        precondition(project.project == "Demo project" && project.hub == nil && project.tab == nil)
        let agent = try ProjectCopyView(show: "project:p-123#agent:Sample Agent", hub: "board-folded")
        precondition(agent.agent == "Sample Agent" && agent.hub == .boardFolded && agent.tab == nil)
        let dashboard = try ProjectCopyView(show: "dashboard", hub: nil)
        precondition(dashboard.show == "dashboard" && dashboard.project == nil)
        let page = try ProjectCopyView(show: "activity", hub: nil)
        precondition(page.show == nil)
        for value in ["project:", "project: #now", "project:p-123#", "project:p-123#bogus", "project:p-123#agent:"] {
            precondition((try? ProjectCopyView(show: value, hub: nil)) == nil)
        }
        precondition((try? ProjectCopyView(show: "project:p-123", hub: "invalid")) == nil)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as? [String: String]
        precondition(wire == ["show": "project:p-123#agent:Sample Agent", "project": "p-123", "agent": "Sample Agent", "hub": "board-folded"])
        print("ok: app reads PI2_SHOW and PI2_HUB and encodes a parsed project view")
    }
}
