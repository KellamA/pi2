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
4. If you touch the app, build it and try the change in a throwaway copy, as [Testing safely](#testing-safely) shows. Apart from the browser's page handling, which `pi2-browser-probe` checks, the app has no automated tests, so say in the pull request what you tried by hand.
5. Say plainly what is and is not tested.

## Testing safely

pi² is often worked on, by people and by agents, on a Mac where it is also in use for real work. That person's data folder, Keychain items, login item and macOS permissions are theirs. A test must never touch them.

### Rules

- **Test only in a throwaway copy of the app**, with its own bundle id, `PI2_HOME` on a temporary folder, and its own `PI2_KEYCHAIN_SERVICE`. The data folder holds the conversations and the Keychain service holds the sign-ins. The bundle id is what macOS files the app's preferences, notifications and privacy permissions under, so a copy with the same id shares them with the real app.
- **Never drive, quit, restart or signal the person's own running pi² or its engine.** Do not use `pkill` or `killall` by name, which would match theirs too. Stop only the processes you started, by their pid.
- **Never read or write the real Keychain service, `dev.pi2.credentials`, and never call a model provider with the person's sign-ins.** The scripted demo model (see [docs/development.md](docs/development.md)) answers without a provider.
- **Do not set off a macOS permission prompt** (Accessibility, Screen Recording, Notifications, Automation and the like). The prompt appears on the person's screen, and their answer stays until they change it in System Settings. A copy with its own bundle id has no permissions, so computer use and turning on notifications in it would ask. Quitting an app with `osascript` sends it an Apple event and can ask for Automation, which is another reason to stop by pid. Signing the person's own bundle again resets its permissions.
- **Leave the login item alone, in a test copy too, whether on or off.** There is one per Mac, the launchd agent `dev.pi2.engine`, and the switch in Settings acts on it whichever copy you use. Turning it off in a test copy stops the person's engine; turning it on replaces their item with one that runs the copy's engine on the real data folder.
- **Never run `app/build.sh` in a checkout whose bundle is the one in use.** It deletes `app/build/pi².app` and builds it again, and a development build runs its engine from that checkout's `engine/src`, so switching branches there changes the running engine too. Build in a clone or a worktree of your own.
- **When several sessions share one checkout, work in a clone or worktree of your own**, and stage files by name, never `git add -A`: another session may have switched the branch or left work of its own there.
- **Clean up afterwards**: the copy, its data folder, its preferences, its test Keychain items, and any process you started.
- **Before each commit, check that nothing personal is in it**: no names, email addresses or home folder paths in the files, the message or a screenshot. The repository and its issues are public. Commit with your GitHub no-reply address.

### A throwaway copy, step by step

In your own clone or worktree, build a development build:

```bash
(cd engine && npm ci)
./app/build.sh
```

Copy it to a temporary folder, give it its own bundle id and name, and sign it again. `ditto` keeps the symbolic links inside Sparkle's framework; editing `Info.plist` breaks the bundle's signature, so it is signed again ad hoc. The new name tells the two apart in the Dock and the menu bar. If other sessions may be testing on the same Mac at the same time, give the bundle id and the Keychain service a suffix of your own (`dev.pi2.app.test-7`, `dev.pi2.credentials.test-7`), so that cleaning up after yours does not remove theirs.

```bash
T=$(mktemp -d)
APP="$T/pi² test.app"
ditto "app/build/pi².app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.pi2.app.test" \
  -c "Set :CFBundleName pi² test" -c "Set :CFBundleDisplayName pi² test" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
```

Launch it on a data folder of its own and a Keychain service of its own. The app passes both variables on to the engine it starts.

```bash
open -n "$APP" --env PI2_HOME="$T/home" --env PI2_KEYCHAIN_SERVICE=dev.pi2.credentials.test
```

Check that it runs on the throwaway folder, not the real one. `$T/home` should now hold `engine.sock`, `engine.pid` and an `engine.log` that ends with `listening on` and the path of that socket. (`app.log` appears there only once the app has had something to note, such as a dropped connection.) The engine should be the copy's own child, with both variables set:

```bash
cat "$T/home/engine.log"
ENGINE_PID=$(cat "$T/home/engine.pid")
APP_PID=$(pgrep -f "$APP/Contents/MacOS/pi2")
ps -o pid,ppid,command -p "$ENGINE_PID"   # its parent is $APP_PID
ps -E -o command= -p "$ENGINE_PID" | tr ' ' '\n' | grep '^PI2_'
```

When you are done, stop both by pid. The engine outlives the app, so stopping the app is not enough; stop the app first, so it does not start a new engine when this one goes.

```bash
kill "$APP_PID"
kill "$ENGINE_PID"
```

Then clean up: forget the copy in Launch Services, remove it with its data folder, remove its preferences, and delete any Keychain items it made under its own service.

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP"
rm -rf "$T"
defaults delete dev.pi2.app.test
rm -f ~/Library/Preferences/dev.pi2.app.test.plist
while security delete-generic-password -s dev.pi2.credentials.test >/dev/null 2>&1; do :; done
```

`defaults delete` can leave an empty file behind, hence the `rm`. If you used the copy's browser, also look for folders named `dev.pi2.app.test` in `~/Library/WebKit`, `~/Library/Caches` and `~/Library/HTTPStorages`.

## What fits

- Fixes, and features that make agents more useful or easier to keep an eye on.
- Anything that widens what an agent can do without asking needs a clear reason and a way for the person to see and stop it.
- Secrets go in the Keychain. Nothing about the person leaves the Mac except to the providers and servers they connected.

## Style

- Swift: SwiftUI, Swift 6, no third-party packages so far. Shared colours and controls live in `Theme.swift`.
- TypeScript: strict, run directly by Node, tabs for indentation.
- Comments explain why, not what.
- Text the person reads is plain and specific: say what happened and what to do next.
