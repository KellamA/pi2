import SwiftUI
import UIKit

/// pi²'s share extension (docs/iphone.md 12.2, P33): a link, text, a photo or a file shared from another app becomes a
/// message to a project's orchestrator, an agent or a chat on the Mac. It has no connection of its own: Send writes
/// the message as a draft into the folder it shares with the app (`ShareDrop`), and the app sends it (`SharePickup`).
/// Everything but this entry is in `Shared/`, built into the app too, where its tests reach it (docs/iphone-app.md,
/// "The extensions").
final class ShareViewController: UIViewController {
    private lazy var model = ShareModel(drop: ShareDrop.inAppGroup())

    override func viewDidLoad() {
        super.viewDidLoad()
        let page = UIHostingController(rootView: SharePage(model: model) { [weak self] sent in
            guard let context = self?.extensionContext else { return }
            if sent {
                context.completeRequest(returningItems: [], completionHandler: nil)
            } else {
                context.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            }
        })
        addChild(page)
        page.view.frame = view.bounds
        page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(page.view)
        page.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.load(items) }
    }
}
