import SwiftUI
import UIKit

/// pi²'s share extension (docs/iphone.md 12.2, P33), an empty shell for now: pi² in the share sheet shows a page saying
/// it is not built yet, and Done completes the request having sent nothing. #702 fills it: sending a link, text, a photo
/// or a file to an orchestrator or an agent. What it shares with the app goes in `Shared/`, which is built into both;
/// how the extensions are put together is "The extensions" in docs/iphone-app.md.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let page = UIHostingController(rootView: SharePlaceholder { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        })
        addChild(page)
        page.view.frame = view.bounds
        page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(page.view)
        page.didMove(toParent: self)
    }
}

/// Says sharing to pi² is not built yet. #702 replaces it with its own.
struct SharePlaceholder: View {
    let done: () -> Void

    var body: some View {
        NavigationStack {
            Text("Sharing to pi² is not built yet (#702). Nothing was sent.")
                .multilineTextAlignment(.center)
                .padding()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: done)
                    }
                }
                .navigationTitle("pi²")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
