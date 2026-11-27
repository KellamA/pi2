// A test copy's press (#1023; TranscriptKit's TranscriptPress, `scripts/test-copy press`): a control of the page found by
// its label, among the page's own controls, and activated as a click would, in the mockups' conversation of present
// cards (Presenting.swift). An absent label, an ambiguous one and one that answers for the person are refused, with
// words saying which; and while a press is in flight the view passes on only what a press may set off, whatever the
// page posts. Only a development build has any of it, as this check is.
// TranscriptPress exists only in a development build; this target has no PI2_DEVELOPMENT of its own.
#if DEBUG
import AppKit
import TranscriptKit

@MainActor
func pressing(folder: URL) async {
    await group("a test copy's press finds a control of the page by its label, presses it as a click would, and refuses what it cannot tell or must not press") {
        let page = PresentingPage(folder: folder, layout: .wide, width: wideWidth, appearance: .darkAqua, zoom: 1)
        defer { page.close() }
        guard await page.load() else { return }
        @MainActor func posts() -> [String] { page.posted.filter { $0["type"] as? String != "presentedImage" }.map { m in m.keys.sorted().map { "\($0)=\(m[$0]!)" }.joined(separator: " ") } }
        func settled() async { try? await Task.sleep(for: .milliseconds(300)) }

        page.posted.removeAll()
        let several = await TranscriptPress.press("Expand", within: nil, in: page.view)
        check("Expand alone names three cards' buttons, so it is refused, saying where they are",
              several.pressed == nil && several.refused?.hasPrefix("3 controls labelled “Expand” are shown on the page, in “Settings › General, as it is now”, “Sign-in screen, three layouts”") == true
              && several.refused?.contains("some are in the same card") == true, several.refused ?? "pressed \(several.pressed ?? "")")
        await settled()
        check("and nothing was pressed", posts().isEmpty, posts().joined(separator: "\n      "))

        let byLabel = await TranscriptPress.press("Expand “Settings › General, as it is now”", within: nil, in: page.view)
        check("its own label names one", byLabel.pressed == "Expand “Settings › General, as it is now”" && byLabel.within == "Settings › General, as it is now" && byLabel.refused == nil,
              "\(byLabel)")
        await settled()
        check("which posts expand as a click does", posts() == ["item=0 presentation=p1 type=expand version=1"], posts().joined(separator: "\n      "))

        page.posted.removeAll()
        let inCard = await TranscriptPress.press("Expand", within: "Settings › General, as it is now", in: page.view)
        check("Expand within the card's title names it too", inCard.pressed == "Expand “Settings › General, as it is now”" && inCard.refused == nil, "\(inCard)")
        await settled()
        check("and posts the same", posts() == ["item=0 presentation=p1 type=expand version=1"], posts().joined(separator: "\n      "))

        page.posted.removeAll()
        let same = await TranscriptPress.press("Expand", within: "Sign-in screen, three layouts", in: page.view)
        check("two cards of one title cannot be told apart by it, and are refused", same.pressed == nil && same.refused?.hasPrefix("2 controls labelled “Expand”") == true, same.refused ?? "pressed")

        let absent = await TranscriptPress.press("Expand everything", within: nil, in: page.view)
        check("a label no control has is refused, with the labels that come near it",
              absent.pressed == nil && absent.refused?.hasPrefix("no control labelled “Expand everything” is shown on the page") == true
              && absent.refused?.contains("labels that come near it: “Expand “Settings › General, as it is now””") == true, absent.refused ?? "pressed")
        let elsewhere = await TranscriptPress.press("Expand", within: "No such card", in: page.view)
        check("so is a card no element is labelled with, saying so",
              elsewhere.refused?.contains("no card or group is labelled “No such card”") == true, elsewhere.refused ?? "pressed")

        let answer = await TranscriptPress.press("Use B", within: nil, in: page.view)
        check("a choice of a question answers for the person, and is refused, pointing to test-copy answer",
              answer.pressed == nil && answer.refused?.contains("answers for the person") == true && answer.refused?.contains("scripts/test-copy answer") == true, answer.refused ?? "pressed")
        await settled()
        let open = await js(page.view, "[...document.querySelectorAll('.card.present')[2].querySelectorAll('.card-buttons button')].every((b) => !b.disabled)") as? Bool
        check("nothing was posted, and the question still waits", posts().isEmpty && open == true, posts().joined(separator: "\n      "))

        // Whatever a pressed control's handler posts, only what a press may set off goes on: here a button of the page's
        // own whose handler decides, opens a link, opens a document, expands, and undoes a moment later.
        _ = await js(page.view, """
            (() => { const b = document.createElement('button'); b.textContent = 'Posts everything';
              b.addEventListener('click', () => { const h = window.webkit.messageHandlers.pi2;
                h.postMessage({ type: 'decide', inbox: 'a1', decision: 'once' });
                h.postMessage({ type: 'openLink', url: 'https://example.com/' });
                h.postMessage({ type: 'openDocument', path: '/tmp/no-such-file.pdf' });
                setTimeout(() => h.postMessage({ type: 'undo', change: 3 }), 50);
                h.postMessage({ type: 'expand', presentation: 'p1', version: 1, item: 0 }); });
              document.getElementById('transcript').appendChild(b); return true; })()
            """)
        page.posted.removeAll()
        let mixed = await TranscriptPress.press("Posts everything", within: nil, in: page.view)
        check("a press passes on only what it may set off, and says what it dropped",
              mixed.pressed == "Posts everything" && mixed.dropped == ["decide", "openLink", "openDocument", "undo"], "\(mixed)")
        check("so the app hears only expand", posts() == ["item=0 presentation=p1 type=expand version=1"], posts().joined(separator: "\n      "))
        // Once the press is over, the page's messages go on as before.
        page.posted.removeAll()
        _ = await js(page.view, "document.querySelectorAll('.card.present')[0].querySelector('.expand').click()")
        _ = await until("a click after the press is heard", { !posts().isEmpty })

        let hidden = await js(page.view, "(() => { const b = document.createElement('button'); b.textContent = 'Not shown'; b.hidden = true; document.getElementById('transcript').appendChild(b); return true; })()")
        let unseen = await TranscriptPress.press("Not shown", within: nil, in: page.view)
        check("a hidden control is not pressed", hidden as? Bool == true && unseen.refused?.contains("one is on the page but not shown") == true, unseen.refused ?? "pressed")
        _ = await js(page.view, "(() => { const b = document.createElement('button'); b.textContent = 'Switched off'; b.disabled = true; document.getElementById('transcript').appendChild(b); return true; })()")
        let off = await TranscriptPress.press("Switched off", within: nil, in: page.view)
        check("nor a disabled one", off.refused == "“Switched off” is disabled", off.refused ?? "pressed")
        let script = await TranscriptPress.press("Expand\nwindow.close()", within: nil, in: page.view)
        check("a label is one line of text", script.refused == "a label is one line", script.refused ?? "pressed")
    }
}
#endif
