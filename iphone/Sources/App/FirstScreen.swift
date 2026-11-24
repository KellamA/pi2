import SwiftUI

/// The screen a phone not yet paired with a Mac opens on (docs/design/iphone.md, "Pairing"; the drafts' figure 2):
/// what pi² for iPhone is, **Scan the code on your Mac**, which opens the pairing screens, **Try it without a Mac**,
/// and the build's version. After a pairing ended on this launch it says how, and lists what the Outbox had not sent.
struct FirstScreen: View {
    @Environment(PhoneLink.self) private var link: PhoneLink?
    @State private var flow: PairingFlow?
    #if DEBUG
    /// `PI2_SHOW=face-id-check` in a debug build's environment opens the check at launch, so that a picture of it can
    /// be taken in the simulator without a tap (`SIMCTL_CHILD_PI2_SHOW` with `xcrun simctl launch`).
    @State private var showsCheck = ProcessInfo.processInfo.environment["PI2_SHOW"] == "face-id-check"
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        Mark()
                        Text("pi² on your iPhone")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Your Mac does the work. This iPhone shows it, and answers for you when agents need you.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    if let ended = link?.ended {
                        EndedNotice(ending: ended, unsent: link?.unsent ?? [])
                    }

                    VStack(spacing: 12) {
                        Text("Pair with your Mac")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Text("On your Mac, open pi² › Settings › Devices › Pair an iPhone, then scan the code it shows.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let link {
                            Button {
                                flow = link.pairingFlow()
                            } label: {
                                Label("Scan the code on your Mac", systemImage: "qrcode.viewfinder")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14))

                    DemoEntry()
                        .environment(\.placement, .inline)

                    #if DEBUG
                    DebugSection(showsCheck: $showsCheck)
                    #endif

                    Text(BuildInfo.line)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            #if DEBUG
            .navigationDestination(isPresented: $showsCheck) {
                FaceIDCheckScreen()
            }
            #endif
        }
        .sheet(isPresented: Binding(get: { flow != nil }, set: { if !$0 { flow = nil } })) {
            if let flow, let link {
                PairingSheet(flow: flow) { record in
                    self.flow = nil
                    if let record { link.didPair(record) }
                }
                .interactiveDismissDisabled()
            }
        }
        #if DEBUG
        .task {
            // The simulator has no camera: with a code in `PI2_PAIR`, pairing opens at launch, once, and takes it as
            // scanned. Not again when the first screen comes back, after the Mac unpaired this phone.
            guard PairingDebugLaunch.payload != nil, !FirstScreenDebug.pairedFromLaunch, flow == nil, let link else { return }
            FirstScreenDebug.pairedFromLaunch = true
            flow = link.pairingFlow()
        }
        #endif
    }
}

#if DEBUG
@MainActor
private enum FirstScreenDebug {
    static var pairedFromLaunch = false
}
#endif

/// The pairing screens in the first screen's sheet. A debug build given its code in `PI2_PAIR` goes on by itself a few
/// seconds after "Paired", as **Continue** does, so that the simulator, which cannot be tapped, reaches the projects.
private struct PairingSheet: View {
    let flow: PairingFlow
    let done: (PairingRecord?) -> Void

    var body: some View {
        PairingView(flow: flow, done: done)
            #if DEBUG
            .task(id: flow.step) {
                guard PairingDebugLaunch.payload != nil, case .paired = flow.step else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled, case .paired = flow.step { done(flow.record) }
            }
            #endif
    }
}

/// How the last pairing ended, on this launch, and what the Outbox had not sent (docs/iphone.md 3.6: a revocation never
/// deletes the Outbox without first showing what in it was not sent). It is gone from the phone; this is the last look.
private struct EndedNotice: View {
    let ending: PhoneLink.Ending
    let unsent: [OutboxItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: ending == .revoked ? "iphone.slash" : "link.badge.plus")
                .font(.headline)
            Text(words)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !unsent.isEmpty {
                Text(unsent.count == 1 ? "Not sent to your Mac, and no longer kept:" : "Not sent to your Mac (\(unsent.count)), and no longer kept:")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                ForEach(unsent, id: \.id) { item in
                    Text(item.summary)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.55)))
    }

    private var title: String {
        switch ending {
        case .revoked: "Your Mac unpaired this iPhone"
        case .unpaired: "This iPhone is unpaired"
        case .keysGone: "This iPhone's keys are gone"
        }
    }

    private var words: String {
        switch ending {
        case .revoked: "It was revoked on the Mac, in pi² › Settings › Devices, so everything pi² kept here was deleted. To use it again, pair it again."
        case .unpaired: "Its keys and everything pi² kept here were deleted."
        case .keysGone: "They are deleted when the passcode is turned off, so this iPhone can no longer reach your Mac. Pair it again."
        }
    }
}

/// pi²'s mark, as the Mac app's icon draws it. Decoration: VoiceOver reads the title beside it.
private struct Mark: View {
    @ScaledMetric(relativeTo: .title) private var side: CGFloat = 64

    var body: some View {
        Text("π²")
            .font(.system(size: side * 0.47, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(Color(red: 0.545, green: 0.576, blue: 1.0), in: RoundedRectangle(cornerRadius: side * 0.28))
            .accessibilityHidden(true)
    }
}

#if DEBUG
/// What only a debug build shows: where its keys will be made (docs/iphone.md section 10) and the check of 4.3 for
/// the owner's phone. None of it is compiled into a release build.
private struct DebugSection: View {
    @Binding var showsCheck: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("Debug build")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if !KeyPlace.secureEnclave {
                Text("No Secure Enclave here (the simulator has none): this build makes its keys in software.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button("Check Face ID signing") {
                showsCheck = true
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Signs twenty times under one Face ID, on this phone, and keeps nothing.")
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}
#endif

#Preview("First screen") {
    FirstScreen()
}
