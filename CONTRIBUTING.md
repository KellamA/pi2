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

1. Read [docs/development.md](docs/development.md) to build and run the project, and [docs/architecture.md](docs/architecture.md) for how it fits together.
2. Keep the change to one thing. A small pull request is reviewed sooner.
3. If you touch the engine, run `npm run check` and `npm test` in `engine/`, and add to `engine/test/engine.ts` when you add behaviour.
4. If you touch the app, build it and try the change in a throwaway copy, as [Testing safely](#testing-safely) shows. Apart from the browser's page handling, which `pi2-browser-probe` checks, the panes' layout, which `pi2-layout-check` checks, and what Return does in a message field, which `pi2-compose-check` checks, the app has no automated tests, so say in the pull request what you tried by hand.
5. If you touch `scripts/issue-hook`, run `scripts/test-issue-hook`; if you touch `scripts/issue`, run `scripts/test-issue` and `scripts/test-issue-hook`. They need `jq`, work in a temporary folder and touch no GitHub issue.
6. Say plainly what is and is not tested.
7. If you can merge, do not sit waiting for the checks. Once the pull request is open, run `gh pr merge <number> --auto --merge`: GitHub merges it when the three required checks pass, about four minutes later. Use that time for what is left (cleaning up a throwaway copy, the next issue), then make sure it merged before you call the work done: `gh pr view <number> --json state -q .state` says `MERGED`. A pull request with a failed check stays open. Read the log (`gh run view --log-failed`), fix it and push, and check that auto-merge is still on (`gh pr view <number> --json autoMergeRequest`).

## Changelog entries

Add an entry under **Unreleased** in `CHANGELOG.md` when a change is worth knowing about in the next version:

- Put features, changed behaviour and fixes that affect someone using an installed copy under `### Added`, `### Changed` or `### Fixed`, reader-facing changes first. Say what they can do now or what used to go wrong, not which classes changed. Changes to an agent's tools, limits or instructions count too.
- Put changes only someone building, testing, contributing to or releasing pi² needs to know under `### For contributors`, after the reader-facing entries. Build modes, CI checks and repository workflows belong there. Use `####` for any subheadings inside it, not `###`.
- A refactor, test or typo fix with no behaviour or contributor workflow worth explaining needs no entry. Do not list every commit.

Keep Unreleased at the top. When the owner makes a release, its entries become the new version's section and a fresh Unreleased section stays above it. Do not move or rewrite entries in an already-published version to tidy its release notes. The contributor heading and its contents, up to the next `###` heading or version, are omitted from both GitHub's notes and the update feed; they stay in the changelog. `node --test app/test-release-notes.mjs` checks the extraction without packaging or releasing anything. See [docs/releasing.md](docs/releasing.md).

## Testing safely

pi² is often worked on, by people and by agents, on a Mac where it is also in use for real work. That person's data folder, Keychain items, login item and macOS permissions are theirs. A test must never touch them.

### Rules

- **Test only in a throwaway copy of a development build, with a bundle id of its own.** The bundle id is what macOS files the app's preferences, notifications and privacy permissions under, and in a development build it also names the data folder (which holds the conversations) and the Keychain service (which holds the sign-ins). A development build keeps apart from the installed pi² by itself: as `app/build.sh` makes it, its bundle id is `dev.pi2.app.dev`, and it never uses the usual data folder or Keychain service, even when the environment names them (see [docs/development.md](docs/development.md#build-and-run)). Every development build made on the Mac has that same id, though, so give your copy one of its own, with a suffix of your own, and it gets a data folder and a Keychain service of its own with it.
- **Never open a release build as it is built.** `./app/build.sh release` makes `app/build/pi².app` with the real bundle id, `dev.pi2.app`, and it uses the usual data folder and Keychain service unless `PI2_HOME` and `PI2_KEYCHAIN_SERVICE` name others. A command an agent of pi² runs already has `PI2_HOME` naming the usual data folder, inherited from pi²'s engine, and `open` passes it on. To try one, copy it as below and launch the copy with both variables naming a temporary folder and a test service.
- **Never drive, quit, restart or signal the person's own running pi² or its engine.** Do not use `pkill` or `killall` by name, which would match theirs too. Stop only the processes you started, by their pid.
- **Never read or write the real Keychain service, `dev.pi2.credentials`, and never call a model provider with the person's sign-ins.** The scripted demo model (see [docs/development.md](docs/development.md)) answers without a provider.
- **Do not set off a macOS permission prompt** (Accessibility, Screen Recording, Notifications, Automation and the like). The prompt appears on the person's screen, and their answer stays until they change it in System Settings. A copy with its own bundle id has no permissions, so computer use and turning on notifications in it would ask. Quitting an app with `osascript` sends it an Apple event and can ask for Automation, which is another reason to stop by pid. Signing the person's own bundle again resets its permissions.
- **Leave the login item alone, in a test copy too, whether on or off.** There is one per Mac, the launchd agent `dev.pi2.engine`, and it belongs to the copy of pi² on the usual data folder. A copy on a data folder of its own, which every development build is, shows the switch in Settings as unavailable and cannot install, replace or remove the item. Do not work around that: the item starts the person's engine, and removing it stops that engine.
- **Never run `app/build.sh` in a checkout whose bundle is the one in use.** It deletes `app/build/pi² dev.app` (or, for a release build, `app/build/pi².app`) and builds it again, and a development build runs its engine from that checkout's `engine/src`, so switching branches there changes the running engine too. Build in a clone or a worktree of your own.
- **When several sessions share one checkout, work in a clone or worktree of your own**, and stage files by name, never `git add -A`: another session may have switched the branch or left work of its own there.
- **Clean up afterwards**: the copy, its data folder, its preferences, its test Keychain items, and any process you started.
- **Before each commit, check that nothing personal is in it**: no names, email addresses or home folder paths in the files, the message or a screenshot. The repository and its issues are public. Commit with your GitHub no-reply address.

### A throwaway copy, step by step

In your own clone or worktree, build a development build:

```bash
(cd engine && npm ci)
./app/build.sh
```

For a problem that only happens with optimisation, use `./app/build.sh optimised` instead. It uses Swift's release configuration but keeps the development build's isolation and switches, including `PI2_SHOW` and the window placement below. Do not use a release build just to turn optimisation on.

This makes `app/build/pi² dev.app`. Copy it to a temporary folder, give it its own bundle id and name, and sign it again. Choose a suffix of your own for `ID`, in lower-case letters, digits and hyphens, such as your issue number, so that several sessions testing on the same Mac at once do not share preferences, data or sign-ins, and cleaning up after yours does not remove theirs. The bundle id `dev.pi2.app.$ID` gives the copy the data folder `~/Library/Application Support/pi2-$ID` and the Keychain service `dev.pi2.credentials.$ID`, so there is nothing else to set. `ditto` keeps the symbolic links inside Sparkle's framework; editing `Info.plist` breaks the bundle's signature, so it is signed again ad hoc. The new name tells your copy apart from other copies in the Dock and the menu bar.

```bash
ID=test-7
T=$(mktemp -d)
APP="$T/pi² $ID.app"
DATA="$HOME/Library/Application Support/pi2-$ID"
ditto "app/build/pi² dev.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.pi2.app.$ID" \
  -c "Set :CFBundleName pi² $ID" -c "Set :CFBundleDisplayName pi² $ID" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
```

Launch it. `-g` keeps it from taking the focus, and the two variables keep its windows out of the way of whoever is at the Mac: behind every other window, and parked in the bottom-right corner of the screen instead of the middle (see [development.md](docs/development.md); a development build reads them, a release build does not). A window kept there can still be captured with `screencapture -l`.

```bash
open -n -g "$APP" --env PI2_WINDOW_BEHIND=1 --env PI2_WINDOW_ORIGIN=10000,10000
```

Check that it runs on its own folder, not the real one. `$DATA` should now hold `engine.sock`, `engine.pid` and an `engine.log` that ends with `listening on` and the path of that socket. Launched from an agent's shell, whose `PI2_HOME` names the usual data folder, it also has an `app.log` saying the copy set that aside; otherwise `app.log` appears only once the app has had something to note, such as a dropped connection. The engine should be the copy's own child, listening in `$DATA`, with the copy's Keychain service:

```bash
cat "$DATA/engine.log" "$DATA/app.log"
ENGINE_PID=$(cat "$DATA/engine.pid")
APP_PID=$(pgrep -f "$APP/Contents/MacOS/pi2")
ps -o pid,ppid,command -p "$ENGINE_PID"   # its parent is $APP_PID
lsof -a -U -p "$ENGINE_PID"                # its engine.sock is in $DATA
ps -E -o command= -p "$ENGINE_PID" | tr ' ' '\n' | grep '^PI2_KEYCHAIN_SERVICE='
```

You can still give the copy `--env PI2_HOME=…` and `--env PI2_KEYCHAIN_SERVICE=…` of your own, such as a folder in `$T`; a development build takes any but the usual ones. A copy of a release build needs both, as the rules above say, and does not read the window variables; use an optimised development build unless the packaging or updating itself is what you need to check.

When you are done, stop both by pid. The engine outlives the app, so stopping the app is not enough; stop the app first, so it does not start a new engine when this one goes.

```bash
kill "$APP_PID"
kill "$ENGINE_PID"
```

Then clean up: forget the copy in Launch Services, remove it with its data folder, remove its preferences, and delete any Keychain items it made under its own service.

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP"
rm -rf "$T" "$DATA"
defaults delete "dev.pi2.app.$ID"
rm -f ~/Library/Preferences/"dev.pi2.app.$ID.plist"
while security delete-generic-password -s "dev.pi2.credentials.$ID" >/dev/null 2>&1; do :; done
```

`defaults delete` can leave an empty file behind, hence the `rm`. The copy's browser, and anything else in it that loads from the web, can leave files of its own under its bundle id. Remove them by their exact paths:

```bash
rm -rf ~/Library/WebKit/"dev.pi2.app.$ID" ~/Library/Caches/"dev.pi2.app.$ID" \
  ~/Library/HTTPStorages/"dev.pi2.app.$ID" ~/Library/HTTPStorages/"dev.pi2.app.$ID.binarycookies"
```

Do not look for them with a pattern across `~/Library`, such as `ls -d ~/Library/*/dev.pi2.app.$ID*`. To expand it, the shell reads every folder in `~/Library`, and some of those hold other apps' data that macOS protects: reading one can put a privacy prompt on the person's screen, and the command waits until someone answers it. A command like that waited 29 minutes in #160: exactly as long as a system prompt was on the screen. Name the folder, as above, or list one folder you know is not protected (`ls ~/Library/Caches`), never a pattern that reaches into all of them.

## What fits

- Fixes, and features that make agents more useful or easier to keep an eye on.
- Anything that widens what an agent can do without asking needs a clear reason and a way for the person to see and stop it.
- Secrets go in the Keychain. Nothing about the person leaves the Mac except to the providers and servers they connected.

## Style

- Swift: SwiftUI, Swift 6, no third-party packages so far. Shared colours and controls live in `Theme.swift`.
- TypeScript: strict, run directly by Node, tabs for indentation.
- Comments explain why, not what.
- Text the person reads is plain and specific: say what happened and what to do next.
