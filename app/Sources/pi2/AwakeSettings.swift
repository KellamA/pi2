import SwiftUI

/// Settings › General › Power: keeping this Mac awake while agents work (#561). The engine keeps the switch and sends it
/// as its `awake` event (engine/src/keepawake.ts); it holds a "no idle sleep" assertion while any conversation is working
/// or waiting for a limit or the network to carry on by itself, and lets it go a minute after the last one stops.
struct AwakeSettings: View {
    let engine: EngineClient
    @State private var problem: String?

    private var event: JSONValue? { engine.extras["awake"] }
    /// On until the engine says otherwise, as it starts.
    private var keep: Bool {
        if case .bool(let on)? = event?["keep"] { return on }
        return true
    }
    /// Off until the engine says otherwise, as it starts.
    private var battery: Bool {
        if case .bool(let on)? = event?["battery"] { return on }
        return false
    }

    var body: some View {
        Section {
            Toggle("Keep this Mac awake while agents are working", isOn: Binding(
                get: { keep },
                set: { on in change(keep: on, battery: battery) }
            ))
            Toggle("Also on battery", isOn: Binding(
                get: { battery },
                set: { on in change(keep: keep, battery: on) }
            ))
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Theme.bad)
            }
        } header: {
            Text("Power")
        } footer: {
            // Two paragraphs, so the lid's limit and what agents cannot do with it are each easy to read.
            VStack(alignment: .leading, spacing: 8) {
                Text("While any conversation is working — or waiting for a provider’s limit or the network to carry on by itself — pi² stops this Mac going to sleep by itself. The display can still sleep, and the Mac is allowed to sleep again a minute after the last run ends. On battery, only with “Also on battery” on.").formFooter()
                Text("Closing the lid of a Mac with no display attached still puts it to sleep: no app can prevent that; an external display, or an administrator’s “sudo pmset disablesleep”, is what changes it. With the screen locked or the lid closed, agents cannot take pictures of windows or work other apps, so work that checks the screen needs the Mac open and unlocked.").formFooter()
            }
        }
    }

    private func change(keep: Bool, battery: Bool) {
        Task {
            do {
                _ = try await engine.call("settings.setAwake", ["keep": keep, "battery": battery])
                problem = nil
            } catch {
                self.problem = error.localizedDescription
            }
        }
    }
}
