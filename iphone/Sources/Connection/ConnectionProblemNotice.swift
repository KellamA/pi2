
import SwiftUI

/// What stopped the connection, or what the relay said, as a card a screen can place under the connection bar
/// (`RemoteConnection.problem`), with **Try again** where the person's word is what it waits for.
struct ConnectionProblemNotice: View {
    let problem: ConnectionProblem
    var tryAgain: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(problem.title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(problem.words)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let tryAgain, waitsForThePerson {
                Button("Try again", action: tryAgain)
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.55)))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch problem {
        case .update: "arrow.down.app"
        case .suspended: "pause.circle"
        case .presence, .faceID: "faceid"
        case .clock: "clock.badge.exclamationmark"
        case .macNotProved: "exclamationmark.shield"
        case .presenceKeyWaits, .presenceKeyNotTaken: "person.badge.key"
        case .relaySaid: "cloud"
        }
    }

    /// Whether trying again is the person's to ask: after the refusals that stop the phone trying by itself.
    private var waitsForThePerson: Bool {
        switch problem {
        case .clock, .suspended, .presence, .faceID(.faceIDNotPassed), .presenceKeyWaits, .presenceKeyNotTaken: true
        default: false
        }
    }
}
