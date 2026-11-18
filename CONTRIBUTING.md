# Contributing to pi²

Thanks for looking. Bug reports, fixes and improvements are all welcome.

## Reporting a bug

Open an issue with:

- what you did, what you expected, and what happened instead;
- your macOS version, and whether it is a development or a release build;
- the model and provider involved, if it matters;
- anything relevant from `engine.log` in `~/Library/Application Support/pi2`. Check it for keys or private text before pasting.

For a security problem, do not open an issue. See [SECURITY.md](SECURITY.md).

## Making a change

An agent handed issues to finish on its own follows these steps too, with [docs/agents.md](docs/agents.md) for what is particular to working that way.

1. Read [docs/development.md](docs/development.md) to build and run the project, and [docs/architecture.md](docs/architecture.md) for how it fits together.
2. Keep the change to one thing. A small pull request is reviewed sooner.
3. If you touch the engine, run `npm run check` and `npm test` in `engine/`, and add to `engine/test/engine.ts` when you add behaviour.
4. If you touch the app, build it and try the change in a throwaway copy, as [Testing safely](#testing-safely) shows. Apart from the browser's page handling, which `pi2-browser-probe` checks, the panes' layout, which `pi2-layout-check` checks, and what Return does in a message field, which `pi2-compose-check` checks, the app has no automated tests, so say in the pull request what you tried by hand.
5. If you touch `scripts/issue-hook`, run `scripts/test-issue-hook`; if you touch `scripts/issue`, run `scripts/test-issue` and `scripts/test-issue-hook`. They need `jq`, work in a temporary folder and touch no GitHub issue. If you touch `scripts/test-copy`, run `scripts/test-test-copy`, which checks its refusals in a temporary folder and launches nothing, then start, capture and stop a real copy with it. CI runs all three on every pull request (the first two on Linux, `scripts/test-test-copy` on macOS, where `PlistBuddy` is), but running them first saves a round trip.
6. Say plainly what is and is not tested.
7. If you can merge, do not sit waiting for the checks. Once the pull request is open, run `scripts/auto-merge <number>`, which turns on auto-merge (`gh pr merge <number> --auto --merge`): GitHub merges it when the required checks pass ([CI](docs/development.md#ci)), usually some minutes later and within a minute or two of the last one. Use that time for what is left (cleaning up a throwaway copy, the next issue), then run `scripts/auto-merge <number>` again, and again after each push, until it says `Merged.` before you call the work done. Each time it says where the pull request stands and puts right what it can: it turns auto-merge back on if it is off, and off and on again if every required check passed three minutes ago and nothing merged. A pull request with a failed check stays open. A check cancelled because no runner took the job is not a failure, and is run again by itself ([CI](docs/development.md#ci)). For a real failure, read the log (`gh run view <run-id> --log-failed`), fix it and push. For a conflict, merge `origin/main` into your branch and push. Auto-merge stays on through both.

## Changelog entries

When a change is worth knowing about in the next version, add a file for its entry to `changelog.d`, named after its issue: `changelog.d/237.md`. Do not add it to `CHANGELOG.md`, whose Unreleased section holds no entries. With a file each, pull requests merging at the same time never add to the same lines. The file holds the heading the entry goes under, on its first line, then the entry as it will appear:

```markdown
### Fixed
- When a sub-chat stopped on an error from the model's provider, the agent that handed it the work was told only that it “did not finish”. Now it is told the provider's message.
```

- Put features, changed behaviour and fixes that affect someone using an installed copy under `### Added`, `### Changed` or `### Fixed`. Say what they can do now or what used to go wrong, not which classes changed. Changes to an agent's tools, limits or instructions count too.
- Put changes only someone building, testing, contributing to or releasing pi² needs to know under `### For contributors`. Build modes, CI checks and repository workflows belong there. The release puts that heading after the reader-facing ones.
- Every line after the heading is a list item starting with `- `, or indented to continue the one above it: no blank lines and no other headings. One file may hold several items under its heading.
- A change with entries under two headings has a file for each: `237.md` and `237-contributors.md`. Anything after the number, up to `.md`, is lower-case letters, digits and hyphens.
- An entry that concerns two issues is one file, named after the issue its pull request fixes, or after either; mention the other in the text if a reader needs it. Do not write the same entry twice.
- To change or withdraw an entry that is merged but not yet released, edit or delete its file in a pull request of its own, or in the next one about that issue. Once released, an entry is in `CHANGELOG.md`'s section for its version, and stays as it is there.
- A refactor, test or typo fix with no behaviour or contributor workflow worth explaining needs no entry. Do not list every commit.

`node app/changelog.mjs check` says whether every file in `changelog.d` is well formed; CI runs the same check with the release-notes tests (`node --test app/test-release-notes.mjs`), so an entry that is not fails its own pull request. `node app/changelog.mjs notes 0.7.9` shows the release notes the entries would make for version 0.7.9, as GitHub and the update window would show them, and `node app/changelog.mjs release 0.7.9 --dry-run` the whole section, For contributors included. Neither changes anything.

When the owner makes a release, `node app/changelog.mjs release <version>` gathers the entries into the new version's section of `CHANGELOG.md`, below Unreleased: by heading (Added, Changed, Fixed, then For contributors), and under each heading by issue number. It removes their files. The order within a heading can be changed by hand before the release is merged. Do not move or rewrite entries in an already-published version to tidy its release notes. The contributor heading and its contents, up to the next `###` heading or version, are omitted from both GitHub's notes and the update feed; they stay in the changelog. See [docs/releasing.md](docs/releasing.md).

## Testing safely

pi² is often worked on, by people and by agents, on a Mac where it is also in use for real work. That person's data folder, Keychain items, login item and macOS permissions are theirs. A test must never touch them.

### Rules

- **Test only in a throwaway copy of a development build, with a bundle id of its own.** The bundle id is what macOS files the app's preferences, notifications and privacy permissions under, and in a development build it also names the data folder (which holds the conversations) and the Keychain service (which holds the sign-ins). A development build keeps apart from the installed pi² by itself: as `app/build.sh` makes it, its bundle id is `dev.pi2.app.dev`, and it never uses the usual data folder or Keychain service, even when the environment names them (see [docs/development.md](docs/development.md#build-and-run)). Every development build made on the Mac has that same id, though, so give your copy one of its own, with a suffix of your own, and it gets a data folder and a Keychain service of its own with it.
- **Never open a release build as it is built.** `./app/build.sh release` makes `app/build/pi².app` with the real bundle id, `dev.pi2.app`, and it uses the usual data folder and Keychain service unless `PI2_HOME` and `PI2_KEYCHAIN_SERVICE` name others. A shell where `PI2_HOME` names the usual data folder passes it on through `open`, as did every command an agent of a pi² from before #195 ran, inherited from its engine. To try one, copy it as below and launch the copy with both variables naming a temporary folder and a test service.
- **Never drive, quit, restart or signal the person's own running pi² or its engine.** Do not use `pkill` or `killall` by name, which would match theirs too. Stop only the processes you started, by their pid.
- **Never read or write the real Keychain service, `dev.pi2.credentials`, and never call a model provider with the person's sign-ins.** The scripted demo model (see [docs/development.md](docs/development.md)) answers without a provider.
- **Do not set off a macOS permission prompt** (Accessibility, Screen Recording, Notifications, Automation and the like). The prompt appears on the person's screen, and their answer stays until they change it in System Settings. A copy with its own bundle id has no permissions, so computer use and turning on notifications in it would ask. Quitting an app with `osascript` sends it an Apple event and can ask for Automation, which is another reason to stop by pid. Signing the person's own bundle again resets its permissions.
- **Leave the login item alone, in a test copy too, whether on or off.** There is one per Mac, the launchd agent `dev.pi2.engine`, and it belongs to the copy of pi² on the usual data folder. A copy on a data folder of its own, which every development build is, shows the switch in Settings as unavailable and cannot install, replace or remove the item. Do not work around that: the item starts the person's engine, and removing it stops that engine.
- **Never run `app/build.sh` in a checkout whose bundle is the one in use.** It deletes `app/build/pi² dev.app` (or, for a release build, `app/build/pi².app`) and builds it again, and a development build runs its engine from that checkout's `engine/src`, so switching branches there changes the running engine too. Build in a clone or a worktree of your own.
- **When several sessions share one checkout, work in a clone or worktree of your own**, and stage files by name, never `git add -A`: another session may have switched the branch or left work of its own there.
- **Clean up afterwards**: the copy, its data folder, its preferences, its test Keychain items, and any process you started. `scripts/test-copy stop` does all of it.
- **Before each commit, check that nothing personal is in it**: no names, email addresses or home folder paths in the files, the message or a screenshot. The repository and its issues are public. Commit with your GitHub no-reply address.

### A throwaway copy, step by step

`scripts/test-copy` does every step, one command each, and keeps the rules above as it goes: it works out the copy's bundle id, data folder and Keychain service from a suffix and refuses any that could be the usual ones, launches the copy with a clean environment, stops only what it started, and cleans up all of it.

In your own clone or worktree, build a development build. The script builds nothing; it copies `app/build/pi² dev.app` and refuses a release build.

```bash
(cd engine && npm ci)
./app/build.sh
```

For a problem that only happens with optimisation, use `./app/build.sh optimised` instead. It uses Swift's release configuration but keeps the development build's isolation and switches, including `PI2_SHOW` and the window placement below. Do not use a release build just to turn optimisation on.

Choose a suffix of your own, in lower-case letters, digits and hyphens, such as `test-` and your issue number, so that several sessions testing on the same Mac at once do not share preferences, data or sign-ins, and cleaning up after yours does not remove theirs. Then:

```bash
scripts/test-copy start test-7 --show inbox
scripts/test-copy shot test-7 app/build/test-copies/test-7/inbox.png
scripts/test-copy stop test-7
```

**`start <suffix> [--show <what>] [--menu <label>] [--welcome]`** copies the bundle to `app/build/test-copies/<suffix>/pi² <suffix>.app` with `ditto` (which keeps the symbolic links inside Sparkle's framework), gives it the bundle id `dev.pi2.app.<suffix>` and the name `pi² <suffix>` (which tells it apart in the Dock and the menu bar), and signs it again ad hoc, since editing `Info.plist` breaks the signature. The bundle id gives it the data folder `~/Library/Application Support/pi2-<suffix>` and the Keychain service `dev.pi2.credentials.<suffix>`.

It launches the copy with `open -n -g`, so it does not take the focus, and with a clean environment that names that data folder and Keychain service explicitly. A shell can have `PI2_HOME` naming the usual data folder (a terminal where it is set, or a command an agent of a pi² from before #195 runs, inherited from its engine), and `open` would pass it on; nothing the shell has reaches the copy. The copy's windows open behind every other window and parked in the bottom-right corner of the screen (`PI2_WINDOW_BEHIND=1`, `PI2_WINDOW_ORIGIN=10000,10000`), and keep drawing while covered (`PI2_DRAW_WHEN_HIDDEN=1`); `--show` sets `PI2_SHOW`, what the window opens on (see [docs/development.md](docs/development.md)).

A new data folder shows the first-run "Welcome to pi²" sheet, which would sit over every page a picture shows. So before launching, `start` marks it done in the copy's own data folder, as finishing it does: it writes `"onboarded": true` into the copy's `settings.json`, which its engine reads as it starts. Nothing in the app changes for this, so a release build shows the welcome as before. To work on the welcome itself, pass `--welcome`, and the copy shows it as a new installation does.

It waits until the copy's own engine, the app's child, is listening in the copy's data folder, then prints the data folder and the app's and the engine's process ids, and keeps them in `app/build/test-copies/<suffix>/state` with each one's start time and executable. If it fails part way, it stops and removes what it made.

An agent whose computer use has **Test copies of pi²** on may click, type and choose menu commands in a copy whose suffix begins with `test`, by its bundle id (`dev.pi2.app.test-7`), with the approvals its settings ask for: pi² checks that the app running under that id is a copy this script made of a development build ([docs/computer-use.md](docs/computer-use.md#clicking-in-test-copies)). An agent without it, and a person checking from the shell, can only look: computer use keeps every other copy of pi² look-only, and working a copy from the shell would need Accessibility, which must not be asked for. Everything below that checks a copy without clicking is for them.

Two things an agent cannot click to see, it can still check. `--show palette:<query>` opens the command palette with that query typed, so a capture shows the entries that match, such as `--show palette:duplicate`. `--menu <label>` sets `PI2_MENU`: the copy writes the items of the context menu on the element with that label (a conversation's title or number, an agent's name or id), in order and with the disabled ones marked, to `context-menu.txt` in its data folder, and `start` prints the file once it is there. A context menu cannot be captured, since macOS draws it only while the app is in front, and a copy must not take the focus. A row made after launch, such as a conversation made through the copy's engine socket, writes the file again when it comes on screen; read it then. [docs/development.md](docs/development.md) says how both work.

**`call <suffix> <method> [<json params>]`** sends one request to the engine socket in that copy's own data folder. It requires a copy started by this checkout and a still-recorded engine, ignores `PI2_HOME` and other socket overrides, and refuses a symlink for the data folder or socket. Params default to `{}` and must be a JSON object. It prints the complete JSON response (`{"id":1,"result":…}` or `{"id":1,"error":…}`), ignoring events, and exits non-zero on an engine error, a closed connection or a ten-minute wait without a response.

To show a conversation made after launch, start with `--show` naming its title (or number). The development build waits for it to appear while nothing else is open; no restart or click is needed (#294). For example, make a conversation explicitly on the scripted demo model (no provider or sign-in), then send it a message:

```bash
scripts/test-copy start test-7 --show 'Late demo'
CHAT=$(scripts/test-copy call test-7 conversation.create '{"title":"Late demo","model":{"provider":"demo","modelId":"demo-1"}}' | jq -er '.result.id')
scripts/test-copy call test-7 submit "{\"id\":$CHAT,\"text\":\"Hello from a test copy\"}"
```

`submit` returns a submission id when the message is accepted, **not when the answer is finished**. Once it has finished, put the conversation away (archiving stops any work still running):

```bash
scripts/test-copy call test-7 conversation.archive "{\"id\":$CHAT}"
```

**`shot <suffix> <file.png> [--window <title>]`** captures the copy's largest window, or the one with that title (Settings is titled after its tab, such as `General`), with `screencapture -l`, which takes that window only, whatever covers it. It first checks `CGPreflightScreenCaptureAccess()`, and refuses when screen capture is not already allowed, since capturing without it makes macOS ask; say then that the change was not seen on screen. The picture goes inside the checkout: one in `app/build/test-copies/<suffix>` goes with the copy at `stop`. A page settles for a few seconds after the window opens, so wait before capturing it.

**`stop <suffix>`** stops the app first, so that it does not start a new engine when the engine goes, then anything else running from the copy's bundle, then the engine, which outlives the app. It signals only the pids it recorded (or the engine the recorded app started in place of one, named in the copy's data folder), each after checking that the pid is still the process it recorded, by its start time and executable. Then it forgets the copy in Launch Services and removes the copy, its data folder, its preferences (`defaults delete`, and the file, which that can leave behind), every Keychain item under its own service, and the files its browser and macOS leave under its bundle id (`~/Library/WebKit`, `Caches`, `HTTPStorages` and `Saved Application State`), each by its exact path, and checks that none of it is left. If something is still running on the copy's data folder that it did not record, it removes nothing and says so.

**`status [<suffix>]`** shows what is recorded for a copy and whether its app and engine still run; with no suffix, every copy started from this checkout.

What it refuses, before it changes anything:

- a suffix that is empty, not lower-case letters, digits and hyphens, longer than 32 characters (the engine's socket path has a limit), or `dev`, the suffix every development build has as built; and so any bundle id, data folder or Keychain service that could be the usual one;
- a bundle that is not a development build of this checkout, so never a release build, which runs on the usual data folder;
- a suffix already in use, by this checkout or any other: the copy's folder in the checkout and its data folder are each made with `mkdir`, which only one of two `start`s at the same moment can do, so a second `start` with the same suffix fails and touches nothing of the first. Copies with different suffixes, from one checkout or several, are independent;
- a `stop`, `shot` or `call` for a copy this checkout did not start, and a signal to a pid it did not record;
- a picture outside the checkout.

It never uses `pkill` or `killall`, and never passes a pattern to `rm` or `security`. To see that the copy runs on its own folder, not the real one: its data folder holds `engine.sock`, `engine.pid` and an `engine.log` that ends with `listening on` and the path of that socket, and `ps -E -o command= -p <engine pid>` shows the copy's `PI2_KEYCHAIN_SERVICE`.

The files a copy's browser leaves are named one by one, never looked for with a pattern across `~/Library`, such as `ls -d ~/Library/*/dev.pi2.app.$ID*`. To expand it, the shell reads every folder in `~/Library`, and some of those hold other apps' data that macOS protects: reading one can put a privacy prompt on the person's screen, and the command waits until someone answers it. A command like that waited 29 minutes in #160: exactly as long as a system prompt was on the screen. Name the folder, or list one folder you know is not protected (`ls ~/Library/Caches`), never a pattern that reaches into all of them.

#### A copy of a release build

The script copies only development builds. To check the packaging itself (`app/check-release-build.mts --open-app --bundle-id …`, see [docs/releasing.md](docs/releasing.md)), copy the release build by hand, give it a bundle id of its own and sign it again, and never open it without `PI2_HOME` and `PI2_KEYCHAIN_SERVICE` naming a temporary folder and a test service, since a release build takes the usual ones otherwise and does not read the window variables:

```bash
ID=test-7
T=$(mktemp -d)
ditto "app/build/pi².app" "$T/pi² $ID.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.pi2.app.$ID" "$T/pi² $ID.app/Contents/Info.plist"
codesign --force --sign - "$T/pi² $ID.app"
```

Clean up after it as `stop` does: the copy and `$T`, its preferences, and its Keychain items, each by its exact name.

## What fits

- Fixes, and features that make agents more useful or easier to keep an eye on.
- Anything that widens what an agent can do without asking needs a clear reason and a way for the person to see and stop it.
- Secrets go in the Keychain. Nothing about the person leaves the Mac except to the providers and servers they connected.

## Style

- Swift: SwiftUI, Swift 6, no third-party packages so far. Shared colours and controls live in `Theme.swift`.
- TypeScript: strict, run directly by Node, tabs for indentation.
- Comments explain why, not what.
- Text the person reads is plain and specific: say what happened and what to do next.
