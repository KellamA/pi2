# pi² for iPhone: the contract

This is the contract for epic [#620](https://github.com/KellamA/pi2/issues/620), pi² for iPhone: how a phone is paired with a Mac, how the engine knows a paired phone speaks for the person, how the two reach each other at home and away, what a notification carries, what moves into a package both apps build on, and how all of it is tested with no phone in hand. Every later issue of the epic is built against it, several at once, by agents who read this page and not the conversation in which it was made. Where this page and an issue's text differ, this page has the last word on names and shapes; [section 12](#12-the-later-issues) says who owns each piece that several issues share.

The design it builds is [design/iphone.md](design/iphone.md), with its drawings in [design/iphone-drafts.html](design/iphone-drafts.html). This page does not repeat why the phone exists; it says exactly what. Where the design left something open, this page decides it, and [section 13](#13-decisions-this-contract-made) lists each decision. What only the owner can decide is in [section 2](#2-the-three-decisions-and-where-each-lives) (the three decisions already asked) and [section 14](#14-questions-for-the-owner) (the rest). Nothing in the epic starts until the owner has agreed this page and a second agent has read it for security.

**How to read it.** Read [section 1](#1-words), [section 2](#2-the-three-decisions-and-where-each-lives) and [section 4](#4-who-is-speaking) whatever your issue, then [12.1](#121-who-owns-what-several-issues-share) and the sections your issue's row in [12.2](#122-each-issue) names. Types are written as TypeScript, as `engine/src/state.ts` writes them; times are milliseconds since 1970. Apple's limits are cited in the notes at the end, from Apple's own documentation; a number this page gives without a note is this page's own choice.

## Contents

1. [Words](#1-words)
2. [The three decisions, and where each lives](#2-the-three-decisions-and-where-each-lives)
3. [Pairing](#3-pairing)
4. [Who is speaking](#4-who-is-speaking)
5. [Transport at home](#5-transport-at-home)
6. [Away from home](#6-away-from-home)
7. [Notifications](#7-notifications)
8. [The shared package](#8-the-shared-package)
9. [Who it is for, and how it is given out](#9-who-it-is-for-and-how-it-is-given-out)
10. [Testing with no phone in hand](#10-testing-with-no-phone-in-hand)
11. [What the Mac cannot check](#11-what-the-mac-cannot-check)
12. [The later issues](#12-the-later-issues)
13. [Decisions this contract made](#13-decisions-this-contract-made)
14. [Questions for the owner](#14-questions-for-the-owner)

## 1. Words

- **The phone**: pi² for iPhone, the app. What is said of it holds for any paired device; an iPad later is one more device.
- **The Mac**: the Mac whose engine the phone is paired with. One phone may later be paired with several Macs; this contract builds one, and keeps a Mac's id in everything so that more can be added.
- **The app**: the Mac app, as everywhere in `docs/`.
- **pi² Remote**: a helper program inside the app's bundle that holds the Mac's listener and talks to iCloud ([5.1](#51-which-program-listens)). The engine starts it and is its judge.
- **Device**: a paired phone, as the engine records it ([3.2](#32-the-keys)).
- **Device connection**: a connection to the engine's socket that pi² Remote opened for one device's session, after the device proved itself ([3.4](#34-what-each-side-proves-at-every-connection)).
- **Presence signature**: a signature over one request, made by a key the phone can use only after Face ID ([4.3](#43-face-id-the-presence-signature)).
- **Route**: how a request reached the engine: `home` (the same network, found by Bonjour), `direct` (another address of the Mac's, such as a private network's), or `icloud` (a record in the person's iCloud).
- **Record**: a CloudKit record in the person's own private database, sealed for one reader ([6.2](#62-icloud-the-recommended-answer)).
- **Outbox**: what the phone has written and not yet seen taken by the Mac.

## 2. The three decisions, and where each lives

The owner has three decisions open. This page is written for the recommended answer of each, and keeps each in one section, so that a different answer changes that section and the rows of [12.2](#122-each-issue) it names, not the rest.

| Decision | Written for | Lives in | A different answer changes |
|---|---|---|---|
| 1. How the phone reaches the Mac away from home | Direct wherever the two can reach each other; otherwise the person's own iCloud private database carries notifications, answers and short messages | [Section 6](#6-away-from-home) | 6.2 is replaced by 6.3 or 6.4; P15 to P17 and P19 change as those sections say |
| 2. What the phone may do | The table of [4.2](#42-what-a-device-may-send): what the person does at the Mac, but what needs the Mac's hands or a secret; the riskiest with Face ID; the same at home and away | [4.2](#42-what-a-device-may-send) | The table's last column, and nothing else: the engine reads it as data |
| 3. Who it is for at first | The owner alone, through TestFlight's internal testing, until the security reading of step 6 | [Section 9](#9-who-it-is-for-and-how-it-is-given-out) | Section 9, and P10 |

## 3. Pairing

### 3.1 What the Mac shows and the phone scans

**Settings › Devices › Pair an iPhone** asks the engine for a pairing (`devices.pairStart`, the app's alone) and draws its payload as a QR code. The payload is a URL:

```
pi2://pair?v=1&m=<macId>&n=<Mac's name>&k=<pin>&r=<Mac's record key>&s=<secret>&a=<address:port,…>&e=<expiry>
```

- `macId`: 16 random bytes, base64url, made once when remote access is first turned on, kept in `pi2.devices`.
- `pin`: the SHA-256 of the Mac's TLS key's SubjectPublicKeyInfo, base64url. The phone accepts a TLS connection only from a server whose key has this hash ([5.3](#53-tls-and-mutual-authentication)).
- `r`: the Mac's record key, a P-256 public key (SPKI DER, base64url), which records for the Mac are sealed to ([6.2](#62-icloud-the-recommended-answer)).
- `secret`: 16 random bytes, base64url, made for this pairing alone and never stored outside the engine's memory.
- `a`: the addresses pi² Remote listens on now, so a phone whose Bonjour is slow can still connect.
- `expiry`: seconds since 1970. A pairing is open for five minutes, for one phone, and closes after it pairs, after three wrong proofs, when the sheet closes, or when it expires.

The QR code is shown only in the app's sheet, never written to disk or a log. The payload holds no account, password or long-lived secret: `secret` is good once, for five minutes, and only together with a phone on the Mac's network.

### 3.2 The keys

**On the phone**, made at pairing, in the Secure Enclave unless said otherwise. The Secure Enclave holds only P-256 keys and cannot import one,[^se] which is why every key here is P-256.

| Key | What it does | Where and how it is kept |
|---|---|---|
| **Device key** (signing) | Proves at every connection that this is the paired phone ([3.4](#34-what-each-side-proves-at-every-connection)); signs every request sent through iCloud | Secure Enclave, `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` with `privateKeyUsage`: usable only while the phone is unlocked, never backed up or moved to another phone, and deleted if the passcode is turned off.[^passcode] |
| **Presence key** (signing) | Signs one request after Face ID ([4.3](#43-face-id-the-presence-signature)) | Secure Enclave, as the device key, plus `biometryCurrentSet`: each use asks for Face ID, and the key is invalidated if Face ID is enrolled again.[^biocurrent] None if the person refused Face ID; the requests that need it are then the Mac's alone. |
| **Record key** (key agreement) | Opens records sealed to this phone, in the app and in its notification service extension | P-256 key agreement, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, in a Keychain access group the extension shares, so a notification that arrives while the phone is locked can be opened. In the Secure Enclave if CryptoKit's HPKE takes a Secure Enclave key on the iOS version P8 targets; otherwise a Keychain key. P8 says which. |
| **What the phone keeps of the Mac** | `macId`, the name, `pin`, the Mac's record key, its last addresses | Keychain, `AfterFirstUnlockThisDeviceOnly`, the same access group |

A new presence key (Face ID enrolled again, or Face ID turned on later) is sent to the Mac and used only once the person accepts it on the Mac's Devices page (`devices.acceptPresenceKey`, the app's alone): otherwise whoever knows the passcode could enrol a face and gain Face ID's answers.

**On the Mac**, made by pi² Remote when remote access is first turned on:

| Key | What it does | Where |
|---|---|---|
| **TLS key** | The Mac's identity in TLS; its hash is the `pin` | Keychain, data-protection keychain, in an access group only pi²'s signed code has, so `/usr/bin/security` and an agent's commands cannot read it; with a self-signed certificate made for it ([13](#13-decisions-this-contract-made), decision 6) |
| **Record key** | Opens records the phone seals to the Mac; seals records for the phone, in HPKE's auth mode | The same |

A development build or throwaway copy, which is signed ad hoc and has no access group, keeps both in a file in its own data folder, readable only by the person ([10](#10-testing-with-no-phone-in-hand)); a release build never does.

**The Mac's record of a device**, kept by the engine in a document of its own:

```ts
type Device = {
	id: string; // "dev_" and 16 random bytes, base64url
	name: string; // as the phone gave it ("Alex's iPhone"); the person can rename it on the Mac
	model: string; // "iPhone 17 Pro"
	system: string; // "iOS 27.1", updated at each connection
	signingKey: string; // the device key's public half, SPKI DER, base64
	presenceKey: string | null; // the presence key's public half, or null
	pendingPresenceKey: string | null; // a new one, until the person accepts it on the Mac
	recordKey: string; // the record key's public half
	iCloudUser: string | null; // the CloudKit user record name the phone saw, compared with the Mac's (6.2)
	pairedAt: number;
	lastSeenAt: number | null;
	lastRoute: "home" | "direct" | "icloud" | null;
	revokedAt: number | null; // kept 90 days for the log, then removed
};

type Devices = {
	// the document `pi2.devices`
	macId: string;
	macName: string; // the Mac's computer name when remote access was turned on; the person can change it
	remote: { on: boolean; iCloud: boolean; preview: boolean };
	macKeys: { tls: string; record: string } | null; // public halves, as pi² Remote reported them (remote.hello)
	devices: Device[];
};
```

### 3.3 The pairing exchange

1. The phone scans the code, browses for `_pi2._tcp` with `m=<macId>` ([5.2](#52-finding-the-mac)) and tries the payload's addresses, and opens TLS 1.3 to the first that answers, accepting only the pinned key.
2. Its first line is `{"pair":{"v":1,"proof":…,"device":{…},"signed":…,"signature":…}}`:
   - `device`: name, model, system, the three public keys, and the CloudKit user record name it sees (null without iCloud);
   - `proof`: HMAC-SHA256 of the TLS exporter value with the label `EXPORTER-pi2-pair-v1` (32 bytes)[^exporter], keyed with `secret`: proof that the phone read this code, bound to this very connection;
   - `signed` and `signature`: the JSON text `{"v":1,"kind":"pair","mac":…,"device":…,"binding":<the exporter value>}` and the device key's signature over it, proof that it holds the device key.
3. pi² Remote passes it to the engine (`remote.pairClaim`, with the exporter value it saw). The engine checks that a pairing is open and unexpired, the proof, the signature, and that fewer than five devices are paired; a wrong proof counts against the pairing's three tries.
4. The engine shows the claim in the `devices` event, with six digits worked out from the secret and the exporter value (HMAC-SHA256 with the label `pi2-digits`, the first 32 bits modulo a million). The phone shows the same six digits. The app shows them with the phone's name and **Pair** and **Cancel**.
5. **Pair** sends `devices.pairConfirm { accept: true }`, the app's alone. The engine stores the device and answers the phone through pi² Remote: `{"paired":{"device":…,"mac":…,"name":…,"iCloudUser":<the Mac's>,"addresses":[…]}}`. The pairing closes.
6. The phone keeps what [3.2](#32-the-keys) says, asks for notifications and then for Face ID (each with a line on what it is for), and connects as any paired phone does ([3.4](#34-what-each-side-proves-at-every-connection)). If the two iCloud users differ, the phone and the Devices page both say that iCloud cannot carry anything between them, and why.

Pairing is only ever started and confirmed on the Mac, in the app. No request a device can send starts, confirms or widens a pairing ([4.2](#42-what-a-device-may-send)).

### 3.4 What each side proves at every connection

- **The Mac** proves it holds the TLS key whose hash the phone pinned: TLS 1.3 does that in its handshake, and the phone accepts no other key and no certificate authority.
- **The phone** proves it holds the device key of a paired, unrevoked device, over this connection: pi² Remote opens a new connection to the engine's socket for the session and asks `remote.attachBegin`, which answers a 32-byte challenge; it passes the challenge to the phone, which answers `{"attach":{"signed":…,"signature":…}}` with `signed` the JSON text `{"v":1,"kind":"attach","mac":…,"device":…,"binding":<exporter, label EXPORTER-pi2-attach-v1>,"challenge":…,"at":…}`; pi² Remote sends it with the exporter value it saw as `remote.attach`. The engine checks the device, the signature, the challenge, the binding and that `at` is within two minutes, and from then on that engine connection is the device's ([4.1](#41-from-the-app-or-from-a-paired-device)). pi² Remote then only passes lines both ways.
- **pi² Remote** proves to the engine that it is pi² Remote: the engine asks PeerKit (`pi2-peer`, [architecture.md](architecture.md#who-may-answer-for-the-person)) of every connection that sends a `remote.*` request, against the designated requirement of the helper inside the app's bundle, as it does for the app. Only such a connection may send `remote.*` requests ([4.1](#41-from-the-app-or-from-a-paired-device)).

A connection that has neither paired nor attached within ten seconds of TLS is closed; so is one whose first line is not `pair` or `attach`. Outside an open pairing, `pair` is answered "Pairing is not open on this Mac" and the connection closed.

### 3.5 How many devices

At most five devices are paired at once (question 7 in [section 14](#14-questions-for-the-owner)). Each has its own keys, record, zone in iCloud and log; nothing one device does is visible to another but through the engine's state, as for two app windows.

### 3.6 Revoking, and a lost phone

**Revoke** on the Devices page (`devices.revoke`, the app's alone):

1. sets `revokedAt` and forgets the device's keys in the same commit: from then on no attach, presence signature or record of it is taken;
2. closes its device connections at once;
3. has pi² Remote delete the device's zone in iCloud, with every record sealed to it, and write nothing more for it;
4. keeps its log for 90 days.

Turning **Reach from an iPhone** off closes the listener and stops writing to iCloud; devices stay paired and can do nothing until it is on again.

**What a revoked or lost phone can still read from its own storage**, and how little that is:

- **Its cache**: the last state the phone saw (projects, the Dashboard, Needs you, the board's lists) and the last 300 entries of at most 20 conversations opened in the last seven days, with no attachments but those shown in them. It is kept with `NSFileProtectionComplete`, readable only while the phone is unlocked. It is wiped when the phone learns it was revoked (any answer from the Mac says so), after 30 days without hearing from the Mac, and when the app is deleted.
- **The widget's file**: counts and names only (how many need the person, who is working where, today's spending), readable while locked, so a widget can be drawn.
- **Notifications already delivered**: iOS keeps them in Notification Center until they are cleared; each holds at most what [section 7](#7-notifications) allows.
- **Its own Outbox**: what the person wrote and had not seen taken.
- **Nothing in iCloud**: records for it are deleted at revocation, and records sealed for another device cannot be opened with its keys.

A lost phone that is not yet revoked can do what the table of [4.2](#42-what-a-device-may-send) allows to whoever holds it unlocked; its Face ID answers need its owner's face. Revoking is the remedy, and the Devices page shows when each device was last seen and from where, to tell.

## 4. Who is speaking

### 4.1 From the app, or from a paired device

Today the engine takes an answer, or a change to what the person set, only from a connection whose other end is the app, as macOS's code signing says (`answers.ts`, [architecture.md](architecture.md#who-may-answer-for-the-person), #504, #513). This epic widens the rule to: **from the app, or from a paired device, as the device's table allows**.

- Every connection has, besides `testCopy`, an optional `device: string` (the `Client` type in `main.ts`), set only by `remote.attach` on a connection PeerKit took for pi² Remote. A device connection is never the app's: `connection.mayAnswer` answers `false` on it, with why.
- **Every request on a device connection is checked against the device's table, whatever its class**: `deviceMay(method, params)` in `answers.ts` answers `"yes"`, `"face"` or `"no"`. `"no"` is refused ("This can be done only on the Mac, in the pi² app."); `"face"` is refused without a valid presence signature for that request ([4.3](#43-face-id-the-presence-signature)) ("This needs Face ID on your iPhone."); `"yes"` is handled as from the app. The refusal comes before the handler runs, as today's does.
- A fourth list, `FOR_THE_HELPER`, holds the `remote.*` requests, taken only from a connection PeerKit took for pi² Remote.
- The check at start-up widens: every handler belongs to exactly one of the three request classes as today, and to exactly one of the device lists (`FROM_A_DEVICE`, `WITH_FACE_ID`, `MAC_ONLY`), or to `FOR_THE_HELPER`; the engine will not open its socket otherwise. A request added later is placed by the issue that adds it, which tests its refusal from a device as `engine/test/answers.ts` tests the app's.
- Requests that are partly a device's, like `inbox.decide` (once or deny, yes; always or a rule, Face ID), have a function in the list, as `FOR_THE_PERSON` has.

### 4.2 What a device may send

This table is decision 2's one place. It is the content of the three device lists in `answers.ts` (P5). "Face ID" means a presence signature is required ([4.3](#43-face-id-the-presence-signature)). "iCloud" marks the requests that may also travel as a record ([6.2](#62-icloud-the-recommended-answer)); every other request needs a direct connection.

| Requests | From a device | iCloud |
|---|---|---|
| **Reading**: `engine.info`, `engine.lag`, `conversation.open`, `.older`, `.close`, `conversations.shown`, `search`, `submission.get`, `background.output`, `changes.list`, `github.refresh`, `github.diff`, `github.unknown`, `needs.list`, `projects.list`, `work.list`, `worktree.suggest`, `branches.refresh`, `limits.refresh`, `settings.getCompaction`, `local.status`, `conversation.image`, `conversation.export` | yes | |
| **Messages, starts and stops**: `submit`, `continue`, `abort`, `withdraw`, `conversation.create` and `chat.continueWithAgent` without `confirmLimit` or an explicit folder, `conversation.compact`, `.reset`, `.edit`, `.version`, `.retry` without a model, `background.stop`, `wakes.cancel`, `wakes.resume`, `reports.wake`, `schedules.runNow` without `confirmLimit` | yes | `submit` (text only, at most 4,000 characters) and `abort` |
| **Names, pins, notes**: `conversation.rename`, `.pin`, `.dismissCompactionError`, `projects.rename`, `memory.add`, `.edit`, `.delete` | yes | |
| **Answers**: `inbox.decide` once or deny, `inbox.answer`, `needs.answer` but the two below | yes | yes |
| **Answers that widen**: `inbox.decide` always, or with a rule; `needs.answer` allowing a reach request; any request with `confirmLimit` (starting past a limit, a limit card's Start Anyway); `agents.allowEverything` with `on: true` | **Face ID** | yes |
| **Changes that widen or cannot be undone**: `agents.save`, `.duplicate`, `.delete`, `.restore`, `.updateFromTemplate`, `conversation.configure`, `conversation.delete`, `memory.setEnabled`, `rules.add`, `schedules.save`, `usage.setBudget`, `changes.undo`, `projects.addAgent`, `projects.setOrchestrator`, `projects.set`, `projects.delete`, `projects.rules.edit`, `.move`, `.remove`, `github.attach`, `github.merge`, `worktree.remove` | **Face ID** | |
| **Changes that narrow, or are the person's ordinary acts**: `agents.allowEverything` off, `conversation.carryOn`, `.fork`, `.retry` with a model, `.archive`, `.unarchive`, `chat.set`, `rules.remove`, `schedules.delete`, `coauthor.set`, `projects.create` (with a folder the Mac offers), `.archive`, `.unarchive`, `.restoreConversation`, `.startFresh`, `.watch`, `projects.rules.add`, `work.create`, `work.act` without `confirmLimit`, `worktree.create`, `github.detach`, `github.sendBack`, `github.settle`, `settings.setCompaction`, `settings.setAutoArchive`, `settings.setAwake`, `recovery.dismiss`, `limits.dismiss` | yes | |
| **The Mac's alone**: secrets and sign-ins (`variables.*`, `providers.*`, `auth.*`, `endpoints.*`), the models that spend on pictures (`pictures.setModel`, `look.setModel`), programs started on the Mac (`mcp.*`, and `local.*` but `local.status`), the app's host roles (`computer.*`, `browser.*`), the Mac's upkeep (`backup.create`, `priority.set`, `settings.finishOnboarding`, `projects.setPreview`, `projects.carryOver`, `projects.retrySecrets`), `chat.continueWithAgent` with an explicit folder, `test-copy.*`, and every `devices.*` request but `devices.self` | no | |

A handler the engine has that this table does not name is placed by P5 in `MAC_ONLY`, and P5's pull request lists it for the owner. New requests this epic adds that a device may send: `devices.self` (its own record and log, yes), `projects.folders` (the folders the Mac offers for a new project, yes, P24), `files.preview` (a text file under a conversation's folder, at most 256 KB, yes, P24).

Under a different answer to decision 2, only the middle column changes. For example "answers only, away from the Mac": every row but Reading and Answers becomes "no" when the route is not `home`, which the engine knows from the connection.

### 4.3 Face ID: the presence signature

A request that needs Face ID carries, beside `id`, `method` and `params`, a `presence` object:

```json
{"id": 41, "method": "github.merge", "params": {"projectId": "p_…", "number": 619},
 "presence": {"signed": "{\"v\":1,\"kind\":\"presence\",\"mac\":\"…\",\"device\":\"dev_…\",\"method\":\"github.merge\",\"params\":{…},\"nonce\":\"…\",\"at\":1764150000000}",
              "signature": "<base64 DER ECDSA P-256 SHA-256>"}}
```

- The phone makes it only after Face ID: signing with the presence key is what asks for Face ID ([3.2](#32-the-keys)), so there is no "Face ID passed" flag to forge; the signature is the proof.
- `signed` is the exact JSON text that was signed, so neither side has to put JSON in a canonical form. The engine parses it and checks that its `method` and `params` are deep-equal to the request's, its `device` is the connection's, `mac` is this Mac's, and the signature verifies with the device's presence key (`node:crypto`).
- **Freshness.** On a device connection, `nonce` is `<the attach challenge>:<n>`, with `n` rising with each presence signature in the session, and `at` within two minutes. Through iCloud, `nonce` is the record's name and `at` within 24 hours ([6.2](#62-icloud-the-recommended-answer)). The engine keeps the nonces it took for 48 hours and takes none twice, after a restart too (in `pi2.devices`' companion document, `pi2.deviceNonces`).
- A request with a presence signature it does not need is taken as it is; the signature is logged.

### 4.4 The devices' log

Every request a device sends that is not in the Reading row of [4.2](#42-what-a-device-may-send), taken or refused, is logged in `pi2.deviceLog`:

```ts
type DeviceLogEntry = {
	at: number;
	device: string;
	route: "home" | "direct" | "icloud";
	method: string;
	summary: string; // "Merged #617 “Sidebar badges” (pi2)"; made by `summarize(method, params)` in devices.ts
	presence: boolean; // a valid presence signature came with it
	outcome: "done" | "refused" | "failed";
	why?: string; // the refusal's or the error's message
};
```

Entries are kept 90 days, at most 10,000 (the oldest go first). The Devices page shows them by device (`devices.log { device, before? }`, the app's), and the phone its own (`devices.self`). A method with no line in `summarize` is logged with its name and the project or conversation its parameters name; the issue that lets a device send a new request adds its line.

## 5. Transport at home

### 5.1 Which program listens

The listener is held by **pi² Remote**, a small app bundle inside the app's (`Contents/Helpers/pi² Remote.app`, bundle id `dev.pi2.app.remote`, no Dock icon), written in Swift (P6). **The engine starts it**, as it starts `pi2-peer`, whenever remote access is on and a device is paired or a pairing is open; it starts it again if it dies (waiting twice as long after each failure, up to a minute), and stops it when remote access goes off or the engine stops. So the listener lives exactly as long as the engine, which outlives the app's window (the login item starts the engine with no app at all).

Why a helper, and not the engine itself:

- **Node cannot do what is needed.** Bonjour advertising, TLS with a key in the data-protection Keychain, the TLS exporter, CloudKit and Apple's push service are Apple frameworks; the engine would need a helper for half of it anyway.
- **iCloud needs a bundle.** CloudKit and push notifications need entitlements given by a provisioning profile, which a Developer ID-signed Mac app may have[^devid] but a bare executable or a Node process cannot carry.
- **macOS's Local Network privilege follows code signing.** Bonjour on macOS needs it, and a launchd agent (the engine's login item) is not exempt; macOS asks once, naming the responsible app.[^lnp] A signed bundle of pi²'s with its own usage description is asked for once, by name, and the person's answer stays.
- **The Mac's private keys stay out of agents' reach.** Items the engine reads go through `/usr/bin/security`, which any command of the person's can run ([architecture.md](architecture.md#who-may-answer-for-the-person)); the data-protection keychain's access group admits only code signed with pi²'s entitlement.

And not the app: the app may be quit while the engine works. **The engine stays the judge**: pi² Remote holds keys and passes lines, and every rule of [section 4](#4-who-is-speaking) is checked in the engine. A fault in pi² Remote can drop or delay a line; it cannot make the engine take a request the device's table refuses, nor a Face ID request without the device's own signature.

**When it asks macOS for anything.** Turning **Reach from an iPhone** on in a release build makes pi² Remote advertise on Bonjour, which asks for the Local Network privilege once; the Devices page says so before the switch is turned on. A development build or throwaway copy never advertises and listens on the loopback interface only ([10](#10-testing-with-no-phone-in-hand)), so it never asks. If the macOS firewall is on, it may also ask whether pi² Remote may accept incoming connections: P6 finds out, on the owner's Mac and with the owner's word, what a Developer ID-signed helper is asked, and writes it here.

### 5.2 Finding the Mac

- pi² Remote advertises `_pi2._tcp` with the Mac's name as the instance name and a TXT record `v=1`, `m=<macId>`. The port is chosen by the system and advertised; it is also kept in `pi2.devices`' companion state for the phone's address list.
- The phone lists `_pi2._tcp` in `NSBonjourServices` and has an `NSLocalNetworkUsageDescription`; browsing asks the phone's owner once for Local Network.[^lnp] An app in the background with the privilege undetermined is denied without being asked,[^lnp] so the phone asks while in the foreground, during pairing.
- The phone connects to the instance whose `m` is its Mac's, and also tries the addresses it last heard of ([6.1](#61-direct-where-the-two-can-reach-each-other)), at the same time; the first to complete TLS with the pinned key wins.

### 5.3 TLS and mutual authentication

**TLS 1.3, with the Mac's key pinned and the phone's key proven inside the session by a signature over the TLS exporter value**, which binds the proof to that one connection (the channel binding of RFC 9266, with TLS 1.3's exporter[^exporter]). Both ends use Network framework. There is no certificate authority, no password and no home-made cryptography: the parts are TLS 1.3, ECDSA P-256 with SHA-256, HMAC-SHA256 and, for records, HPKE (RFC 9180).

- The Mac's certificate is a self-signed one for its TLS key, made once by pi² Remote. The phone checks only the key's hash against the `pin`, never the certificate's names or dates.
- The phone does not present a certificate: its proof is the attach signature of [3.4](#34-what-each-side-proves-at-every-connection), so its key never has to leave the Secure Enclave in a certificate.
- TLS 1.2 and earlier are refused; session resumption is allowed (it resumes the pinned server's session), and every resumed session attaches again with a new challenge.

### 5.4 The messages

**The engine's own requests and events, carried as they are**: one JSON object per line, in both directions, as on the socket ([architecture.md](architecture.md#how-they-talk)). The reason: the shared package's client already speaks them ([section 8](#8-the-shared-package)), so the phone gets every request and event as the Mac app has it, and nothing has to be kept in step with a second protocol, which is the drift the epic warns of. What a phone may send is limited where it counts, in the engine ([4.2](#42-what-a-device-may-send)); what it is sent, in the engine too ([5.5](#55-what-is-never-sent-to-a-phone)).

On top of them, only:

- the first lines of a session, before the engine's: `pair` or `challenge` and `attach`, answered by `paired` or `attached` ([3.3](#33-the-pairing-exchange), [3.4](#34-what-each-side-proves-at-every-connection));
- `presence` beside a request ([4.3](#43-face-id-the-presence-signature));
- a `device` event, sent to a device connection after the greeting and whenever its record changes: `{ event: "device", id, name, mac: { id, name }, routes: { iCloud: boolean, addresses: string[] }, revoked: boolean }`. A revoked device is sent `revoked: true` and closed.

The greeting on a device connection is the app's ([projects.md](projects.md#44-what-an-app-is-sent-on-connecting)), less [5.5](#55-what-is-never-sent-to-a-phone)'s events, then `device`.

### 5.5 What is never sent to a phone

- **Events**: `computer`, `browser`, `auth`, `local`, `local.progress` and `mcp` are not sent on a device connection (they are the app's host roles, sign-ins and the Mac's upkeep).
- **Secrets**: no event or answer carries a provider's key, a sign-in's token, an agent's variable's value or an MCP server's variables today, and none may. P5 adds a test that runs a demo session with known secrets set and fails if any of their values appears in a line sent to a device connection.
- **The test copy's key**, and anything from `test-copy.*`.
- **Files outside what a conversation shows**, but through `files.preview`: a text file under the conversation's own folder, at most 256 KB, refused for anything that is not UTF-8 text or that lies outside the folder after links are followed (P24).

What *is* sent: conversations as their transcripts hold them, which include what agents read and ran. That is the product. It travels only inside the TLS session ([5.3](#53-tls-and-mutual-authentication)) and is never written to iCloud.

### 5.6 Resuming after the phone slept

The phone holds a connection only while it is in the foreground, and for the short time iOS gives it after.[^bgtime] Coming back:

1. it connects and attaches again ([3.4](#34-what-each-side-proves-at-every-connection)), with a new challenge;
2. the engine sends the greeting, as to an app that reconnects after the engine restarted, and the phone's client replaces its state with it;
3. the phone asks again for the conversations it has open (`conversation.open` with `newestFirst`), as the Mac app does on reconnecting;
4. a message whose answer never came is sent again with the same request id, and the engine finds the submission it may already have taken, as the Mac app's `outgoing` does ([architecture.md](architecture.md#keeping-the-app-quick-while-agents-work)).

The Outbox ([section 6](#6-away-from-home)) is sent before anything new.

### 5.7 Battery and data

- No connection is kept in the background, and the phone never polls. It runs in the background only when iOS wakes it: for a notification's action, a push, or a background refresh iOS schedules.
- The engine sends `activity` to a device connection at most once a second (to the app, four times), and `conversation` events only for conversations the phone has open, as for the app.
- A greeting is the size of the person's library and projects; P30 measures it, and a request for only what changed since a version is left to an issue of its own if it matters.
- P30 measures a day's battery and data for an ordinary day (ten notifications an hour answered from the notification, the app open half an hour); this page promises no number.

## 6. Away from home

This section is decision 1's one place. 6.1 and 6.2 are the recommended answer; 6.3 and 6.4 say what changes for the other two.

### 6.1 Direct, where the two can reach each other

pi² Remote listens on every interface while remote access is on (in a release build). The phone tries, at once: the Bonjour instance on the network it is on; the addresses the Mac last gave it (in `paired`, the `device` event and the `State` record), ordered local network first, then the rest, such as a private network's (Tailscale and the like, which needs nothing from pi²). Each try has four seconds; the first to finish TLS with the pinned key wins, and its route is `home` (found by Bonjour) or `direct`. Being reachable from the internet at large is not a goal: a listener reached from anywhere only ever answers a pinned TLS handshake and an attach it can check, and closes anything else after ten seconds.

### 6.2 iCloud, the recommended answer

When no direct route works, **the person's own iCloud private database** carries what matters, and only that: notifications of what needs the person, their answers, short messages and stops, and a small summary of how things stand. Nothing passes through a server of pi²'s.

**Which program.** pi² Remote, the only program with the CloudKit and push entitlements ([5.1](#51-which-program-listens)). The engine tells it what to write (`remote.cloudOut` events, sent only to pi² Remote's control connection) and hands it nothing to decide; pi² Remote hands each request it reads back to the engine as `remote.cloudIn`, which the engine checks as it checks a device connection's, with the route `icloud`. The Mac must be signed in to iCloud with the same Apple Account as the phone; pairing compares the two CloudKit user record names ([3.3](#33-the-pairing-exchange)), and the route is shown as unavailable, saying why, when they differ or the Mac is signed out.

**Where.** A container `iCloud.dev.pi2.remote` (P10), its private database, one custom zone for each pair of Mac and device, `pi2-<macId>-<deviceId>`. Custom zones because a database subscription does not see the private database's default zone,[^dbsub] and one zone per device so that revoking deletes everything for that device at once and a phone subscribes only to its own. Each phone saves record zone subscriptions on its zone,[^zonesub] one for each record type that should show a notification, with its category; the Mac saves a silent one for `Answer` and `Message`. Subscriptions are made in CloudKit's development environment and promoted to production (P10).[^sub]

**What a record holds.** Every record has exactly two fields, `box` (the sealed content) and `enc` (HPKE's encapsulated key), both written through CloudKit's `encryptedValues`, so iCloud's own encryption applies to them as well;[^ckenc] the record's type, zone and name are all iCloud's own fields show, and they say only that something of that type was written for that device at that time.

| Type | Written by | Content once opened (JSON) | Notification |
|---|---|---|---|
| `NeedApproval`, `NeedQuestion`, `NeedDecision`, `NeedReach`, `NeedRule`, `NeedLimit` | the Mac, one per device, as the need appears | `{ v, mac, need, kind, projectId, project, agent, title, body, createdAt, expires }`, the text of [section 7](#7-notifications) | Yes, its kind's category |
| `Notice` | the Mac | `{ v, mac, kind: "limit" \| "answered", title, body, ref }`: a limit reached or carried on (as the Mac notifies today), and an orchestrator's answer the person asked to be told of | Yes, no buttons |
| `Gone` | the Mac | `{ v, needs: [ids] }`: answered or withdrawn, so the phone takes those notifications away | Silent |
| `State` | the Mac, at most every five minutes while anything in it changes, and as the Mac goes to sleep | `{ v, at, asleep, addresses, projects: [{ id, name, needs, working, idle }], needs: number, spendToday, planWeek }`: counts and names, nothing an agent wrote | None (read when the app opens, by widgets, and after any push) |
| `Receipt` | the Mac | `{ v, record, outcome: "done" \| "refused", why? }`: what became of an `Answer` or a `Message` | Silent; one that refused shows as a `Notice` |
| `Answer`, `Message` | the phone | `{ v, request: { method, params }, signed, signature, presence? }`, where `signed` is `{ v, kind: "request", mac, device, method, params, nonce: <record name>, at }` signed by the device key, and `presence` as [4.3](#43-face-id-the-presence-signature) with the same nonce | None |

`Answer` carries only the "iCloud" rows of [4.2](#42-what-a-device-may-send) that answer something; `Message` only `submit` (text, at most 4,000 characters) and `abort`. The engine refuses anything else that arrives this way, and logs it.

**How it is sealed, beyond iCloud's own.** HPKE (RFC 9180), in its authenticated mode, with the suite DHKEM(P-256, HKDF-SHA256), HKDF-SHA256 and AES-256-GCM, as CryptoKit provides it:[^hpke] the Mac seals to the device's record key and authenticates with its own; the phone seals to the Mac's and authenticates with its own. The HPKE `info` is `pi2-record-v1`, the record's type, its zone and its name, so a record cannot be moved to another place or type and still open. A request in an `Answer` or `Message` is signed by the device key besides, which only an unlocked phone can use ([3.2](#32-the-keys)), and by the presence key where the table asks for Face ID. Neither Apple, nor anyone who gets into the iCloud account, nor another device of the person's, can read a record or make one the Mac would take.

**How old a record may be.**

- A `Need…` record expires 24 hours after it is written: after that the phone shows it as stale and its buttons open the app. The Mac deletes it, and writes `Gone`, as soon as the need is answered or withdrawn.
- An `Answer` or `Message` is taken if its `at` is no more than 24 hours old when the engine reads it, its nonce is new, and (for an answer) the item still waits. Otherwise a `Receipt` says why ("This is no longer waiting: it was answered or withdrawn." or "Not sent: more than a day passed before your Mac saw it.") and the Outbox shows it.
- The Mac deletes each `Answer` and `Message` once it has written its `Receipt`; the phone deletes `Receipt`s and `Gone`s once read. A zone holds a few dozen small records at most.
- Clocks: the engine compares `at` with its own clock, and allows five minutes of difference besides.

**When the Mac is asleep.** Nothing runs on a sleeping Mac: no agent works, so no new need appears, and nothing is read from iCloud. As it goes to sleep, pi² Remote writes a last `State` with `asleep: true`, if macOS gives it the time. The phone shows that state, dated ("Mac asleep · last seen 23:10"), and its Outbox records wait in iCloud. When the Mac wakes and the engine is running, pi² Remote fetches every change since its last token (a push to it may have been missed or merged), hands the requests to the engine in the order of their `at`, and writes their receipts. pi² does not try to wake a sleeping Mac.

**What iCloud does not promise.** iCloud merges pushes and may leave data out of them,[^dbsub] and silent pushes are low priority, not guaranteed, and throttled past two or three an hour.[^bgpush] So: every push, of any kind, makes its receiver fetch all changes since its last token; the notification service extension shows what is new ("Forge needs approval, and 2 more"); the Mac also fetches every minute while a device is paired, any need waits, and no direct connection is open; and the phone fetches whenever it comes to the foreground. A notification is a hint to look, never the only copy.

**Notifications always come this way**, at home too: with the app closed there is no connection, and only a push from Apple wakes a phone.

### 6.3 If the answer is "direct only"

- Nothing is written to iCloud; pi² Remote has no CloudKit or push entitlement; P15 and P16 are not built, and the `remote.cloud*` requests and events not added.
- **No notifications while the app is closed**: the Mac has no way to wake the phone. The app shows local notifications only while iOS lets it run in the background, which is seconds.
- Away from home the phone works only over a private network that reaches the Mac (6.1); otherwise it shows its last copy and keeps the Outbox until it is back.
- Widgets and the Live Activity change only while the app runs.

### 6.4 If the answer is "a relay pi² runs"

- A server pi² operates holds the developer's push key and a rendezvous: the Mac's pi² Remote and the phone each connect out to it over TLS, and it passes frames between them, sealed end to end with the HPKE keys of [3.2](#32-the-keys) (the relay sees which device, how much and when, never what). Pushes go from it through Apple's push service, with `mutable-content` and a sealed payload, opened by the same notification service extension.
- It can update a Live Activity while the app is closed, which only a holder of the push key can,[^lapush] and it works when the two use different Apple Accounts.
- It costs a server, its upkeep and someone answerable for it, and a privacy policy that says what the relay sees. A new issue builds the relay; P15 and P16 become its two ends in place of iCloud; P25 gains push updates.

## 7. Notifications

**What triggers one.**

- A new item in Needs you (with the projects preview on; the Inbox's items with it off), one notification per item, for each paired device with iCloud on.
- A provider's limit reached, or work carrying on past it, as the Mac notifies today (`Notifier.limitNotices`).
- An orchestrator's finished answer, only for a message the person sent from the phone with **Tell me when it answers** on.

Nothing else in this epic. The phone's own setting turns each of the three off.

**What its text may contain.**

- Title: the agent's name and the kind ("Forge needs approval", "Scribe has a question", "The orchestrator asks for more reach", "Forge proposes a rule", "Forge is held back by a limit"), as the Mac's `Notifier.needsYou` says it.
- Body: the project's name and the card's short line (`NeedItem.short`, the tool and its call's summary for an approval), at most 180 characters, after the engine has replaced every secret it knows that appears in it (agents' variables' values, providers' keys and tokens, MCP servers' variables) with "•••".
- Never: a command's output, a file's contents, a diff, an attachment, or any transcript text beyond the card's own short line.
- iOS shows the body on the Lock Screen only as the person's notification previews setting allows; the phone suggests "When Unlocked" during pairing, and does not require it.

**Its actions, by kind.** Every action is `authenticationRequired`, which makes iOS ask for the phone to be unlocked first:[^auth] the device key, which signs every answer, is usable only then ([3.2](#32-the-keys)). Actions marked *opens* are `foreground`: Face ID cannot be asked for in the background, so they open the app on the card, which asks for it there.[^fg]

| Kind | Category | Actions |
|---|---|---|
| Approval | `pi2.approval` | **Allow once**, **Deny** (destructive), **Open** (*opens*; Always Allow and rules are in the app, with Face ID) |
| Question | `pi2.question` | **Reply** (a text input action), **Open** (*opens*) |
| Decision | `pi2.decision` | **Open** (*opens*; categories are fixed when the app starts, so a decision's own choices cannot be buttons) |
| More reach | `pi2.reach` | **Allow…** (*opens*, Face ID), **Refuse** |
| Proposed rule | `pi2.rule` | **Accept**, **Refuse**, **Open** (*opens*, to edit) |
| Limit | `pi2.limit` | **Start anyway…** (*opens*, Face ID), **Wait** |
| Notice | `pi2.notice` | none |

**What the phone does in the background to deliver an answer.** iOS starts the app in the background with the action;[^actions] the app:

1. makes the request and signs it with the device key, and puts it in the Outbox;
2. asks iOS for more time to finish (`beginBackgroundTask`);[^bgtime]
3. tries a direct connection for four seconds; if one attaches, sends the request over it and waits for the answer;
4. otherwise saves it as an `Answer` record and stops there: the `Receipt` comes later;
5. takes the notification away, and leaves the Outbox entry until the Mac's answer or receipt says what became of it. If the request could not even be saved before iOS ended the app's time, the next time the app runs it sends it, and a local notification tells the person once: "Your answer to Forge is not sent yet. pi² will send it when it can reach your Mac."

A notification whose need was answered elsewhere is taken away when the phone reads the `Gone` record (or the `needs` event on a live connection); a button pressed on one not yet taken away is answered "This is no longer waiting".

**The notification service extension** (P16) opens the record a push points to, within the thirty seconds or so iOS allows it,[^nse] and replaces the push's generic text ("pi² needs you", which CloudKit sends with `mutable-content` set) with the title and body, and the category with its kind's. If it cannot open the record in time, the generic text stays.

## 8. The shared package

What the Mac app knows of the engine moves into targets of `app/Package.swift` that build for macOS and iOS (the package's platforms gain `.iOS(.v18)`), and both apps build on them. In this order, each a pull request that moves before it changes:

| Order | Target | What moves into it | Issue |
|---|---|---|---|
| 1 | `PiModels` | `Models.swift`'s types (`JSONValue`, `ConversationSummary`, `Item`, `AgentProfile`, `InboxItem`, `ActivityRun`, `UsageSummary`, `OpenConversation`, `EngineError` and the rest), the projects' models (`ProjectRow`, `NeedItem` and the types beside them), `Formats`, and `TranscriptFeed`, which depends on the models alone | P2 |
| 2 | `EngineKit` | The client without AppKit: requests and answers, `call`, events read into observable stores (`update`, the per-event decoding of `EngineClient.handle`), `OpenConversation` handling, `outgoing` and its retry, and an `EngineTransport` protocol with the Unix socket as the Mac's transport (`EngineSocket.swift`) | P3 |
| 3 | `TranscriptKit` | Split: the page's loading and its messages (shared), the AppKit view and the page loaded ahead (Mac), a UIKit view (iPhone); `app/Web/transcript` gains rules for a narrow screen and touch, with nothing changed at the Mac's widths | P4 |
| 4 | `RemoteKit` | The wire formats both pi² Remote and the phone use: the pairing payload, `pair`, `attach`, `presence`, the records' content and sealing, the notification kinds and categories | P6 |

**Stays Mac-only**: starting and watching the engine (`EngineSpawn`, `EngineTrouble`, `LoginItemKit`), the app's host roles (`ComputerKit`, `BrowserKit` and their sessions), `PaneKit`, `WindowKit`, `FileLinkKit`, `ComposeKit`, `PeerKit`, `Notifier`, Sparkle, and every view. `EngineClient` stays as the Mac's object, holding an `EngineKit` session and what only the Mac does with it.

**How the Mac app's behaviour is proven unchanged.**

1. **Moves first.** A pull request that moves code changes nothing inside what it moves but `public` and imports; the reviewer reads it with `git diff -M --color-moved`, and behaviour changes come in a later pull request.
2. **A recorded session, replayed** (`pi2-client-check`, P2): the events a throwaway copy's engine sent while `scripts/test-copy fill --project` built two demo projects and their conversations, recorded once into a fixture, are fed to the client; every property the views read is written out and compared with a file made from the client as it was before P2. P3 and P4 run it unchanged; any difference fails.
3. **The checks that exist** (`pi2-transcript-check`, `pi2-layout-check`, `pi2-window-check`, `pi2-compose-check`, `pi2-file-link-check`, `pi2-computer-check`) pass as before.
4. **The same pictures.** P3 and P4 picture a throwaway copy's hub, Dashboard and a long conversation before and after, in both appearances, and say what differs (nothing should).

## 9. Who it is for, and how it is given out

This section is decision 3's one place. Under the recommended answer:

- **The owner alone**, through TestFlight's internal testing, until step 6's security reading is done and the owner says otherwise.
- **Identifiers** (P10): the iPhone app `dev.pi2.ios`, its notification service extension `dev.pi2.ios.notifications`, widgets `dev.pi2.ios.widgets`, share extension `dev.pi2.ios.share`; pi² Remote `dev.pi2.app.remote`; the CloudKit container `iCloud.dev.pi2.remote`. Release builds of the Mac app carry pi² Remote with its provisioning profile from P10 on.
- **Behind a preview switch on the Mac**: Settings › Devices shows only **iPhone (preview)** until the owner turns it on (`remote.preview` in `pi2.devices`); with it off, the engine starts no helper and refuses every `devices.*` request but turning it on.
- **Builds**: a script (`scripts/iphone-release`, P10) archives and uploads to TestFlight with `xcodebuild` and Apple's own tools; no third-party build tools.

If the answer is a wider TestFlight group, P10 adds Beta App Review's requirements (a description, a contact, how to try it with no Mac, which reviewers do not have). If it is the App Store, P10 adds the privacy details (no data collected by pi²; iCloud is the person's), App Review's notes on a companion app, and the preview switch goes.

## 10. Testing with no phone in hand

**The simulator against a throwaway copy's engine.**

- `scripts/test-copy start <suffix> --remote` (P9) starts a copy whose engine starts pi² Remote in its **loopback mode**: it listens on 127.0.0.1 only, on a port it writes into the copy's data folder, advertises nothing on Bonjour, uses no iCloud and registers for no push, and keeps its keys in a file in the copy's data folder. Loopback is not a local network, so nothing asks macOS for the Local Network privilege,[^lnp] and the copy's own rules ([CONTRIBUTING.md](../CONTRIBUTING.md#testing-safely)) hold: no permission prompt, nothing of the installed pi² touched. A development build's pi² Remote has no other mode.
- `scripts/test-copy pair <suffix>` opens a pairing through the copy's engine with the test copy's key, confirms it itself, and prints the `pi2://pair?…` URL with the loopback address; `xcrun simctl openurl booted '<url>'` hands it to the simulator's app, which pairs without scanning.
- The simulator has no Secure Enclave: a debug build of the phone makes its keys in software when `SecureEnclave.isAvailable` is false, and says so on screen; a release build has no such path and refuses to pair. Face ID is the simulator's own (Features › Face ID). Notifications are tried with `xcrun simctl push` and a payload file, which runs the notification service extension against records a stand-in store holds.
- **A stand-in for iCloud.** pi² Remote and the phone reach iCloud through a `RecordStore` protocol in RemoteKit; its stand-in is a folder (`remote-records/` in the copy's data folder), which both use in loopback mode and in tests. Sealing, expiry, receipts and the order of answers are all tested through it.

**What CI builds and runs** (the iPhone workflow, P9, on the macOS runner):

- the shared targets' tests on macOS (`swift test`), and on the iOS simulator;
- the iPhone app and its extensions built for the simulator, with its unit tests;
- the engine's tests for devices (`engine/test/devices.ts`, P5): pairing, attach, the device table for every handler, presence signatures (good, stale, replayed, wrong method or params, wrong key), the log, revocation, the events never sent, and secrets never sent, with a stand-in for pi² Remote written in the test;
- a protocol test (P6): pi² Remote built in loopback mode against an engine started as the engine's tests start one, with a RemoteKit client in a test program that pairs, attaches, sends a request of each device class with software keys, and reads records through the folder stand-in.

**What only a real phone can show**: the Secure Enclave and Face ID; real pushes, how late they come, and the notification service extension's time; the Local Network prompts (the simulator does not have local network privacy[^lnp]); Bonjour on a real network; how much time iOS gives a notification's action; a Live Activity's look and updates; how often widgets are redrawn; battery and data; cellular and a private network away from home; iCloud's delays; what the Lock Screen shows. P29 and P30 try these on the owner's phone, with the owner, and write what they found here.

## 11. What the Mac cannot check

The engine checks what reaches it. About a phone, these lie outside, and nothing in the epic may claim otherwise:

- **That a device's keys are where they should be.** The Mac takes the public keys the phone sends at pairing. It cannot tell a key in the Secure Enclave from one in software, or a genuine pi² for iPhone from another program that paired with the code; the code and the six digits prove only that someone on the Mac's network had the code in front of them and the person clicked Pair. (Apple's App Attest could prove more; it is left to the step 6 reading.)
- **Whose face.** A presence signature proves that the phone's enrolled Face ID passed. It cannot prove whose face is enrolled, or that the passcode that guards enrolling is strong.
- **What the phone keeps, and shows.** The Mac cannot see the phone's cache, its screenshots, its delivered notifications, its Lock Screen setting, or whether it is jailbroken. [3.6](#36-revoking-and-a-lost-phone) says what pi² keeps there; nothing stops a person or a broken phone keeping more.
- **Who holds an unlocked phone.** Every request but Face ID's is taken from whoever has the paired phone unlocked.
- **That iCloud delivers.** The Mac cannot tell whether a notification reached the phone, or when; a need answered nowhere stays under Needs you on the Mac, as it does today.
- **When something was written.** `at` in a request is the phone's clock; the engine bounds it with its own, as [6.2](#62-icloud-the-recommended-answer) says, and the order of answers in iCloud is the order of those clocks.
- **What [projects.md section 11](projects.md#11-what-the-engine-cannot-check) already says** stays true: an agent's command can still write the data folder or start an engine of its own; the device rules do not sandbox commands.

## 12. The later issues

Thirty issues, in the roadmap's steps. "Waits for" is what must be merged first; "owns" is what no other issue changes while it is open, so issues built side by side do not collide. Each issue updates the part of this page it built if the build had to differ, in the same pull request.

### 12.1 Who owns what several issues share

| Shared piece | Owner | Until then, and how others plug in |
|---|---|---|
| The device lists in `answers.ts`, `deviceMay`, `FOR_THE_HELPER`, and the start-up check | P5 | Every later issue that adds a request places it in the lists and tests its refusal from a device |
| `pi2.devices`, `pi2.deviceNonces`, `pi2.deviceLog`, `summarize`, the `devices` and `device` events | P5 | An issue that lets a device send a new request adds its `summarize` line |
| Presence verification in the engine | P5 | P12 signs; P17 signs from a notification |
| `remote.*` requests and the `remote.cloudOut` event | P5 (control, pairing, attach), P15 (cloud) | P5 leaves `remote.cloudIn`/`cloudOut` out; P15 adds them in `engine/src/remote.ts` |
| `RemoteKit` (wire formats, `RecordStore`, notification kinds) | P6 | P8, P15, P16, P17, P19 use it; a change they need is made in P6's place by the issue that needs it, alone in its pull request |
| `PiModels` | P2 | Other issues add types beside their own feature's |
| `EngineKit` and `EngineTransport` | P3 | P8 adds the TLS transport in `iphone/`, not in EngineKit |
| `TranscriptKit` and `app/Web/transcript`'s narrow layout | P4 | P13 and P24 use it |
| `app/Package.swift` | each target's issue adds its own lines | Conflicts there are lines added side by side; keep both |
| The `iphone/` Xcode project, its targets and signing | P8 | P8 makes the project with folders Xcode keeps in step by itself, so a source file added in a folder never changes `project.pbxproj`. A new target changes it: P16 (notification service), P26 (widgets), P28 (share); they land one at a time |
| Identifiers, the CloudKit container, provisioning profiles | P10 | Until P10, CloudKit work runs against the `RecordStore` folder stand-in |
| `scripts/test-copy --remote` and `pair`, the iPhone CI workflow | P9 | Until P9, protocol tests run from P6's test program |
| The phone's store (cache, Outbox, protection, wiping) | P18 | Earlier screens keep state in memory only |

### 12.2 Each issue

**Step 0: design and contract**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P1 A security reading of this contract | A second agent's reading: pairing, keys, attach, presence, the device table, records and sealing, what a lost phone keeps; findings as review comments, and changes to this page agreed by the owner | The owner's agreement of this page | Nothing outside its findings | Every finding is answered on the pull request that makes this page, or filed |

**Step 1: foundations, side by side**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P2 Shared models | `PiModels` ([8](#8-the-shared-package)); `pi2-client-check` and its recorded session | P1 | `app/Sources/PiModels`, `app/Sources/pi2-client-check`, its fixture | The Mac app builds on `PiModels`, the check passes, nothing else changed |
| P3 The engine's client in a package | `EngineKit`, `EngineTransport` and the Unix socket transport; `EngineClient` on top of it | P2 | `app/Sources/EngineKit`, `EngineClient.swift`, `EngineSocket.swift` | `pi2-client-check` passes unchanged; a copy's pictures match |
| P4 The conversation page for both | `TranscriptKit` split; the UIKit view; the page's narrow layout | P2 | `app/Sources/TranscriptKit`, `app/Web/transcript` (narrow rules), `pi2-transcript-check` | The Mac's check and pictures unchanged; the page drawn at 390 points in a test |
| P5 Devices in the engine | [Section 3](#3-pairing)'s engine side, [section 4](#4-who-is-speaking) whole, [5.4](#54-the-messages) and [5.5](#55-what-is-never-sent-to-a-phone) in the engine, starting pi² Remote | P1 | `engine/src/devices.ts`, `engine/src/remote.ts` (but its cloud part), the device lists in `answers.ts`, `engine/test/devices.ts` | The tests of [10](#10-testing-with-no-phone-in-hand) pass with a stand-in helper |
| P6 pi² Remote | The helper ([5.1](#51-which-program-listens) to [5.3](#53-tls-and-mutual-authentication)): TLS with the pinned key, Bonjour, loopback mode, attach, passing lines; its PeerKit requirement; `RemoteKit`; embedding it in the app's bundle | P5 for attach (it may start against a stand-in) | `app/Sources/pi2-remote`, `app/Sources/RemoteKit`, the helper's requirement in `PeerKit`, `app/build.sh`'s lines for it | The protocol test passes in CI; a copy's helper never asks macOS for anything |
| P7 The Devices page on the Mac | Settings › Devices: the preview switch, Reach from an iPhone, iCloud's line, pairing with the QR code and the digits, the list, rename, revoke, accept a new Face ID key, the log | P5 | `app/Sources/pi2/DevicesSettings.swift`, its tab in `SettingsView.swift` | Every state drawn in a copy; pairing confirmed through it with a stand-in phone |
| P8 The iPhone app's shell | `iphone/`: the project, its signing for development, the first screen, scanning, pairing, the keys ([3.2](#32-the-keys)), the TLS transport, attach, the connection's states, an empty list | P3, P6 | `iphone/` (project, `App/`, `Pairing/`, `Connection/`, `Keys/`) | Pairs with a copy from the simulator and shows "At home" |
| P9 Testing with no phone | [Section 10](#10-testing-with-no-phone-in-hand): `--remote`, `pair`, the simulator script, the CI workflow, `docs/development.md`'s section | P6, P8 | `scripts/test-copy`'s remote commands and `scripts/test-test-copy`'s cases for them, `scripts/iphone-sim`, `.github/workflows/iphone.yml` | CI builds and tests the phone on every pull request that touches it |
| P10 Signing, iCloud and TestFlight | [Section 9](#9-who-it-is-for-and-how-it-is-given-out): identifiers, the container, profiles, the upload script, `docs/releasing.md`'s section | P8 | `scripts/iphone-release`, the entitlements files, `docs/releasing.md`'s iPhone section | A build reaches the owner's TestFlight; a release Mac build carries pi² Remote signed with its profile |

**Step 2: the first useful release, at home**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P11 The projects list | The list with Needs you on top, the connection bar, chats, More, search | P8 | `iphone/Sources/Home/` | Drawn against a copy's demo projects in both appearances |
| P12 Needs you, answered | Every kind of card, answered; Face ID and the presence signature where [4.2](#42-what-a-device-may-send) asks | P5, P8 | `iphone/Sources/Needs/`, `iphone/Sources/Presence/` | Each kind answered from the simulator against a copy; the engine refuses a Face ID one without it |
| P13 The orchestrator's conversation | The transcript page, sending, dictation, photos and the camera, stop, queued messages, the outgoing chips | P4, P8 | `iphone/Sources/Conversation/` | A conversation read live and written to from the simulator |
| P14 The hub, Now and the Dashboard | The tab bar, Now, the Dashboard's pages | P11 | `iphone/Sources/Hub/`, `iphone/Sources/Dashboard/` | Drawn against a copy's demo hub |

**Step 3: away, and with the app closed**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P15 iCloud on the Mac | [6.2](#62-icloud-the-recommended-answer)'s Mac side: zones, records, sealing, subscriptions, fetching, `remote.cloudIn` and `cloudOut` | P5, P6, P10 | `app/Sources/pi2-remote/Cloud/`, `RemoteKit/Records/`, the cloud part of `engine/src/remote.ts` | Records written and read through the stand-in in CI, and through the owner's iCloud once |
| P16 iCloud and notifications on the phone | Subscriptions, the notification service extension, `Gone`, `State`, receipts | P15 | `iphone/NotificationService/`, `iphone/Sources/Cloud/` | A push from the simulator's tool opens a record and shows its text |
| P17 Notification actions | [Section 7](#7-notifications)'s categories and actions, delivering in the background, Face ID by opening the app | P12, P16 | `iphone/Sources/Notifications/` | Each kind's buttons answer a copy's need, directly and through the stand-in |
| P18 The Mac out of reach | The phone's store, dated; the Outbox; file protection; what is kept and wiped ([3.6](#36-revoking-and-a-lost-phone)) | P8 | `iphone/Sources/Store/`, `iphone/Sources/Outbox/` | A copy stopped and started again: the phone shows the last state, then sends its Outbox |
| P19 Direct from anywhere | [6.1](#61-direct-where-the-two-can-reach-each-other): addresses in `paired`, `device` and `State`, trying them at once, `direct` | P6, P8 | `iphone/Sources/Connection/Routes.swift`, the address list in `RemoteKit` | Reached by a non-Bonjour address in a test; "Away · direct" shown |

**Step 4: the rest of the board**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P20 Work | The list, a piece of work, giving it to an agent, filing | P14 | `iphone/Sources/Work/` | Against a copy's demo work, kept by pi² and with `PI2_GH` |
| P21 A pull request | Checks, findings, files, one file's diff, merge with Face ID, send back | P20 | `iphone/Sources/PullRequest/` | Against `PI2_GH`'s stand-in |
| P22 Agents, Rules, Notes, Branches | The board's other tabs and templates, with Face ID where asked | P14 | `iphone/Sources/Board/` | Each drawn and changed against a copy |
| P23 Settings, limits, usage, schedules | A project's settings and limits, the plan's windows, today's spending, schedules, the app's settings a phone may change | P14 | `iphone/Sources/Settings/`, `iphone/Sources/Usage/` | Each drawn and changed against a copy |
| P24 Agents' conversations, and the rest | An agent's own conversation, other conversations, chats, the archive, background commands; a new project from a folder the Mac offers; `projects.folders` and `files.preview` in the engine | P13 | `iphone/Sources/Conversations/`, `engine/src/folders.ts` | Each opened from the simulator; `files.preview` refuses outside the folder |

**Step 5: what only a phone can do**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P25 Live Activity and the Dynamic Island | For a followed project, updated while the app runs or is woken, dated | P26 | `iphone/Widgets/LiveActivity/` | Started, updated and ended against a copy, in the simulator |
| P26 Widgets | Needs you, Who is working, Today's spending, from `State` and the app's store | P16, P18 | `iphone/Widgets/` (the extension) | Drawn from a stand-in `State` in every size |
| P27 Shortcuts and Siri | App Intents: ask an orchestrator, what needs me, stop a project | P13 | `iphone/Sources/Intents/` | Each run from the Shortcuts app in the simulator |
| P28 The share sheet | Sending a link, text, photo or file to an orchestrator or agent | P13 | `iphone/ShareExtension/` | A link and a photo sent from the simulator's Safari and Photos |

**Step 6: before others use it**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P29 A second security reading, and a lost phone tried | The whole read again as built; App Attest weighed; a revoked and a lost phone tried on the owner's phone | P1 to P28 | Its findings, and [section 11](#11-what-the-mac-cannot-check) | Findings fixed or filed; [3.6](#36-revoking-and-a-lost-phone) shown true on a real phone |
| P30 Battery and data measured | A day's battery and data on the owner's phone; the greeting's size; the pushes' delays | P17, P19 | Its measurements, in [5.7](#57-battery-and-data) | Numbers written here, and issues filed for what costs too much |

An Apple Watch glance and an iPad layout are not issues of this epic; if wanted, each is filed as an idea once step 2 is in use.

## 13. Decisions this contract made

1. **One table decides what a device may send** ([4.2](#42-what-a-device-may-send)), checked on every request of a device connection whatever its class; every handler is placed in it, or the engine will not start.
2. **Face ID is a signature, not a flag**: the key that signs asks for Face ID, so the engine checks a signature over that one request, fresh and used once.
3. **The listener and iCloud are held by a helper in the app's bundle**, started by the engine and living as long as it; the engine stays the judge ([5.1](#51-which-program-listens)).
4. **The engine's own requests and events are carried as they are**, filtered in the engine both ways, rather than a narrower protocol kept in step by hand ([5.4](#54-the-messages)).
5. **TLS 1.3 with a pinned server key, and the phone's key proven over the TLS exporter**, so the phone's key never leaves the Secure Enclave and needs no certificate.
6. **The Mac's certificate is self-signed and only its key's hash is checked**; making it needs code that writes a certificate, which Apple's frameworks lack (question 6).
7. **Three keys on the phone**: one to prove the device (unlocked only), one for Face ID, one to open records (after first unlock, so a locked phone can show a notification).
8. **Pairing only on the Mac**, with a five-minute code and six digits worked out from the connection, confirmed by a click in the app.
9. **A new Face ID key must be accepted on the Mac**, so whoever knows the passcode cannot take Face ID's answers by enrolling a face.
10. **One iCloud zone per device**, every record sealed with HPKE to one reader and bound to its place, on top of iCloud's own encryption.
11. **Only answers, short messages and stops travel through iCloud**; everything else waits for a direct connection.
12. **Records are good for a day**: a need's buttons stop working after 24 hours, and an answer older than that is refused, with a receipt.
13. **Notifications always come through iCloud**, at home too, and a notification is only ever a hint to look.
14. **Every notification button asks for the phone to be unlocked**; the Face ID ones open the app.
15. **A notification says who, what kind, which project and the card's short line**, secrets replaced; never output, files or transcript.
16. **The phone's cache is small, protected and wiped**: 20 conversations of the last seven days, `NSFileProtectionComplete`, wiped on revocation and after 30 days without the Mac.
17. **Moves before changes** in the shared package, proven by a recorded session replayed against the client before and after.
18. **Throwaway copies listen on loopback only** and never advertise, so testing asks macOS for nothing.
19. **Behind a preview switch on the Mac**, as projects were, until the owner says otherwise.

## 14. Questions for the owner

Beyond the three decisions of [section 2](#2-the-three-decisions-and-where-each-lives). The page is written as if each recommended answer were given; each can be answered yes, or changed.

1. **The helper.** *Recommended:* pi² Remote, a helper app inside pi²'s bundle, started by the engine, holds the listener and iCloud; turning remote access on asks macOS for the Local Network privilege once, by pi²'s name ([5.1](#51-which-program-listens)).
2. **What asks for Face ID.** *Recommended:* the rows marked Face ID in [4.2](#42-what-a-device-may-send): answers that widen reach, Allow everything, starting past a limit, a merge, changes to agents' and projects' settings, Undo, deleting. Everything else is taken from an unlocked paired phone.
3. **Face ID enrolled again.** *Recommended:* the phone's Face ID key is invalidated when faces change, and the new one works only once the person accepts it on the Mac ([3.2](#32-the-keys)).
4. **What the phone keeps.** *Recommended:* the last state and the last 300 entries of at most 20 conversations opened in the last seven days, readable only while unlocked, wiped on revocation and after 30 days without the Mac ([3.6](#36-revoking-and-a-lost-phone)).
5. **What a notification says.** *Recommended:* the agent, the kind, the project and the card's short line (for an approval, the command's summary), with every secret the Mac knows replaced; the Lock Screen follows the phone's own preview setting ([section 7](#7-notifications)).
6. **A package for certificates.** The Mac's TLS key needs a self-signed certificate, which Apple's frameworks cannot write. *Recommended:* allow Apple's own open-source `swift-certificates` (and the `swift-asn1` it needs) in pi² Remote alone; the other way is to run `/usr/bin/openssl` once at set-up, which leaves a key outside the Keychain for a moment.
7. **How many devices.** *Recommended:* up to five, each with its own keys and log; an iPad later counts as one.
8. **The oldest iPhone.** *Recommended:* iOS 18 or later, on an iPhone with Face ID; the owner's phone is the one that matters first.
9. **An Xcode project in the repository.** The Mac app has none and builds with SwiftPM and `app/build.sh`; an iPhone app with extensions needs one. *Recommended:* one Xcode project in `iphone/`, holding only the app's shell and its extensions, with all shared code in `app/Package.swift`'s targets, and folders Xcode keeps in step by itself so that adding a file never touches the project file.

## Notes

[^se]: Apple, [Protecting keys with the Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave): it "works only with NIST P-256 elliptic curve keys" and "can't encode preexisting keys".
[^passcode]: Apple, [kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessiblewhenpasscodesetthisdeviceonly): accessible only while unlocked, "never migrate to a new device", and "Disabling the device passcode causes all items in this class to be deleted."
[^biocurrent]: Apple, [SecAccessControlCreateFlags.biometryCurrentSet](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/biometrycurrentset): "The item is invalidated if … the user re-enrolls for Face ID."
[^exporter]: The TLS 1.3 exporter is RFC 8446, section 7.5; channel binding with it is RFC 9266. Network framework gives it as [sec_protocol_metadata_create_secret](https://developer.apple.com/documentation/security/sec_protocol_metadata_create_secret(_:_:_:_:)): "Export a secret … derived from the protocol metadata using a label string."
[^devid]: Apple, [Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos): iCloud (CloudKit) and Push notifications are both available to apps signed with a Developer ID certificate, through a provisioning profile.
[^lnp]: Apple, [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy): "All Bonjour operations require local network access"; on macOS "The exception for launchd daemons doesn't apply to launchd agents", and macOS asks for the responsible app; an iOS app in the background with the privilege undetermined is denied without the alert; a local network is one on a broadcast-capable interface, "but not cellular (WWAN) or VPN"; "The simulator doesn't support local network privacy."
[^dbsub]: Apple, [CKDatabaseSubscription](https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription): the default zone of the private database "doesn't participate in database subscriptions"; "Because the system coalesces notifications, don't rely on them for specific changes. CloudKit can omit data to keep the payload size under the APNs size limit."
[^zonesub]: Apple, [CKRecordZoneSubscription](https://developer.apple.com/documentation/cloudkit/ckrecordzonesubscription): "Only the private database supports record zone subscriptions", and a subscription can be limited to one record type.
[^sub]: Apple, [CKSubscription](https://developer.apple.com/documentation/cloudkit/cksubscription): "Create subscriptions in the development environment first and then promote them to production"; the server notifies "all devices with that subscription except for the one that makes the original changes". Its [NotificationInfo](https://developer.apple.com/documentation/cloudkit/cksubscription/notificationinfo-swift.class) carries an alert's text, a `category` and `shouldSendMutableContent`.
[^ckenc]: Apple, [Encrypting user data](https://developer.apple.com/documentation/cloudkit/encrypting-user-data): fields set through `encryptedValues` are encrypted with key material in the person's iCloud Keychain.
[^hpke]: Apple, [HPKE](https://developer.apple.com/documentation/cryptokit/hpke): hybrid public key encryption as RFC 9180 describes it, which "optionally incorporates sender authentication".
[^bgpush]: Apple, [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app): "the system doesn't guarantee their delivery … don't try to send more than two or three per hour"; the app then has 30 seconds.
[^bgtime]: Apple, [Extending your app's background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time): five seconds after moving to the background, more on asking with `beginBackgroundTask`, up to what `backgroundTimeRemaining` says.
[^auth]: Apple, [UNNotificationActionOptions.authenticationRequired](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/authenticationrequired): "The action can be performed only on an unlocked device."
[^fg]: Apple, [UNNotificationActionOptions.foreground](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/foreground): "The action causes the app to launch in the foreground."
[^actions]: Apple, [Declaring your actionable notification types](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types): categories and their actions are declared when the app launches; on a choice "the system launches your app in the background"; users "can respond to actions while the device is locked".
[^nse]: Apple, [Modifying content in newly delivered notifications](https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications): the extension "has only about 30 seconds", runs only for pushes with `mutable-content` and an alert, and is meant among other things to "Decrypt data sent in an encrypted format".
[^lapush]: Apple, [Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications): remote updates come from the developer's server over a token-based connection to APNs; and [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities): a Live Activity "can't access the network", lasts up to eight hours, and its data is at most 4 KB.
