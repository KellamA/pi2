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

`./app/build.sh optimised` makes a development build with Swift's release configuration (`-O`), for checking optimisation-only problems without losing `PI2_SHOW`, hidden drawing, window placement or isolation. It is not a release candidate: it still runs the engine from the checkout. Those development affordances use the compile-time condition `PI2_DEVELOPMENT` (defined for debug builds in `Package.swift`, passed explicitly by the script for optimised development builds). A release build never defines it, so there is no environment switch a person could be tricked into setting to enable them. `app/check-release-build.mts`, which CI runs on a release build of every change and the release workflow on what it publishes, fails if the app's executable so much as names one of the variables those affordances read (`PI2_SHOW`, `PI2_MENU` and the window variables), or if pi² Remote's names one of a development build's strings ([pi2-remote.md](pi2-remote.md#packaging-and-signing)). It fails too if the executable names Settings › Devices or the `devices.*` requests the page makes: until a real phone is paired (#712), the Devices tab, the device line in the menu bar item and the sidebar, and the app's asking for the `devices` event are development builds' alone, inside the same condition (#679).

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

In the repository's Settings › Environments, make an environment called `release`. Limit it to tags matching `v*`, and add yourself as a required reviewer, so that each release run waits for your approval. Once the agents have an account of their own, which can push tags, that approval is what keeps these secrets yours ([relay.md, step 3](relay.md#3-the-environments)). Then add:

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
2. Merge to `main`. The pull request runs `App (build)`: `app/VERSION` is one of the files that job's steps build and check with. A version with white space inside it is refused by CI's first job, which then runs every macOS job ([CI](development.md#ci)).
3. Tag the commit on `main` and push the tag:

   ```bash
   git tag v0.7.0 && git push origin v0.7.0
   ```

4. When the workflow finishes, open the draft release, download the disk image, and try it.
5. Publish the draft. Installed copies see the update the next time they check.

The workflow refuses a tag that does not match `app/VERSION`, a commit that is not on `main`, and a version with no changelog section. The build number is the number of commits on `main`, which is what Sparkle compares, so it only goes up as long as releases come from `main`.

If no macOS runner takes the job in time, GitHub cancels it before it starts, and it is run again by itself, as CI's jobs are ([CI](development.md#ci)). Nothing has been built, signed or drafted by then, so running it again is safe.

## The iPhone app and TestFlight

pi² for iPhone is given out to the owner alone, through TestFlight's internal testing, and built so that the App Store stays possible ([iphone.md](iphone.md#91-given-out-testflights-internal-testing), 9.1). It is a second distribution with a second version and its own builds: nothing here touches the Mac app's release, its version or its tags. **Every step below is the owner's.** No agent holds an Apple account, a signing certificate, a provisioning profile or an App Store Connect key, and no agent builds for a phone or uploads anything; the values the upload needs live where you keep them, never in this repository and never in the reach of a workflow run from a branch ([iphone.md](iphone.md#123-before-anything-is-built-the-repository-p0), 12.3). **And they are done as another macOS user, or on another Mac, than the one agents run commands as**: [`docs/relay.md` step 1](relay.md#1-the-agents-own-identity-on-github) asks for that user for the same reason, and step 6 below says what it means for the key that uploads.

### The identifiers, and what each one is

The five App IDs below are the ones the project builds; a build signs for the App ID its bundle identifier names, so they must be registered exactly ([iphone.md](iphone.md#91-given-out-testflights-internal-testing)). The four the app and its extensions need are in `iphone/pi2.xcodeproj`, and each one's capabilities are in the entitlements file beside its sources; `scripts/iphone-release` refuses to archive if any of them has been renamed or has lost its file.

| App ID | What it is | Capabilities to turn on | Given by |
|---|---|---|---|
| `dev.pi2.ios` | pi² for iPhone | Push Notifications, App Attest, App Groups (`group.dev.pi2.ios`), Keychain Sharing (`group.dev.pi2.ios`) | `iphone/pi2.entitlements` |
| `dev.pi2.ios.notifications` | the notification service extension, which opens a push that arrives while the phone is locked | App Groups (`group.dev.pi2.ios`), Keychain Sharing (`group.dev.pi2.ios`) | `iphone/NotificationService/NotificationService.entitlements` |
| `dev.pi2.ios.widgets` | the widgets and the Live Activity | App Groups (`group.dev.pi2.ios`) | `iphone/Widgets/Widgets.entitlements` |
| `dev.pi2.ios.share` | the share sheet | App Groups (`group.dev.pi2.ios`) | `iphone/ShareExtension/ShareExtension.entitlements` |
| `dev.pi2.app.remote` | pi² Remote, the Mac app's helper (macOS) | Keychain Sharing (its own group) | `app/remote-helper.entitlements` |

The App Group is one group for the app and its three extensions: make it first, then give it to each App ID. The Keychain Sharing group is the same name, `group.dev.pi2.ios`: Apple files it under the team's prefix, which is why the entitlements say `$(AppIdentifierPrefix)group.dev.pi2.ios` and no team id is written in this repository. Only the record key and what the phone keeps of the Mac are kept there, so that a notification that arrives while the phone is locked can be opened; the phone's other keys stay in the app's own group, which the extension cannot read ([iphone.md](iphone.md#32-the-keys), 3.2).

**pi² Remote is not signed with its profile yet.** `app/remote-helper.sh` signs it ad hoc in a development build and with the Developer ID alone in a release build, so its `keychain-access-groups` entitlement reaches no build: a release build's helper cannot open its Keychain yet, and `app/Sources/pi2-remote/Keychain.swift` stops rather than keep its keys anywhere else. What changes that is #682's report to the orchestrator: a Developer ID provisioning profile for `dev.pi2.app.remote`, `app/build.sh` and `.github/workflows/release.yml` passing it to `app/remote-helper.sh`, which signs the helper with the entitlements and the profile, and `app/check-release-build.mts` allowing exactly that entitlement. Register the App ID now; make the profile when that change lands.

### Setting it up, once

1. **The team id.** In [developer.apple.com](https://developer.apple.com/account) → **Membership**, the **Team ID**: ten capital letters or digits. That is `PI2_TEAM_ID` below.
2. **The App Group.** Certificates, Identifiers & Profiles → **Identifiers** → **App Groups** → **+**, description `pi²`, identifier `group.dev.pi2.ios`, **Continue**, **Register**.
3. **The four App IDs.** **Identifiers** → **+** → **App IDs** → **App**, one at a time, with the bundle identifier from the table above and a name of your own, then the **Capabilities** tab of each and the boxes that table names. For each, **App Groups** → **Configure** → tick `group.dev.pi2.ios`; for `dev.pi2.ios` and `dev.pi2.ios.notifications`, **Keychain Sharing** → **Configure** → **+** → `group.dev.pi2.ios`; for `dev.pi2.ios`, tick **Push Notifications** and **App Attest**, neither of which has anything to configure. **Save** each. An extension's App ID must begin with the app's, which is why they all begin `dev.pi2.ios`.
4. **The certificates and profiles are Xcode's to make.** `scripts/iphone-release` signs with the team's automatic signing (`DEVELOPMENT_TEAM`, `-allowProvisioningUpdates`), so Xcode makes the Apple Distribution certificate and the four App Store profiles the first time it archives, from the App IDs above. Nothing to download by hand.
5. **The App Store Connect record.** [App Store Connect](https://appstoreconnect.apple.com) → **My Apps** → **+** → **New App**: platform **iOS**, name `pi²`, primary language, the bundle ID `dev.pi2.ios`, a SKU of your own (`pi2-ios`), and full access for yourself. Then **App Information → Test Information**: a short description of what the app does (that it pairs with the Mac app, and that the Mac app does the work) and the address people write to, for the TestFlight screen. App Privacy and the listing wait for the App Store ([iphone.md](iphone.md#95-if-it-goes-to-the-app-store), 9.5).
6. **An App Store Connect API key, for the upload.** App Store Connect → **Users and Access** → **Integrations** (App Store Connect API) → **Team Keys** → **+**, a name, the **App Manager** role, **Generate**, then **Download** — Apple lets you download the `.p8` once. Write down its **Key ID** and the **Issuer ID** shown above the list. Keep the file `chmod 600`, never in this repository, and **with the other macOS user of step 1 and not this one**: what `scripts/iphone-release` checks is that no other user of the Mac can read it, which keeps a second macOS user out and nothing more. A program running as the user that file belongs to reads it as that user does — an agent's shell included — and nothing in a script can tell your command from an agent's. Keeping it with the other user is what keeps it from agents; the mode check only makes that user's own copy safe from the rest of the Mac. The key can also make certificates and profiles for the team, since the script signs with `-allowProvisioningUpdates`, so the **App Manager** role is the least it needs, and if that user or Mac is lost, revoke the key there (**Team Keys** → the key → **Revoke**).
7. **The push key.** `docs/relay.md` [step 4](relay.md#4-the-push-key-apns): one topic-specific APNs key for `dev.pi2.ios` for each relay, given to that relay as Workers secrets. It is the relay's, not the app's: the phone's `aps-environment` comes from the profile. **It never goes to GitHub, and its `.p8` is kept off this Mac too**, with that other user or device, as the API key above is: [12.3](iphone.md#123-before-anything-is-built-the-repository-p0) asks for both, and an APNs key can push to `dev.pi2.ios` with nothing else.
8. **The internal tester.** App Store Connect → **Users and Access** → yourself is a member of the team already; TestFlight → **Internal Testing** → **+** next to **Groups**, a name (`Owner`), and **+** next to **Testers** to add yourself. Builds reach internal testers with no review by Apple, and each is testable for 90 days.

### Making a build and sending it

1. **The environment.** As the other macOS user of step 1, in that user's checkout of this repository and in the shell that will run it, the team id and the key, and nothing that prints them:

   ```bash
   export PI2_TEAM_ID=ABCDE12345                 # Membership, step 1
   export PI2_ASC_KEY_ID=ABC1234567              # the key's Key ID, step 6
   export PI2_ASC_ISSUER_ID=…                    # the Issuer ID, step 6: a UUID
   export PI2_ASC_KEY_PATH=~/Keys/AuthKey_ABC1234567.p8   # the file, chmod 600
   ```

   A password manager that sets them for one command is better than exporting them: nothing in the repository, in a workflow or in a shell history should hold them.
2. **Look before you upload.** `scripts/iphone-release --dry-run` checks the project, the entitlements, the identifiers, the key file and the credentials, says what it would archive and upload, and stops before signing and uploading anything. It archives nothing, and it cannot upload.
3. **Upload.** From `main` in that user's checkout, with the working tree committed (it refuses a dirty checkout, since a build nobody can trace is no use in TestFlight; `--allow-dirty` overrides it for a try of your own):

   ```bash
   scripts/iphone-release
   ```

   It archives the `pi2` scheme in the Release configuration for a phone, signs it with the team's automatic signing, and exports the archive straight up to App Store Connect with the API key. `--build` sets the build number (the default is the UTC minute, `YYYYMMDDHHMM`, since TestFlight refuses one it already has for that version) and `--version` the version (the default is the project's `MARKETING_VERSION`). The archive stays in `iphone/build/release`, with the dSYMs Apple's processing may ask for; the export's options plist is made for that one run in a temporary folder, holds no secret, and is removed after it.
4. **Give it to the group.** App Store Connect → TestFlight: the build is **Processing** for a few minutes, then appears on the app's page, with no question about encryption because `ITSAppUsesNonExemptEncryption` is in `iphone/Info.plist` ([9.5](iphone.md#95-if-it-goes-to-the-app-store), item 6). Add it to the internal group; TestFlight on your phone offers it.

**Encryption is your answer to give.** The app declares that it uses non-exempt encryption: its channel is its own composition of CryptoKit's standard algorithms, not only what an operating system's own services do ([9.5](iphone.md#95-if-it-goes-to-the-app-store), item 6). That declaration means App Store Connect's export-compliance questions are yours to answer once, and that a yearly self-classification report may be due; if you judge the use exempt instead, `ITSAppUsesNonExemptEncryption` becomes `false` in `iphone/Info.plist` and nothing else changes.

**Before anyone else tests it.** Nothing puts a build in front of anyone but you yet, and [iphone.md 9.3](iphone.md#93-nothing-app-review-refuses-on-sight) wants a link to a privacy policy and a way to reach pi² **in the app's settings from the first TestFlight build**, so that nothing is added at the end. The Settings screen is P28's and has no row for either yet ([#1072](https://github.com/KellamA/pi2/issues/1072) is the row; #682's report to the orchestrator says why it was left out of it), so the first build, given to you alone, waits for that row or for your decision that it does not. External testing, a public link and the App Store each add what [iphone.md](iphone.md#91-given-out-testflights-internal-testing) 9.1 and [9.5](iphone.md#95-if-it-goes-to-the-app-store) list.

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

This does not tag, publish, draft or use release secrets. Without `SIGN_IDENTITY`, the build is signed ad hoc. The check starts **the Node and engine inside the app**, from `/` with macOS's bare `PATH`, a temporary `PI2_HOME`, its own Keychain service and `PI2_LOGIN_SHELL=off`. It checks the bundle's version, build number, build id and signature, asks `engine.info` and compares its build, entry point and process id, checks that the engine ignores a switch only tests may set (`PI2_DEMO_TOKENS_PER_SECOND`, which it is given) and names it in its log (#720), gets an answer from the scripted demo model without a provider, and stops the engine cleanly. A failure names what was wrong and shows the end of the engine log; the temporary data and processes go away on failure too.

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
