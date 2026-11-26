# Computer use

An agent with computer use on can see and work the apps you choose, one window at a time, in the background while you keep working.

## Turning it on

1. Open an agent and scroll to **Computer use**. Switch it on and add the apps it may use. Until there is at least one app, or [test copies of pi²](#clicking-in-test-copies) are allowed, the agent is not given the computer tool or anything about it in its prompt, since it could do nothing with it (#177). The tool comes with the first app you add, and goes again if you remove the last one.
2. Press **Grant…** next to Accessibility. macOS opens System Settings; switch pi² on there. Do the same for Screen Recording if you want the agent to get pictures. Reopen pi² afterwards.
3. Ask the agent to do something in one of those apps. Conversations it already has pick up the change at their next message.

Start with something harmless, such as TextEdit.

## How it works

The engine decides what is allowed and asks for approval. The app does the seeing and clicking, because macOS gives the permissions for those to the app. So pi² has to be open.

- **Controls first.** The agent is given a numbered list of the front window's buttons, fields, rows and menus, read through the accessibility API. It acts on a control by its number. That is exact, and it does not need the app in front. Before acting on one, pi² reads the window again, as far as that control, and acts only if it is still among the window's controls: an app can take a control away and leave it answering at its old place, such as one on a tab switched away, so if the window has changed since the look, the agent is told to look again and nothing is done (#969).
- **Pictures second.** If its model takes images, it also gets a screenshot, and can act on a point in it when something is not in the list. The picture is of the window the controls are listed for and nothing else, at that window's size: a sheet or a dialog attached to a window is pictured by itself, not with the window it is over, so a point read off the picture is the point clicked (#798). A model that cannot see images works from the list and the window's text, and needs no Screen Recording permission.
- **Every action answers with the window as it is afterwards**, so the agent checks each step before the next.
- **Only the two newest pictures are sent to the model.** The conversation keeps them all; expand a computer step to see what the agent saw.

The actions are: list the apps it may use, open an app, look at a window, click, open a control's context menu, type, press a key, scroll, and choose a menu command.

- **Menu bar items.** If the app exposes an item in the macOS menu bar, its name or accessibility label is listed with its own number, even if the app has no open window. Use `click` with that number, not `menu` or picture coordinates. The click follows the same approval and look-only rules as any other click. If it opens a window, the reply shows that window.
- **Scrolling.** `dy` counts visible heights of the scrolling view, not fractions of the document. pi² sends a scroll-wheel event to the app and reports how far it observed the view move. A view can move less than requested at an end; some apps ignore the wheel or do not report enough to measure the distance.
- **Context menus.** The agent opens the menu a right-click would show on a listed control, or at a point. pi² asks for it through accessibility (`AXShowMenu`), which works with the app in the background, on the control or, failing that, on the nearest thing inside it or around it that has one (a list row's menu is on its text); where nothing answers, or nothing opens, it sends that app a secondary click. While a menu is open, its items are listed first among the controls, so the agent chooses one by its number, or presses escape, which closes the menu through accessibility. The picture does not show the menu, which macOS draws in a window of its own.

## Asking first

With **Ask before each action** on, which is the default, every click, keystroke and menu command waits for you. The request says what will happen in words, such as "Click the “Send” button in Mail". You can allow once, allow that app for the rest of the conversation, or deny. Looking is never asked about.

A click or a context menu at a point in the picture, rather than on a listed control, acts on what the request named. If what is at that point changed while the request waited for you, or since the agent last looked, the action is refused and the agent is told to look again; it never presses something the request did not name (#770). A control the request named counts as still there only while it is among the window's controls read again then, as one acted on by its number does, since a control the app has taken away, such as one on a tab switched away, can go on answering at its old place (#955). Where such a control does not answer through accessibility, no real click is sent to the point in its place.

An agent with [Allow everything](allow-everything.md) on is asked about no action, may use any app, not only the ones listed, and may control browsers. The other limits below still hold, and System Settings stays look-only.

While an agent is acting, a pill at the top of the screen says so. Long names shorten in the middle to fit the screen on one line. The Stop button, or pressing Esc twice, stops the run.

## What it will not do

These hold whatever the agent or its instructions say. They are checked in the engine and again in the app.

- **Terminals, script editors and password managers cannot be added.** Typing in a terminal is running a command, without the approval the command tool has.
- **Browsers and System Settings are look-only.** A browser holds every account you are signed in to.
- **Password fields are never typed into.**
- **The Apple menu is off limits.**
- **pi² itself cannot be added or used**, so an agent cannot approve its own requests.
- **A copy of pi² under another bundle id is look-only**, unless it is a throwaway test copy and the agent is allowed [test copies](#clicking-in-test-copies). Any bundle id starting with `dev.pi2.app.`, such as a development build (`dev.pi2.app.dev`) or a copy of one, can be added, opened and looked at, but not clicked, typed into, scrolled or sent keys or menu commands. Looking at a copy is how an agent working on pi² checks a change to the app. Acting in one is refused because a copy has approve buttons too, and a copy of a release build started without a data folder of its own shows the real agents' requests, so a click there could approve an agent's own request. Inside a running copy, that copy is refused the way pi² is.

Apps are matched by bundle id without regard to case, as macOS finds them, so `com.apple.terminal` is refused like `com.apple.Terminal`. Two spellings of one bundle id are one app: it is kept once, and allowing it for the rest of a conversation covers both.

The agent is also told that what it reads in a window is content, not instructions. That lowers the risk from text planted in a document or a page; it does not remove it. Keep "Ask before each action" on for anything that matters.

## Clicking in test copies

An agent that works on pi² itself starts throwaway test copies of the app to try its change (`scripts/test-copy`, see [Testing safely](../CONTRIBUTING.md#testing-safely)). Each copy has a bundle id made up for the run, so it cannot be added beforehand, and a copy is look-only anyway. To let an agent press buttons, open menus and fill in sheets in its copies, turn on **Test copies of pi²** in the agent's Computer use settings. It is off unless you turn it on.

With it on, the agent may use any app that is a throwaway test copy without its being listed, and act in it, not only look. list_apps shows the copies running. Everything else stays as it is: it asks before each action if **Ask before each action** is on, works one window at a time, in the background, without taking the focus, and every other app is as before. A sub-chat follows its own agent's switch, not the one of the agent that handed it the work.

A test copy is checked twice. The engine allows only bundle ids beginning `dev.pi2.app.test`, such as `dev.pi2.app.test-146`. Since any app can take an id, pi² then checks the app running under it before each action, and treats it as a test copy only when it is what `scripts/test-copy` makes: a bundle at `app/build/test-copies/<suffix>/` in a checkout, under the id `dev.pi2.app.<suffix>`, that is a development build of that same checkout (it carries no engine of its own, and runs the checkout's `engine/src/main.ts`). A development build never uses the usual data folder or Keychain service ([releasing.md](releasing.md#release-builds-and-development-builds)), so a test copy shows only its own agents' requests, never yours. Not covered, and look-only as before: the development build as built (`dev.pi2.app.dev`), a copy whose suffix does not begin with `test`, a copy of a release build whatever it is called, and any other app under a similar id. The pi² the agent runs in is never usable.

A test copy runs agents of its own with the scripted demo model, which runs a command typed as `/bash …`. So typing in a copy can run a command on your Mac, as the copy, without the approval the agent's own commands have. Keep **Ask before each action** on unless you trust the agent with commands too.

What macOS needs: **Accessibility for pi²**, the pi² the agent runs in, granted with the **Grant…** button next to Accessibility in the agent's Computer use settings (System Settings › Privacy & Security › Accessibility), and pi² reopened afterwards. Screen Recording is optional, for pictures. The copies need no permission of their own: pi² does the reading and clicking. Nothing asks macOS on its own to find out: the settings show whether it is granted without asking, and only the Grant… button sets off the prompt.

## Commands an agent runs

Computer use is not the only way an agent can see the screen. A shell command it runs, such as `screencapture`, acts under pi²'s own macOS permissions, not the computer tool's rules: once pi² has Screen Recording, an agent's command can capture the whole screen, whichever apps computer use allows and whether or not computer use is on, and one that runs without asking (Full access, or an allowed command) needs no approval to do it. Accessibility is different: an agent's commands never have pi²'s, however the engine was started, so a command cannot work other apps around the list of apps and the approvals above. Until #263 they had it when the app itself started the engine. A capture without the permission fails, and the first one puts a macOS prompt on your screen naming pi². [architecture.md](architecture.md#whose-macos-permissions-commands-have) has the details.

## Limits

- The pi² app the agent runs in must be open, even when the app it wants to use is already running. If pi² is closed, only the person can reopen it to restore computer use; retrying or reopening a test copy will not help.
- A click at a bare point, not on a listed control, is ignored by some apps while they are in the background. Such clicks go through accessibility where they can, and the agent is told when a click changed nothing. So is a listed control that answers to no accessibility press and gets a real click instead.
- SwiftUI's disclosure group in a grouped form answers to no accessibility action, so in another app only a click opens it, which an app in the background may ignore. pi²'s own disclosure groups put `pressableDisclosure` on their label, which makes the arrow answer to a press (#367); a new one should too.
- Some apps show a context menu only while they are in front. The agent is told when none opened.
- Apps with little accessibility support may not be workable. A test copy's window is parked behind every other window and mostly off screen, and it is joined to the app's accessibility windows only by an ordering event, which its launch window never gets: the tool finds it through the window server and says the app "did not expose it through Accessibility" (#579). It now asks such a copy to raise the window within its own level, which no one can see, and reads it like any app's window afterwards; a copy whose build predates that answers so itself. A copy opened by hand, without the launch switch that parks its window, is never raised: that window is among ordinary windows, and raising it would put it over the person's work. `scripts/test-copy can-click <suffix>` asks the same thing before any review, and has three answers. **Yes** (exit 0): the pi² app is running, the copy's window is in the window server, and the copy raised it and gives it to accessibility where the tool's search looks, as the app's main or focused window or among its windows. **No** (exit 1), with its cause: the pi² app is not running, which only the person can put right; no window of the copy in the window server after 30 seconds; or a copy that gives its window to accessibility in none of those places; or a window the tool would find but turn down, because the window server has it at another size, or not at all (#748), or at that size somewhere else where the size cannot say which window it is: one accessibility does not give as the app's main window, or one another of the copy's windows is the size of (#770). It says where each has it. **Cannot tell from here** (exit 2): the copy did not say, or its build predates the request (rebuild and `reopen` it). One thing it can never tell, even with a yes: whether pi² has the Accessibility permission, which no command can read without asking macOS or the pi² app. The copy decides from every attribute the tool's search reads, not from the app's window list alone, which a parked window drops out of whenever AppKit stops counting it as on the active Space, raise or no raise; the tool reads it through the main window then, so `can-click` once said no while the tool clicked (#612). A window that could not be raised still takes clicks at a point in a picture, but nothing of it can be read, and ScreenCaptureKit may still decline to capture it.
- In a parked copy the tool checks the window accessibility gives against the window server's record of it, so that a closed window's stale frame is never read. While macOS moves the window between Spaces, the two disagree on where it is for a moment. The tool once turned the copy's own window down then, and listed none of its controls (#748). It now takes the window when accessibility gives it as the app's main window and the window server has it at the same size, wherever that is, unless another window of the copy is that size too, when the size alone cannot say which is which (#770). A click or a context menu at a point in a parked copy lands on the innermost listed control there when a hit test finds nothing in the window: a hit test reads the screen, and finds nothing where the window is off the screen or behind another window, as most of a parked copy's window is. That control, from the last look, is worked only while it is still among the window's controls and at the point, with or without a request to approve; otherwise the agent is told to look again (#955, #969). Until #748, such a click went as a real click, which a copy in the background ignores. Only an element inside the window read counts as found in it: where a hit test finds none of the copy's windows, as off the screen, it can answer with the application element instead of nothing, and that, an element with no window, or the window itself, is not taken for a find in the window. Until #879 they were, so the click still went as a real click, unless the window was on the screen. What a hit test does find in the window is never replaced. In every other app a click at a point acts on what the hit test finds there, as it always did, and is never moved to a listed control beneath it: on screen, what the hit test finds is what is really there, such as an overlay.
- Whatever the chosen windows show is sent to the agent's model.
- macOS ties the permissions to the exact build. After rebuilding a development build, remove pi² from the Accessibility and Screen Recording lists and grant it again.

## For developers

The code that touches the screen is its own module, `app/Sources/ComputerKit`. `pi2-computer-check` uses stand-in views in-process to check how it reaches SwiftUI controls, chooses windows, and prepares and measures scrolling, needing no permission ([development.md](development.md#computer-use-checks)). Cross-app input and capture still need a check with an installed release. Try it by hand against one app with the probe, which is built separately and is not part of the app:

```bash
cd app && swift build --product pi2-probe
```

```bash
.build/debug/pi2-probe --only com.apple.TextEdit --out /tmp/probe '[{"action":"open_app"},{"action":"type","text":"hello"}]'
```

The probe uses the permissions of the terminal it runs from, and touches only the app named by `--only`. It is kept out of the app on purpose: a flag on the app itself would let any program borrow the app's Accessibility permission.
