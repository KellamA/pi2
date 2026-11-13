# Releasing

How pi² is built for download, how installed copies update, and what has to be set up once before the first release.

## What a release is

Pushing a tag such as `v0.7.0` runs [.github/workflows/release.yml](../.github/workflows/release.yml). It tests the engine, builds a self-contained app, signs it with a Developer ID, has Apple notarize it, and makes a **draft** GitHub release with three files:

| File | For |
|---|---|
| `pi2-<version>.dmg` | People downloading pi². The app beside a link to Applications; signed, notarized and stapled. |
| `pi2-<version>.zip` | Copies already installed. Sparkle downloads this to update them. |
| `appcast.xml` | The update feed: the newest version, its notes from the changelog, and a signature over the zip. The feed itself is signed too. |

Nothing reaches anyone until you publish the draft. Installed copies read the feed at `https://github.com/KellamA/pi2/releases/latest/download/appcast.xml`, which GitHub serves from the newest **published** release, so drafts and pre-releases are never offered as updates.

Builds are for Apple silicon only: the Node copied into the app is the runner's arm64 build.

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

1. Set the version in `app/VERSION`, and give it a `## <version>` section in `CHANGELOG.md`. That section becomes the release notes and what the update window shows.
2. Merge to `main`.
3. Tag the commit on `main` and push the tag:

   ```bash
   git tag v0.7.0 && git push origin v0.7.0
   ```

4. When the workflow finishes, open the draft release, download the disk image, and try it.
5. Publish the draft. Installed copies see the update the next time they check.

The workflow refuses a tag that does not match `app/VERSION`, a commit that is not on `main`, and a version with no changelog section. The build number is the number of commits on `main`, which is what Sparkle compares, so it only goes up as long as releases come from `main`.

## How updating works in the app

- **Asking first.** Nothing is checked until the person agrees. Sparkle asks on the second launch whether to check automatically; Settings › General › Updates changes the answer, and **pi² › Check for Updates…** checks at any time. A check sends only the app's version and the macOS version.
- **Checking the download.** Sparkle refuses a feed or an archive not signed with the updates key, and checks the new app's code signature against the installed one.
- **The engine.** The engine runs Node and the engine's files from inside the app, and can outlive it. Just before Sparkle replaces the app, pi² stops the engine cleanly. If agents are meant to keep running without the app (Settings › General › In the background), the engine is started again 20 seconds later from the new copy. When the new app opens, it asks the engine which build it belongs to (`engine.info`). If the engine is from another build (left over from before the update, or from a copy of the app that has since moved), the app stops it and starts its own, and points the login item at itself. Runs pick up where they stopped.
- **Sheets.** While a sheet is open (the welcome, the command palette, a confirmation), macOS ignores a request to quit, so "Install and Relaunch" would do nothing. pi² closes sheets just before the update installs and, if the app has not quit two seconds later, closes them again and quits.
- **Development builds** never update themselves and do not check engine builds: they run from the source folder.

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

1. In a throwaway clone, change `CFBundleIdentifier` in `app/build.sh` (for example to `dev.pi2.app.updtest`). In `EngineClient.init`, `setenv` `PI2_HOME` to a short folder of its own and `PI2_KEYCHAIN_SERVICE` to a test service, so they hold even when Sparkle relaunches the app without your environment.
2. Make a throwaway updates key without touching the Keychain:

   ```bash
   node -e 'const {generateKeyPairSync}=require("crypto");const k=generateKeyPairSync("ed25519");console.log(k.privateKey.export({format:"der",type:"pkcs8"}).subarray(-32).toString("base64"));console.log(k.publicKey.export({format:"der",type:"spki"}).subarray(-32).toString("base64"))'
   ```

3. Build the old version with `SPARKLE_PUBLIC_KEY=<public>`, `SPARKLE_FEED_URL=http://127.0.0.1:8737/appcast.xml` and `PI2_BUILD_NUMBER=100`, and copy the app aside. Raise `app/VERSION`, add a changelog section, build again with `PI2_BUILD_NUMBER=101`, then run `SPARKLE_PRIVATE_KEY=<private> DOWNLOAD_URL=http://127.0.0.1:8737 ./release.sh`.
4. Serve `app/build/release` with `python3 -m http.server 8737 --bind 127.0.0.1`, open the old copy, and choose **Check for Updates…**.
