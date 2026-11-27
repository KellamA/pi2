#if os(macOS) && PI2_DEVELOPMENT
import AppKit
import WebKit

/// Pressing a control of the conversation page by its label, for a throwaway test copy (#1023). WebKit gives none of the
/// page's buttons to accessibility, and a parked copy ignores a click at a point, so `scripts/test-copy press` asks the
/// copy, over its window control folder (`TestCopyControl`), to press one, as a click would.
///
/// It is compiled only into a development build, and the app asks it only of a copy `scripts/test-copy` made. It is not a
/// way to run script: the request is a label, and the label of the card or group the control is in, and nothing else.
/// One fixed script, `Self.script`, takes them as arguments, in the view's main frame and in a content world of its own,
/// which the page's scripts can neither see nor call. It looks only among the page's own buttons and button-like roles
/// (no links, no fields), refuses a label that names none, or several, or a hidden or disabled one, with words saying
/// which, and refuses the controls that answer for the person. A presented page is not in the transcript page at all:
/// it is drawn in a view of its own (`PresentedPageView`), which this never looks in.
///
/// Answers for the person stay with `scripts/test-copy answer`, which the copy's engine checks against its key: while a
/// press runs, and for 300 ms after, the view passes on only the page's messages in `mayFollow` and drops the rest
/// (`TranscriptWebKitView.received`). That covers what the pressed control's handler posts at once; the page's own scripts
/// post only at once, and a model's text cannot add a handler, so nothing else gets through.
@MainActor
public enum TranscriptPress {
    /// The content world the press runs in: the page's own scripts are in `.page` and cannot reach it.
    static let world = WKContentWorld.world(name: "pi2-test-copy-press")

    /// What the page may ask of the app because of a press: what stays inside the copy and the engine does not keep for
    /// the person. Everything else the page posts during a press is dropped: `decide`, `answer`, `answerNeed`, `choose`
    /// and `undo`, which the engine takes only from the app because they answer for the person or undo what they set,
    /// and `openLink`, which would open the person's browser, and `openDocument`, which would open a file in another
    /// app. A new kind is added here when a test needs it, in review.
    static let mayFollow: Set<String> = [
        "ready", "older", "copy", "openChat", "fork", "retry", "edit", "version", "image", "output", "save", "savePicture",
        "saveDocument", "showFile", "fileMenu", "presentedImage", "expand",
    ]

    /// How long after the press's script returns the view still filters what the page posts: the page posts at once in
    /// a click's handler, but a handler could post in its next frame.
    static let settle: Duration = .milliseconds(300)

    /// Labels and the card's label are one line of text, as an accessible label is.
    static let longestLabel = 300

    /// The fixed script. `label` and `within` are its arguments, as strings (`within` may be null); it returns
    /// `{ pressed, within }` or `{ refused }`. An accessible label is `aria-labelledby`'s text, else `aria-label`, else
    /// the control's text, else its `title`; a control is also found by its text alone, so Expand is found by "Expand"
    /// as well as by its label “Expand “title””. `within` is the label of an element the control is inside, such as a
    /// card (a presented card is labelled with its title).
    static let script = """
        const norm = (s) => String(s ?? "").replace(/\\s+/g, " ").trim();
        const wanted = norm(label);
        const scope = within === null || within === undefined ? null : norm(within);
        const quote = (s) => "\\u201c" + s + "\\u201d";
        const controls = 'button, [role="button"], [role="tab"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="switch"], [role="checkbox"], [role="option"], summary';
        const named = (el) => {
            const by = el.getAttribute("aria-labelledby");
            if (by) {
                const text = norm(by.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((e) => e.textContent).join(" "));
                if (text) return text;
            }
            return norm(el.getAttribute("aria-label")) || norm(el.textContent) || norm(el.getAttribute("title"));
        };
        const groups = (el) => {
            const names = [];
            for (let p = el.parentElement; p; p = p.parentElement) {
                const n = norm(p.getAttribute("aria-label"));
                if (n) names.push(n);
            }
            return names;
        };
        const shown = (el) => {
            if (!el.isConnected || el.getClientRects().length === 0) return false;
            if (el.closest('[hidden], [inert], [aria-hidden="true"]')) return false;
            const style = getComputedStyle(el);
            return style.visibility !== "hidden" && style.display !== "none";
        };
        const disabled = (el) => el.disabled === true || el.getAttribute("aria-disabled") === "true" || !!el.closest("fieldset[disabled]");
        // The page's controls that answer for the person, or undo what they set: an approval's, a question's, a need's
        // and a presented question's buttons and the field for words, and Undo. The engine takes those only from the
        // app, and a test answers them with scripts/test-copy answer.
        const answers = (el) => !!el.closest(".card-buttons, .card-answer, .present-ask, .undo-button");
        if (wanted === "") return { refused: "a label is needed" };
        const all = [...document.querySelectorAll(controls)];
        const found = all.filter((el) => named(el) === wanted || norm(el.textContent) === wanted);
        const inScope = scope === null ? found : found.filter((el) => groups(el).includes(scope));
        const live = inScope.filter(shown);
        if (live.length === 0) {
            const why = [];
            if (inScope.length > 0) why.push(`${inScope.length === 1 ? "one is" : inScope.length + " are"} on the page but not shown`);
            if (scope !== null && found.length > inScope.length) why.push(`${found.length - inScope.length} ${found.length - inScope.length === 1 ? "is" : "are"} outside ${quote(scope)}`);
            if (scope !== null && !all.some((el) => groups(el).includes(scope))) why.push(`no card or group is labelled ${quote(scope)}`);
            // The shown controls' labels that hold the label, or failing that one of its words.
            const labels = [...new Set(all.filter(shown).map(named).filter(Boolean))];
            const holds = (words) => labels.filter((n) => words.some((w) => n.toLowerCase().includes(w)));
            const whole = holds([wanted.toLowerCase()]);
            const near = (whole.length ? whole : holds(wanted.toLowerCase().split(" ").filter((w) => w.length >= 3))).slice(0, 8);
            if (near.length > 0) why.push(`labels that come near it: ${near.map(quote).join(", ")}`);
            return { refused: `no control labelled ${quote(wanted)}${scope === null ? "" : " in " + quote(scope)} is shown on the page` + (why.length ? `; ${why.join("; ")}` : "") };
        }
        if (live.length > 1) {
            const places = live.map((el) => groups(el)[0] ?? "the page itself");
            const distinct = [...new Set(places)];
            const where = distinct.map((p) => (p === "the page itself" ? p : quote(p))).join(", ");
            const how = distinct.length === live.length
                ? "name the one to press with --within and the label of its card"
                : "some are in the same card, so give the control's own label, or press it with the computer tool";
            return { refused: `${live.length} controls labelled ${quote(wanted)} are shown on the page, in ${where}; ${how}` };
        }
        const el = live[0];
        if (disabled(el)) return { refused: `${quote(named(el))} is disabled` };
        if (answers(el)) return { refused: `${quote(named(el))} answers for the person or undoes what they set, which a press never does; answer it with scripts/test-copy answer` };
        el.click();
        return { pressed: named(el), within: groups(el)[0] ?? null };
        """

    /// What a press did: the control's label and the card or group it is in, or why nothing was pressed; and the kinds
    /// of message the page posted because of it that were dropped.
    public struct Outcome: Sendable {
        public let pressed: String?
        public let within: String?
        public let refused: String?
        public let dropped: [String]
    }

    /// Presses the control labelled `label` (inside the element labelled `within`, if given) on the page `view` shows.
    public static func press(_ label: String, within: String?, in view: TranscriptWebKitView) async -> Outcome {
        func refusal(_ words: String) -> Outcome { Outcome(pressed: nil, within: nil, refused: words, dropped: []) }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return refusal("a label is needed") }
        guard label.count <= longestLabel, (within?.count ?? 0) <= longestLabel else { return refusal("a label is at most \(longestLabel) characters") }
        guard !label.contains(where: \.isNewline), within?.contains(where: \.isNewline) != true else { return refusal("a label is one line") }
        guard view.isReady else { return refusal("the page has not loaded yet") }
        view.beginPress()
        let answer: Any?
        do {
            answer = try await view.callAsyncJavaScript(script, arguments: ["label": label, "within": within ?? NSNull()], in: nil, contentWorld: world)
        } catch {
            _ = await view.endPress(after: settle)
            return refusal("the page did not answer: \(error.localizedDescription)")
        }
        let dropped = await view.endPress(after: settle)
        let result = answer as? [String: Any] ?? [:]
        if let refused = result["refused"] as? String { return Outcome(pressed: nil, within: nil, refused: refused, dropped: dropped) }
        guard let pressed = result["pressed"] as? String else { return refusal("the page gave no answer") }
        return Outcome(pressed: pressed, within: result["within"] as? String, refused: nil, dropped: dropped)
    }
}
#endif
