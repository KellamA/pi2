#if DEBUG
import SwiftUI
import UIKit

/// The debug screen that runs FaceIDCheck on the owner's phone and shows its result as one line to send back.
struct FaceIDCheckScreen: View {
    @State private var running = false
    @State private var report: FaceIDCheck.Report?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("This makes a key in the Secure Enclave that only Face ID can use, asks Face ID once, signs \(FaceIDCheck.signatures) different messages under that one Face ID, then ends the Face ID and tries once more. It keeps nothing.")
                    .foregroundStyle(.secondary)

                if KeyPlace.secureEnclave {
                    Button {
                        running = true
                        report = nil
                        Task {
                            let result = await FaceIDCheck.run()
                            report = result
                            running = false
                        }
                    } label: {
                        Text(report == nil ? "Run the check" : "Run it again")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(running)
                } else {
                    Text("This check cannot run here: there is no Secure Enclave, as in the simulator. Run this debug build on an iPhone with Face ID.")
                        .font(.headline)
                }

                if running {
                    ProgressView("Checking…")
                }

                if let report {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Send back this line:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(report.line)
                            .font(.title3.monospaced())
                            .textSelection(.enabled)
                        Button("Copy the line") {
                            UIPasteboard.general.string = report.line
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))

                    if !report.details.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Each step")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(Array(report.details.enumerated()), id: \.offset) { _, detail in
                                Text(detail)
                                    .font(.footnote)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Check Face ID signing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
