import SwiftUI
import UIKit

/// The lock screen: what pi² shows on a paired phone while no session is open (docs/iphone.md 4.5; the design's "A
/// stolen or unlocked phone"). `App/` places it with `.presenceGate(session)` rather than by name.
struct PresenceLockScreen: View {
    let session: PresenceSession

    var body: some View {
        PresenceLockContent(state: session.state, lastEnd: session.lastEnd) {
            Task { await session.open() }
        }
    }
}

/// The lock screen for one state, without a session: the gate draws it with the live one, the debug build with a
/// state of its choosing, for a picture.
struct PresenceLockContent: View {
    let state: PresenceSession.State
    var lastEnd: PresenceSession.EndReason?
    let open: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 56
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let words = PresenceLockWords(state: state, lastEnd: lastEnd)
        // The words scroll; the buttons stay at the bottom, so that at the largest text the way on is in view.
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: typeSize.isAccessibilitySize ? 12 : 40)
                Image(systemName: words.symbol)
                    .font(.system(size: min(symbolSize, 80), weight: .regular))
                    .foregroundStyle(words.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text(words.title)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(words.text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                if state == .opening {
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel("Asking Face ID")
                }
                Spacer(minLength: 12)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if words.button != nil || words.offersSettings {
                VStack(spacing: 10) {
                    if let button = words.button {
                        Button(action: open) {
                            Label(button, systemImage: "faceid")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if words.offersSettings {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } label: {
                            Text("Open Settings")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }
}

/// The lock screen's words for each state. The design gives the rule ("Face ID opens pi² on the phone, with no
/// passcode instead"; "pi² closes itself a minute after the person leaves it, when the phone locks"; a person whose
/// Face ID fails "cannot use pi² on the phone until it works again; the Mac is unaffected"; a new Face ID key is
/// accepted on the Mac); these say it for each case.
struct PresenceLockWords: Equatable {
    var symbol: String
    var title: String
    var text: String
    /// The main button's label, if the state has one; it asks Face ID.
    var button: String?
    var offersSettings = false
    var isProblem = false

    init(state: PresenceSession.State, lastEnd: PresenceSession.EndReason? = nil) {
        switch state {
        case .locked:
            symbol = "lock.fill"
            title = "pi² is locked"
            text = switch lastEnd {
            case .awayTooLong: "It locked after a minute away. Face ID opens it, not your passcode."
            case .phoneLocked: "It locked with your iPhone. Face ID opens it, not your passcode."
            case .lockButton: "You locked it. Face ID opens it, not your passcode."
            case .revoked, nil: "Face ID opens it, not your passcode. It locks again a minute after you leave it, and when your iPhone locks."
            }
            button = "Open with Face ID"
        case .opening:
            symbol = "faceid"
            title = "Opening pi²"
            text = "Look at your iPhone."
            button = nil
        case .open:
            symbol = "lock.open.fill"
            title = "pi² is open"
            text = "Nothing more is asked until it locks."
            button = nil
        case .failed(let failure):
            isProblem = true
            switch failure {
            case .notRecognised:
                symbol = "faceid"
                title = "Face ID did not recognise you"
                text = "pi² opens only with Face ID, never with the passcode, so that someone who saw your passcode cannot open it."
                button = "Try Face ID again"
            case .noFaceID:
                symbol = "faceid"
                title = "Set up Face ID"
                text = "pi² opens only with Face ID. Set it up in Settings › Face ID & Passcode, then come back. Until then this iPhone shows pi²'s notifications and nothing else; your Mac is unaffected."
                button = "Try again"
                offersSettings = true
            case .faceIDLockedOut:
                symbol = "lock.trianglebadge.exclamationmark.fill"
                title = "Face ID is locked"
                text = "After too many tries, iOS keeps Face ID off until your passcode is entered. Lock your iPhone, unlock it with the passcode, then open pi² again. Your Mac is unaffected."
                button = "Try again"
            case .faceIDNotAllowed:
                symbol = "faceid"
                title = "Allow Face ID for pi²"
                text = "pi² opens only with Face ID. Turn it on for pi² in Settings › pi² › Face ID, then come back."
                button = "Try again"
                offersSettings = true
            case .noBiometrics:
                symbol = "exclamationmark.lock.fill"
                title = "This iPhone has no Face ID"
                text = "pi² opens only with Face ID or Touch ID, so it cannot be used on this iPhone. Your Mac is unaffected."
                button = nil
            case .noPasscode:
                symbol = "exclamationmark.lock.fill"
                title = "Set a passcode"
                text = "pi² keeps its keys only on an iPhone with a passcode. Set one in Settings › Face ID & Passcode, then pair this iPhone with your Mac again."
                button = nil
                offersSettings = true
            case .faceIDSetUpAgain:
                symbol = "person.badge.key.fill"
                title = "Face ID was set up again"
                text = "So pi² made a new Face ID key for this iPhone. Your Mac uses it once you accept it there, in pi² › Settings › Devices. Accept it only if you set up Face ID yourself."
                button = "Open with Face ID"
            case .keysGone:
                symbol = "key.slash.fill"
                title = "This iPhone's keys are gone"
                text = "They are deleted when the passcode is turned off. Pair this iPhone again: on your Mac, pi² › Settings › Devices › Pair an iPhone."
                button = nil
            case .other(let code):
                symbol = "exclamationmark.triangle.fill"
                title = "pi² could not ask Face ID"
                text = "Face ID answered with error \(code). Try again; if it keeps failing, restart your iPhone."
                button = "Try again"
            }
        }
    }
}

/// A button that ends the session at once, for a screen to place where the person can find it (the person's Lock, which ends the session as leaving pi² for a minute does).
struct PresenceLockButton: View {
    let session: PresenceSession

    var body: some View {
        Button {
            session.end(.lockButton)
        } label: {
            Label("Lock pi²", systemImage: "lock.fill")
        }
        .accessibilityHint("Closes pi² on this iPhone until Face ID opens it again.")
    }
}
