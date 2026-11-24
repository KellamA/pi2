
import SwiftUI

/// The pairing screens (docs/design/iphone.md, "Pairing"): scan the code on the Mac, then the phone reaches the Mac,
/// shows six digits to type there, and says it is paired, or why not. Entered from the first screen's **Scan the code
/// on your Mac**, which `App/` places; `done` is called once paired, or when the person leaves.
struct PairingView: View {
    let flow: PairingFlow
    var camera: CameraState = .current
    var done: (PairingRecord?) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !isPaired {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                flow.scanAgain()
                                done(nil)
                            }
                        }
                    }
                }
        }
        #if DEBUG
        .task {
            // The simulator has no camera: a debug build takes the code from its launch value (`PI2_PAIR`).
            if let payload = PairingDebugLaunch.payload, flow.step == .scanning { flow.scanned(payload) }
        }
        #endif
    }

    private var isPaired: Bool {
        if case .paired = flow.step { true } else { false }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .scanning:
            PairingScanScreen(camera: camera) { flow.scanned($0) }
        case let .replace(current, new):
            PairingReplaceScreen(current: current, new: new, replace: { flow.replace() }, keep: { done(nil) })
        case let .reaching(mac):
            PairingReachingScreen(mac: mac)
        case let .digits(digits, mac, path):
            PairingDigitsScreen(digits: digits, mac: mac, path: path)
        case let .paired(mac):
            PairingDoneScreen(mac: mac) { done(flow.record) }
        case let .failed(failure):
            PairingFailedScreen(failure: failure, again: { flow.scanAgain() })
        }
    }
}

/// A screen of the pairing: a symbol, a title, what to do, and whatever else it holds, at any text size.
struct PairingPage<Extra: View>: View {
    let symbol: String
    var tint: Color = .accentColor
    let title: String
    let words: String
    /// What the screen holds comes before the words, not after: the digits, which must show without scrolling at
    /// any text size.
    var holdingFirst = false
    @ViewBuilder var extra: Extra

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                if holdingFirst { extra }
                Text(words)
                    .font(.body)
                    .foregroundStyle(.secondary)
                if !holdingFirst { extra }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }
}

struct PairingScanScreen: View {
    let camera: CameraState
    let found: @MainActor (String) -> Void
    @State private var state: CameraState?
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 260

    private var shown: CameraState { state ?? camera }

    var body: some View {
        PairingPage(symbol: "qrcode.viewfinder", title: "Scan the code on your Mac", words: "On your Mac, open pi² › Settings › Devices › Pair an iPhone. Hold this iPhone up to the code it shows.") {
            viewfinder
        }
        .task {
            if camera == .unknown { state = await CameraState.ask() }
        }
    }

    @ViewBuilder private var viewfinder: some View {
        switch shown {
        case .ready:
            CodeScanner(found: found)
                .frame(width: min(side, 320), height: min(side, 320))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.7), lineWidth: 2))
                .accessibilityLabel("Camera")
                .accessibilityHint("Point it at the pairing code on your Mac.")
        case .unknown:
            ProgressView()
                .frame(height: 80)
        case .denied:
            Notice(symbol: "camera.fill", text: "pi² can't use the camera. To scan the code, allow it in Settings › pi² › Camera.")
            if let settings = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settings)
                    .buttonStyle(.borderedProminent)
            }
        case .none:
            Notice(symbol: "camera", text: "This iPhone has no camera to scan with. (The simulator has none.)")
        }
    }
}

/// A line in a box, for what stands in the way.
private struct Notice: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct PairingReplaceScreen: View {
    let current: String
    let new: String
    let replace: () -> Void
    let keep: () -> Void

    var body: some View {
        PairingPage(symbol: "arrow.triangle.2.circlepath", tint: .orange, title: "Replace your pairing with \(new)?", words: "This iPhone is paired with \(current). It can be paired with one Mac at a time: replacing unpairs it from \(current) first.") {
            VStack(spacing: 12) {
                Button(role: .destructive, action: replace) {
                    Text("Replace with \(new)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: keep) {
                    Text("Keep \(current)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }
}

struct PairingReachingScreen: View {
    let mac: String

    var body: some View {
        PairingPage(symbol: "antenna.radiowaves.left.and.right", title: "Reaching \(mac)", words: "Through pi²'s relay, or straight to your Mac if this iPhone is on its network. Keep the code showing on your Mac.") {
            ProgressView()
                .controlSize(.large)
                .padding(.top, 8)
        }
    }
}

struct PairingDigitsScreen: View {
    let digits: String
    let mac: String
    let path: AppSession.Path

    var body: some View {
        PairingPage(symbol: "keyboard", title: "Type these digits on your Mac", words: "\(mac) is waiting for them under the code, in pi² › Settings › Devices. It pairs only if they match.", holdingFirst: true) {
            Text(spaced)
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.vertical, 18)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel(digits.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("pairing-digits")
            Label(pathWords, systemImage: path == .relay ? "cloud" : path == .home ? "house" : "network")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var pathWords: String {
        switch path {
        case .relay: "Through pi²'s relay"
        case .home: "On your home network"
        case .direct: "Straight to your Mac"
        }
    }

    private var spaced: String {
        guard digits.count == 6 else { return digits }
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }
}

struct PairingDoneScreen: View {
    let mac: String
    let next: () -> Void

    var body: some View {
        PairingPage(symbol: "checkmark.circle.fill", tint: .green, title: "Paired with \(mac)", words: "This iPhone can now reach \(mac) from any network. Next, pi² asks to send you notifications and to use Face ID, which opens pi² so that only you can answer for your Mac.") {
            Button(action: next) {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

struct PairingFailedScreen: View {
    let failure: PairingFailure
    let again: () -> Void

    var body: some View {
        PairingPage(symbol: "exclamationmark.triangle.fill", tint: .orange, title: failure.title, words: failure.words) {
            Button(action: again) {
                Text("Scan again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

#Preview("Digits") {
    PairingDigitsScreen(digits: "482913", mac: "Alex's MacBook Pro", path: .relay)
}
