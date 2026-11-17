# Releasing

How pi² is built for download, how installed copies update, and what has to be set up once before the first release.

## What a release is

Pushing a tag such as `v0.7.0` runs [.github/workflows/release.yml](../.github/workflows/release.yml). It tests the engine, builds a self-contained app, signs it with a Developer ID, has Apple notarize it, packages and starts it, and makes a **draft** GitHub release with three files:

| File | For |
|---|---|
| `pi2-<version>.dmg` | People downloading pi². The app beside a link to Applications; signed, notarized and stapled. |
| `pi2-<version>.zip` | Copies already installed. Sparkle downloads this to update them. |
| `appcast.xml` | The update feed: the newest version, its notes from the changelog, and a signature over the zip. The feed itself is signed too. |

Nothing reaches anyone until you publish the draft. Installed copies read the feed at `https://github.com/KellamA/pi2/releases/latest/download/appcast.xml`, which GitHub serves from the newest **published** release, so drafts and pre-releases are never offered as updates.

Builds are for Apple silicon only: the Node copied into the app is the runner's arm64 build.

## Release builds and development builds

`./app/build.sh release`, which the workflow runs, makes the build that is released. `./app/build.sh` alone makes a development build, which is kept apart from an installed release so that trying one never touches the installed copy's data ([development.md](development.md#build-and-run)):

| | Release build | Development build |
|---|---|---|
| Bundle | `app/build/pi².app` | `app/build/pi² dev.app` |
| Bundle id and name | `dev.pi2.app`, "pi²" | `dev.pi2.app.dev`, "pi² dev" |
| Engine and Node | inside the app | the checkout's `engine/src` and the Node on the `PATH` |
| Data folder | `~/Library/Application Support/pi2`, unless `PI2_HOME` names another | `~/Library/Application Support/pi2-dev`, unless `PI2_HOME` names another; never the release's |
| Keychain service | `dev.pi2.credentials`, unless `PI2_KEYCHAIN_SERVICE` names another | `dev.pi2.credentials.dev`, unless `PI2_KEYCHAIN_SERVICE` names another; never the release's |
| Login item | can be turned on in Settings, on the usual data folder | never |
| Updates | with `SPARKLE_PUBLIC_KEY`, from the feed | never |
| `engine.info` check | replaces an engine from another build | leaves it running, noted in `app.log` |

`./app/build.sh optimised` makes a development build with Swift's release configuration (`-O`), for checking optimisation-only problems without losing `PI2_SHOW`, hidden drawing, window placement or isolation. It is not a release candidate: it still runs the engine from the checkout. Those development affordances use the compile-time condition `PI2_DEVELOPMENT` (defined for debug builds in `Package.swift`, passed explicitly by the script for optimised development builds). A release build never defines it, so there is no environment switch a person could be tricked into setting to enable them.

The app tells which it is by whether it carries its own engine (`DevelopmentBuild.swift`), not by how it was compiled. A development build's data folder and Keychain service follow its bundle id, so a test copy given `dev.pi2.app.test-7` uses `pi2-test-7` and `dev.pi2.credentials.test-7`.

## Setting up, once

### 1. A Developer ID

1. Join the Apple Developer Program.
2. In Xcode › Settings › Accounts, or at developer.apple.com, make a **Developer ID Application** certificate.
3. In Keychain Access, export it with its private key as a `.p12` file with a password.

The certificate carries the account holder's name, and anyone can read it from the app's signature. An organization account shows the organization's name instead.

### 2. A notarization key

In App Store Connect › Users and Access › Integrations › App Store Connect API, make a key with the Developer role. Download the `.p8` file (it can only be downloaded once) and note its Key ID and the Issuer ID.

### 3. An updates key

Sparkle checks every update against a key pair of its own, separate from Apple's. Build once so the tools are there, then:

```bash
cd app && swift package resolve && .build/artifacts/sparkle/Sparkle/bin/generate_keys
```

This keeps the private key in your login Keychain and prints the public key. Export the private key for CI:

```bash
app/.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
```

Keep a copy somewhere safe and delete the file once it is in GitHub. If the private key is lost, installed copies can never be updated again: they only accept updates signed with it. If it leaks, anyone who can serve a feed to your users can ship them an update.

### 4. GitHub

In the repository's Settings › Environments, make an environment called `release`. Limit it to tags matching `v*`, and add yourself as a required reviewer if you want to approve each release run. Then add:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12` | `base64 -i developer-id.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | the `.p12` password |
| `SIGN_IDENTITY` | the certificate's full name, `Developer ID Application: … (TEAMID)` |
| `NOTARY_KEY_P8` | `base64 -i AuthKey_XXXX.p8` |
| `NOTARY_KEY_ID` | the key's ID |
| `NOTARY_ISSUER` | the issuer ID |
| `SPARKLE_PRIVATE_KEY` | the contents of `sparkle-private-key.txt` |

| Variable | Value |
|---|---|
| `SPARKLE_PUBLIC_KEY` | the public key `generate_keys` printed |

## Making a release

1. Set the version in `app/VERSION`, then gather the entries waiting in `changelog.d` into its section of `CHANGELOG.md`:

   ```bash
   node app/changelog.mjs release 0.7.9
   ```

   This adds a `## 0.7.9` section below `## Unreleased`, with the entries under `### Added`, `### Changed`, `### Fixed` and `### For contributors`, in that order, and under each heading by issue number, and removes the entry files. It refuses, and changes nothing, when `app/VERSION` says another version, the section exists already, an entry is not well formed, an entry was written into Unreleased instead, or no entry is reader-facing. `--dry-run` prints the section without writing it. Reorder lines within a heading by hand if you like, then commit `CHANGELOG.md`, `app/VERSION` and the removed files. That version's reader-facing entries become the release notes and what the update window shows; `### For contributors` and its contents are left out. Do not edit already-published sections to tidy their notes.
2. Merge to `main`.
3. Tag the commit on `main` and push the tag:

   ```bash
   git tag v0.7.0 && git push origin v0.7.0
   ```

4. When the workflow finishes, open the draft release, download the disk image, and try it.
5. Publish the draft. Installed copies see the update the next time they check.

The workflow refuses a tag that does not match `app/VERSION`, a commit that is not on `main`, and a version with no changelog section. The build number is the number of commits on `main`, which is what Sparkle compares, so it only goes up as long as releases come from `main`.

## Previewing the notes without releasing

```bash
node app/changelog.mjs notes 0.7.9
node app/release-notes.mjs 0.7.6
node --test app/test-release-notes.mjs
```

The first shows the notes the entries in `changelog.d` would make for the next version, here 0.7.9, without changing anything; the second those of a version already in `CHANGELOG.md`. Both use the extractor `app/release.sh` uses. `release.sh` uses it to write `notes.md`, then takes the feed's description from that file, so neither destination includes For contributors. Relative `docs/` links become links to that version's tag. A missing or duplicate version section, or one with no reader-facing notes, fails before packaging. The tests run in ordinary CI, cover the heading at the end and in the middle, and keep the published 0.7.5 and 0.7.6 notes byte-for-byte unchanged. Their old contributor-only entries have not been moved retroactively. The same tests check that every file in `changelog.d` is well formed, and that gathering 0.7.8's entries from files of their own makes its published section byte for byte.

## Checking the packaged build without releasing

```bash
./app/build.sh release
node app/check-release-build.mts "app/build/pi².app"
```

This does not tag, publish, draft or use release secrets. Without `SIGN_IDENTITY`, the build is signed ad hoc. The check starts **the Node and engine inside the app**, from `/` with macOS's bare `PATH`, a temporary `PI2_HOME`, its own Keychain service and `PI2_LOGIN_SHELL=off`. It checks the bundle's version, build number, build id and signature, asks `engine.info` and compares its build, entry point and process id, gets an answer from the scripted demo model without a provider, and stops the engine cleanly. A failure names what was wrong and shows the end of the engine log; the temporary data and processes go away on failure too.

`--version`, `--build-number` and `--commit` pin the expected release. A `.zip` or `.dmg` instead of an app checks the app **inside that package** (and that the disk image has its Applications link). The release workflow runs this after packaging and Gatekeeper's checks, before drafting: it opens the app from the unpacked update archive too (`--open-app`), verifies that it started its own packaged engine and connected to it, and checks the engine from the mounted disk image. Any failure stops the run before a draft exists. The owner's download-and-try step above stays: this is not a check of every feature or an actual Sparkle update.

Ordinary CI's existing **App (build)** job builds a release-configuration app without a Developer ID and runs the same script with `--open-app`. Thus the start-up check is exercised on GitHub's macOS before the next release depends on it. Only the Developer-ID-signed, notarized packages are first checked at that next release. On a Mac where pi² is in use, do **not** open the release bundle as-is: `--open-app` refuses its real bundle id outside CI. Use a throwaway copy with its own id as [Testing safely](../CONTRIBUTING.md#testing-safely) describes, and pass that id with `--bundle-id`.

## How updating works in the app

- **Asking first.** Nothing is checked until the person agrees. Sparkle asks on the second launch whether to check automatically; Settings › General › Updates changes the answer, and **pi² › Check for Updates…** checks at any time. A check sends only the app's version and the macOS version.
- **Checking the download.** Sparkle refuses a feed or an archive not signed with the updates key, and checks the new app's code signature against the installed one.
- **The engine.** The engine runs Node and the engine's files from inside the app, and can outlive it. Just before Sparkle replaces the app, pi² stops the engine cleanly. If agents are meant to keep running without the app (Settings › General › In the background), the engine is started again 20 seconds later from the new copy. When the new app opens, it asks the engine which build it belongs to (`engine.info`). If the engine is from another build (left over from before the update, or from a copy of the app that has since moved), the app stops it and starts its own, and points the login item at itself. Runs pick up where they stopped.
- **Sheets.** While a sheet is open (the welcome, the command palette, a confirmation), macOS ignores a request to quit, so "Install and Relaunch" would do nothing. pi² closes sheets just before the update installs and, if the app has not quit two seconds later, closes them again and quits.
- **Development builds** never update themselves, and never replace the engine they find: they run from the source folder, on a data folder of their own, so the engine there is their own or another development build's. One pointed at another copy's data folder on purpose would otherwise stop that copy's engine. An engine started from another checkout is noted in `app.log`.

## Building a signed copy on your own Mac

```bash
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=profile SPARKLE_PUBLIC_KEY=… ./app/build.sh release
```

```bash
SPARKLE_PRIVATE_KEY="$(cat sparkle-private-key.txt)" SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=profile ./app/release.sh
```

`NOTARY_PROFILE` is a profile saved with `xcrun notarytool store-credentials`. The files end up in `app/build/release`.

## Trying an update without publishing anything

This is how updating was first tested. Keep it away from the copy of pi² you use: give the test copy its own bundle identifier, data folder and Keychain service, and turn off its Quick Ask shortcut so it does not take the shortcut from your own copy.

1. In a throwaway clone, change the release build's `BUNDLE_ID` in `app/build.sh` (for example to `dev.pi2.app.updtest`). A release build keeps the usual data folder whatever its bundle id, hence the next step. In `EngineClient.init`, `setenv` `PI2_HOME` to a short folder of its own and `PI2_KEYCHAIN_SERVICE` to a test service, so they hold even when Sparkle relaunches the app without your environment.
2. Make a throwaway updates key without touching the Keychain:

   ```bash
   node -e 'const {generateKeyPairSync}=require("crypto");const k=generateKeyPairSync("ed25519");console.log(k.privateKey.export({format:"der",type:"pkcs8"}).subarray(-32).toString("base64"));console.log(k.publicKey.export({format:"der",type:"spki"}).subarray(-32).toString("base64"))'
   ```

3. Build the old version with `SPARKLE_PUBLIC_KEY=<public>`, `SPARKLE_FEED_URL=http://127.0.0.1:8737/appcast.xml` and `PI2_BUILD_NUMBER=100`, and copy the app aside. Raise `app/VERSION`, add a changelog section, build again with `PI2_BUILD_NUMBER=101`, then run `SPARKLE_PRIVATE_KEY=<private> DOWNLOAD_URL=http://127.0.0.1:8737 ./release.sh`.
4. Serve `app/build/release` with `python3 -m http.server 8737 --bind 127.0.0.1`, open the old copy, and choose **Check for Updates…**.
