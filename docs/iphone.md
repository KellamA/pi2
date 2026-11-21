# pi² for iPhone: the contract

This is the contract for epic [#620](https://github.com/KellamA/pi2/issues/620), pi² for iPhone: how a phone is paired with a Mac, how the engine knows a paired phone speaks for the person, how the two reach each other on any two networks, what a notification carries, what moves into a package both apps build on, and how all of it is tested with no phone in hand. Every later issue of the epic is built against it, several at once, by agents who read this page and not the conversation in which it was made. Where this page and an issue's text differ, this page has the last word on names and shapes; [section 12](#12-the-later-issues) says who owns each piece that several issues share.

The design it builds is [design/iphone.md](design/iphone.md), with its drawings in [design/iphone-drafts.html](design/iphone-drafts.html). This page does not repeat why the phone exists; it says exactly what. Where the design left something open, this page decides it, and [section 13](#13-decisions-this-contract-made) lists each decision. What only the owner can decide is in [section 2](#2-the-decisions-and-where-each-lives) (the three decisions asked, one answered) and [section 14](#14-questions-for-the-owner) (the rest). Nothing in the epic starts until the owner has agreed this page and a second agent has read it for security.

**How to read it.** Read [section 1](#1-words), [section 2](#2-the-decisions-and-where-each-lives), [section 4](#4-who-is-speaking) and [5.1](#51-the-shape-one-channel-two-paths) whatever your issue, then [12.1](#121-who-owns-what-several-issues-share) and the sections your issue's row in [12.2](#122-each-issue) names. Types are written as TypeScript, as `engine/src/state.ts` writes them; times are milliseconds since 1970. Apple's and Cloudflare's limits and prices are cited in the notes at the end, from their own documentation; a number this page gives without a note is this page's own choice.

## Contents

1. [Words](#1-words)
2. [The decisions, and where each lives](#2-the-decisions-and-where-each-lives)
3. [Pairing](#3-pairing)
4. [Who is speaking](#4-who-is-speaking)
5. [Transport](#5-transport)
6. [Across any two networks: the ways compared](#6-across-any-two-networks-the-ways-compared)
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
- **The Mac**: the Mac whose engine the phone is paired with. One phone may later be paired with several Macs; this contract builds one, and keeps a pairing's id in everything so that more can be added.
- **The app**: the Mac app, as everywhere in `docs/`.
- **pi² Remote**: a helper program inside the app's bundle that holds the Mac's ends of both paths and its keys ([5.5](#55-which-program-holds-them)). The engine starts it and is its judge.
- **The relay**: a small service pi² runs, on Cloudflare ([5.3](#53-the-relay)), that passes sealed bytes between a Mac and its paired phones, keeps a small mailbox of sealed items for an end that is away, and sends pushes. It can read none of what it passes.
- **Pairing**: at the relay, a Mac and its paired devices, under a random id. In the engine, the record of [3.2](#32-the-keys).
- **Device**: a paired phone, as the engine records it.
- **Channel**: a Noise session between the phone and pi² Remote ([5.2](#52-the-secure-channel-noise)), over either path.
- **Path**: what carries a channel: `relay` (the main path, on any two networks), `home` (TCP on the same network, found by Bonjour) or `direct` (TCP to another address of the Mac's, such as a private network's).
- **Device connection**: a connection to the engine's socket that pi² Remote opened for one device's channel, after the device proved itself ([3.4](#34-what-each-side-proves-at-every-connection)).
- **Presence signature**: a signature over one request, made by a key the phone can use only after Face ID ([4.3](#43-face-id-the-presence-signature)).
- **Sealed item**: a message encrypted for one reader with HPKE and signed by its writer, which can wait in the relay's mailbox ([5.3](#53-the-relay)).
- **Outbox**: what the phone has written and not yet seen taken by the Mac.

## 2. The decisions, and where each lives

| Decision | Status | Written for | Lives in |
|---|---|---|---|
| 1. How the phone reaches the Mac away from home | **Answered by the owner**: "it needs to work on separate networks or it defeats the purpose." Everything, the live conversation included, works with the phone on any network and the Mac on another, with nothing for the person to set up beyond pairing. | The way recommended in [section 6](#6-across-any-two-networks-the-ways-compared): **a relay pi² runs on Cloudflare** (Workers with Durable Objects), end-to-end encrypted, which also sends the pushes; the direct connection at home is an optimisation of the same channel. The owner agrees the way with question 1 of [section 14](#14-questions-for-the-owner). | [Section 5](#5-transport) and [section 6](#6-across-any-two-networks-the-ways-compared) |
| 2. What the phone may do | **Answered by the owner, as recommended**: everything the person can do at the Mac, with Face ID on the phone for the risky ones, and a Devices page on the Mac | The table of [4.2](#42-what-a-device-may-send): what the person does at the Mac, but what needs the Mac's hands or a secret; the riskiest with Face ID; the same on every path. The Devices page is [3.6](#36-revoking-and-a-lost-phone) and [4.4](#44-the-devices-log), built by P11 | [4.2](#42-what-a-device-may-send); the engine reads it as data |
| 3. Who it is for at first | **Not made yet.** The owner asked what changes if the App Store is planned for from the start | **Built so that the App Store stays possible, given out to the owner alone through TestFlight's internal testing first**: nothing assumes one person, no private API, a demo mode with no Mac, and a page on what going to the App Store would still take | [Section 9](#9-who-it-is-for-and-how-it-is-given-out); [9.5](#95-if-it-goes-to-the-app-store) |

The first draft of this page was written for "direct at home, the person's iCloud for a push and an answer away". The owner's answer rules that out as the main path, since a live conversation cannot travel through iCloud ([6.1](#61-the-three-ways)). iCloud is no longer used anywhere in the epic.

## 3. Pairing

### 3.1 What the Mac shows and the phone scans

**Settings › Devices › Pair an iPhone** asks the engine for a pairing (`devices.pairStart`, the app's alone). The engine has pi² Remote register the pairing with the relay if it has none ([5.3](#53-the-relay)) and open a **join window** there for five minutes, and the app draws the payload as a QR code. The payload is a URL:

```
pi2://pair?v=2&p=<pairing>&n=<Mac's name>&c=<Mac's channel key>&r=<Mac's record key>&s=<secret>&u=<relay>&a=<address:port,…>&e=<expiry>
```

- `p`: the pairing's id at the relay, 16 random bytes the relay chose, base64url.
- `c`: the Mac's channel key, a Curve25519 public key, base64url. The phone accepts a channel only with the holder of this key ([5.2](#52-the-secure-channel-noise)).
- `r`: the Mac's record key, a P-256 public key (SPKI DER, base64url), to which sealed items for the Mac are sealed.
- `s`: 32 random bytes, made for this pairing alone and kept only in the engine's memory and pi² Remote's until the window closes. It is the pre-shared key of the pairing handshake, and the relay is given only a hash of a value made from it ([3.3](#33-the-pairing-exchange)).
- `u`: the relay's address, such as `wss://relay.example.dev/v1`.
- `a`: the Mac's addresses on its network now, for the `home` path.
- `e`: seconds since 1970. The window is open for five minutes, for one phone; it closes after a phone pairs, after three wrong tries, when the sheet closes, or when it expires.

The QR code is shown only in the app's sheet, never written to disk or a log. It holds no account, password or long-lived secret: `s` is good once, for five minutes, and only with a genuine pi² for iPhone and a click on the Mac.

### 3.2 The keys

**On the phone**, made at pairing. The Secure Enclave holds only P-256 keys and cannot import one;[^se] Noise's standard key agreement is Curve25519,[^noise] which the Secure Enclave cannot hold. So the key that proves the device is in the Secure Enclave, and the channel key, which is Curve25519, is bound to it by a signature at every connection ([3.4](#34-what-each-side-proves-at-every-connection)).

| Key | What it does | Where and how it is kept |
|---|---|---|
| **Device key** (P-256, signing) | Proves the device to the relay and, over the channel's handshake hash, to the Mac; signs every sealed item the phone writes | Secure Enclave, `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` with `privateKeyUsage`: usable only while the phone is unlocked, never backed up or moved, deleted if the passcode is turned off.[^passcode] |
| **Presence key** (P-256, signing) | Signs one request after Face ID ([4.3](#43-face-id-the-presence-signature)) | Secure Enclave, as the device key, plus `biometryCurrentSet`: each use asks for Face ID, and the key is invalidated if Face ID is enrolled again.[^biocurrent] None if the person refused Face ID; the requests that need it are then the Mac's alone. |
| **Channel key** (Curve25519) | The phone's static key in Noise ([5.2](#52-the-secure-channel-noise)) | Keychain, `WhenPasscodeSetThisDeviceOnly`: as the device key, but not in the Secure Enclave |
| **Record key** (P-256, key agreement) | Opens what is sealed to the phone: a push's content and the mailbox's items, in the app and in its notification service extension | Keychain, `AfterFirstUnlockThisDeviceOnly`, in an access group the extension shares, so a notification that arrives while the phone is locked can be opened; in the Secure Enclave if CryptoKit's HPKE takes a Secure Enclave key on the iOS version P14 targets, which P6 finds out |
| **App Attest key** | Proves to the relay, once, that the phone runs a genuine pi² for iPhone signed by pi²'s team[^attest] | Made and held by `DCAppAttestService`, in the Secure Enclave |
| **What the phone keeps of the Mac** | The pairing's id, the Mac's name, channel key, record key, the relay's address, the Mac's last addresses | Keychain, `AfterFirstUnlockThisDeviceOnly`, the same access group |

A new presence key (Face ID enrolled again, or Face ID turned on later) is sent to the Mac and used only once the person accepts it on the Mac's Devices page (`devices.acceptPresenceKey`, the app's alone): otherwise whoever knows the passcode could enrol a face and gain Face ID's answers.

**On the Mac**, made by pi² Remote when remote access is first turned on, kept in the data-protection Keychain in an access group only pi²'s signed code has, so `/usr/bin/security` and an agent's commands cannot read them:

| Key | What it does |
|---|---|
| **Channel key** (Curve25519) | The Mac's static key in Noise; its public half is `c` |
| **Record key** (P-256, key agreement) | Opens items sealed to the Mac; seals items and push contents for a device, in HPKE's authenticated mode |
| **Relay key** (P-256, signing) | Proves to the relay that this Mac owns the pairing |

A development build or throwaway copy, which is signed ad hoc and has no access group, keeps them in a file in its own data folder, readable only by the person, and talks only to a relay on this Mac ([10](#10-testing-with-no-phone-in-hand)); a release build never does either.

**The Mac's record of a device**, kept by the engine:

```ts
type Device = {
	id: string; // "dev_" and 16 random bytes, base64url; also the device's slot at the relay
	name: string; // as the phone gave it ("Alex's iPhone"); the person can rename it on the Mac
	model: string; // "iPhone 17 Pro"
	system: string; // "iOS 27.1", updated at each connection
	deviceKey: string; // public halves, SPKI DER or raw, base64
	presenceKey: string | null;
	pendingPresenceKey: string | null; // a new one, until the person accepts it on the Mac
	channelKey: string;
	recordKey: string;
	pairedAt: number;
	lastSeenAt: number | null;
	lastPath: "relay" | "home" | "direct" | "mailbox" | null;
	revokedAt: number | null; // kept 90 days for the log, then removed
};

type Devices = {
	// the document `pi2.devices`
	pairing: string | null; // the pairing's id at the relay
	relay: string; // the relay's address; the release build's own unless the person changed it
	macName: string;
	remote: { on: boolean; relay: boolean; preview: boolean }; // relay: false is "home and private networks only" (6.4)
	macKeys: { channel: string; record: string; relay: string } | null; // public halves, as pi² Remote reported them
	devices: Device[];
};
```

### 3.3 The pairing exchange

1. The phone scans the code, and at once tries both paths: the relay at `u`, and `home` (Bonjour `_pi2._tcp` with `p=<pairing>`, and the addresses in `a`). Pairing works with the phone on any network.
2. **On the relay path**, the phone first joins: it sends the relay `join { pairing, deviceKey, attestation, keyId, token }`, where `attestation` is App Attest's for its key with the relay's challenge as client data,[^attest] and `token` is HMAC-SHA256 keyed with `s` of the text `pi2-join` and the pairing's id. The relay checks the window is open, the token against the hash the Mac gave it, and the attestation against Apple's root and pi²'s app id; it gives the phone a slot and connects it to the Mac's socket. A wrong token counts against the window's three tries. On the `home` path nothing is asked of the relay.
3. Over the first path to connect, the phone runs **Noise_IKpsk2_25519_ChaChaPoly_SHA256**:[^noise] it knows the Mac's static key `c`, the pre-shared key is `s`, and the prologue is `pi2-pair-v2` and the pairing's id. Only the holder of the Mac's channel key and of `s` can complete it.
4. Its first transport message is `{"pair":{"v":2,"device":{…},"signed":…,"signature":…}}`: `device` holds the name, model, system and the four public keys (device, presence, channel, record); `signed` is the JSON text `{"v":2,"kind":"pair","pairing":…,"binding":<the handshake hash>}` and `signature` the device key's over it, proof that the phone holds the device key, bound to this very channel (Noise's channel binding is the handshake hash[^noise]).
5. pi² Remote passes it to the engine (`remote.pairClaim`, with the handshake hash). The engine checks the window, the signature and that fewer than five devices are paired, and shows the claim in the `devices` event with six digits worked out from `s` and the handshake hash (HMAC-SHA256 with the label `pi2-digits`, the first 32 bits modulo a million). The phone shows the same six digits. The app shows them with the phone's name and **Pair** and **Cancel**.
6. **Pair** sends `devices.pairConfirm { accept: true }`, the app's alone. The engine stores the device; pi² Remote tells the relay to add the device's slot with its device key and closes the window; the phone is answered `{"paired":{"device":…,"pairing":…,"name":…,"addresses":[…]}}`.
7. The phone keeps what [3.2](#32-the-keys) says, asks for notifications and then for Face ID (each with a line on what it is for), sends the relay its push token ([7](#7-notifications)), and connects as any paired phone does.

Pairing is only ever started and confirmed on the Mac, in the app. No request a device can send starts, confirms or widens a pairing ([4.2](#42-what-a-device-may-send)).

### 3.4 What each side proves at every connection

**To the relay** (the relay path only): the Mac signs the relay's challenge with its relay key; the phone signs it with its device key and names its slot. The relay connects a phone only to its own pairing's Mac, and only while its slot is listed.

**To each other**, on either path, **Noise_KK_25519_ChaChaPoly_SHA256**:[^noise] both static keys are known from pairing, so the handshake proves to each that the other holds its channel key, with forward secrecy, in one round trip. The prologue is `pi2-v2`, the pairing's id and the device's id, so a handshake cannot be moved to another pairing or device.

**The device to the engine**: pi² Remote opens a new connection to the engine's socket for the channel and asks `remote.attachBegin`, which answers a 32-byte challenge; it passes it to the phone, which answers `{"attach":{"signed":…,"signature":…}}`, with `signed` the JSON text `{"v":2,"kind":"attach","pairing":…,"device":…,"binding":<handshake hash>,"challenge":…,"at":…}` signed by the device key; pi² Remote sends it with the handshake hash it saw as `remote.attach`. The engine checks the device, the signature, the challenge, the binding and that `at` is within two minutes, and from then on that engine connection is the device's ([4.1](#41-from-the-app-or-from-a-paired-device)). The device key is in the Secure Enclave, so the channel key, which is not, cannot be used to attach without it.

**pi² Remote to the engine**: the engine asks PeerKit (`pi2-peer`, [architecture.md](architecture.md#who-may-answer-for-the-person)) of every connection that sends a `remote.*` request, against the designated requirement of the helper inside the app's bundle. Only such a connection may send them ([4.1](#41-from-the-app-or-from-a-paired-device)).

A channel that has not attached within ten seconds of its handshake is closed.

### 3.5 How many devices

At most five devices are paired at once (question 8 in [section 14](#14-questions-for-the-owner)). Each has its own keys, slot at the relay, mailbox, push token and log; nothing one device does is visible to another but through the engine's state.

### 3.6 Revoking, and a lost phone

**Revoke** on the Devices page (`devices.revoke`, the app's alone):

1. sets `revokedAt` and forgets the device's keys in the same commit: from then on no attach, presence signature or sealed item of it is taken;
2. closes its device connections and channels at once;
3. has pi² Remote remove its slot at the relay, which closes its socket there, refuses it from then on, deletes its push token and its mailbox;
4. keeps its log for 90 days.

**Unpair this iPhone**, on the phone itself (its Settings), does the same from the other end, so that a person can take back everything about them without the Mac: the phone sends `devices.forgetSelf` if it can reach the Mac (a device's own request, [4.2](#42-what-a-device-may-send)), which revokes it as above; it sends the relay `leave`, signed with its device key, which removes its slot, push token and mailbox whether the Mac is reachable or not; and it deletes its keys, cache, store and Outbox. The Mac learns of a `leave` at its next connection to the relay and revokes the device then. This is the phone's "delete my data" ([9.5](#95-if-it-goes-to-the-app-store)).

Turning **Reach from an iPhone** off closes the channels and pi² Remote's socket at the relay; devices stay paired and can do nothing until it is on again. **Forget this Mac at the relay** (on the Devices page, with every device revoked) deletes the pairing there.

**What a revoked or lost phone can still read from its own storage**:

- **Its cache**: the last state the phone saw (projects, the Dashboard, Needs you, the board's lists) and the last 300 entries of at most 20 conversations opened in the last seven days, with no attachments but those shown in them. It is kept with `NSFileProtectionComplete`, readable only while the phone is unlocked. It is wiped when the phone learns it was revoked (the relay or the Mac says so), after 30 days without hearing from the Mac, and when the app is deleted.
- **The widgets' file**: counts and names only, readable while locked, so a widget can be drawn.
- **Notifications already delivered**, each holding at most what [section 7](#7-notifications) allows.
- **Its own Outbox**.
- **Nothing at the relay**: its slot, mailbox and push token are deleted at revocation, and items sealed for another device cannot be opened with its keys.

A lost phone that is not yet revoked can do what the table of [4.2](#42-what-a-device-may-send) allows to whoever holds it unlocked, on any network, within the relay's limits for its pairing ([6.6](#66-abuse-and-cost)); its Face ID answers need its owner's face. Revoking is the remedy, and the Devices page shows when and by which path each device was last seen.

## 4. Who is speaking

### 4.1 From the app, or from a paired device

Today the engine takes an answer, or a change to what the person set, only from a connection whose other end is the app, as macOS's code signing says (`answers.ts`, [architecture.md](architecture.md#who-may-answer-for-the-person), #504, #513). This epic widens the rule to: **from the app, or from a paired device, as the device's table allows**.

- Every connection has, besides `testCopy`, an optional `device: string` (the `Client` type in `main.ts`), set only by `remote.attach` on a connection PeerKit took for pi² Remote. A device connection is never the app's: `connection.mayAnswer` answers `false` on it, with why.
- **Every request on a device connection is checked against the device's table, whatever its class**: `deviceMay(method, params)` in `answers.ts` answers `"yes"`, `"face"` or `"no"`. `"no"` is refused ("This can be done only on the Mac, in the pi² app."); `"face"` is refused without a valid presence signature for that request ([4.3](#43-face-id-the-presence-signature)) ("This needs Face ID on your iPhone."); `"yes"` is handled as from the app. The refusal comes before the handler runs, as today's does.
- A sealed item from the mailbox (`remote.mailboxIn`, [5.3](#53-the-relay)) is checked the same way, with the path `mailbox`, and refused unless its row allows the mailbox.
- A fourth list, `FOR_THE_HELPER`, holds the `remote.*` requests, taken only from a connection PeerKit took for pi² Remote.
- The check at start-up widens: every handler belongs to exactly one of the three request classes as today, and to exactly one of the device lists (`FROM_A_DEVICE`, `WITH_FACE_ID`, `MAC_ONLY`), or to `FOR_THE_HELPER`; the engine will not open its socket otherwise. A request added later is placed by the issue that adds it, which tests its refusal from a device as `engine/test/answers.ts` tests the app's.
- Requests that are partly a device's, like `inbox.decide` (once or deny, yes; always or a rule, Face ID), have a function in the list, as `FOR_THE_PERSON` has.

### 4.2 What a device may send

This table is decision 2's one place; the owner agreed it as recommended. It is the content of the three device lists in `answers.ts` (P5). It holds on every path alike. "Face ID" means a presence signature is required ([4.3](#43-face-id-the-presence-signature)). "Mailbox" marks the requests that may also wait in the relay's mailbox as a sealed item while the Mac is not connected; every other request needs a channel.

| Requests | From a device | Mailbox |
|---|---|---|
| **Reading**: `engine.info`, `engine.lag`, `conversation.open`, `.older`, `.close`, `conversations.shown`, `search`, `submission.get`, `background.output`, `changes.list`, `github.refresh`, `github.diff`, `github.unknown`, `needs.list`, `projects.list`, `work.list`, `worktree.suggest`, `branches.refresh`, `limits.refresh`, `settings.getCompaction`, `local.status`, `conversation.image`, `conversation.export` | yes | |
| **Messages, starts and stops**: `submit`, `continue`, `abort`, `withdraw`, `conversation.create` and `chat.continueWithAgent` without `confirmLimit` or an explicit folder, `conversation.compact`, `.reset`, `.edit`, `.version`, `.retry` without a model, `background.stop`, `wakes.cancel`, `wakes.resume`, `reports.wake`, `schedules.runNow` without `confirmLimit` | yes | `submit` (text only, at most 4,000 characters) and `abort` |
| **Names, pins, notes**: `conversation.rename`, `.pin`, `.dismissCompactionError`, `projects.rename`, `memory.add`, `.edit`, `.delete` | yes | |
| **Answers**: `inbox.decide` once or deny, `inbox.answer`, `needs.answer` but the two below | yes | yes |
| **Answers that widen**: `inbox.decide` always, or with a rule; `needs.answer` allowing a reach request; any request with `confirmLimit` (starting past a limit, a limit card's Start Anyway); `agents.allowEverything` with `on: true` | **Face ID** | yes |
| **Changes that widen or cannot be undone**: `agents.save`, `.duplicate`, `.delete`, `.restore`, `.updateFromTemplate`, `conversation.configure`, `conversation.delete`, `memory.setEnabled`, `rules.add`, `schedules.save`, `usage.setBudget`, `changes.undo`, `projects.addAgent`, `projects.setOrchestrator`, `projects.set`, `projects.delete`, `projects.rules.edit`, `.move`, `.remove`, `github.attach`, `github.merge`, `worktree.remove` | **Face ID** | |
| **Changes that narrow, or are the person's ordinary acts**: `agents.allowEverything` off, `conversation.carryOn`, `.fork`, `.retry` with a model, `.archive`, `.unarchive`, `chat.set`, `rules.remove`, `schedules.delete`, `coauthor.set`, `projects.create` (with a folder the Mac offers), `.archive`, `.unarchive`, `.restoreConversation`, `.startFresh`, `.watch`, `projects.rules.add`, `work.create`, `work.act` without `confirmLimit`, `worktree.create`, `github.detach`, `github.sendBack`, `github.settle`, `settings.setCompaction`, `settings.setAutoArchive`, `settings.setAwake`, `recovery.dismiss`, `limits.dismiss` | yes | |
| **The Mac's alone**: secrets and sign-ins (`variables.*`, `providers.*`, `auth.*`, `endpoints.*`), the models that spend on pictures (`pictures.setModel`, `look.setModel`), programs started on the Mac (`mcp.*`, and `local.*` but `local.status`), the app's host roles (`computer.*`, `browser.*`), the Mac's upkeep (`backup.create`, `priority.set`, `settings.finishOnboarding`, `projects.setPreview`, `projects.carryOver`, `projects.retrySecrets`), `chat.continueWithAgent` with an explicit folder, `test-copy.*`, and every `devices.*` request but `devices.self` and `devices.forgetSelf` | no | |

A handler the engine has that this table does not name is placed by P5 in `MAC_ONLY`, and P5's pull request lists it for the owner. New requests this epic adds that a device may send: `devices.self` (its own record and log, yes), `devices.forgetSelf` (it unpairs itself, yes, [3.6](#36-revoking-and-a-lost-phone)), `projects.folders` (the folders the Mac offers for a new project, yes, P29), `files.preview` (a text file under a conversation's folder, at most 256 KB, yes, P29).

The owner answered decision 2 as this table has it. Were it ever narrowed, only the middle and last columns would change. For example "answers only, away from home": every row but Reading and Answers becomes "no" when the path is not `home`, which the engine knows from pi² Remote.

### 4.3 Face ID: the presence signature

A request that needs Face ID carries, beside `id`, `method` and `params`, a `presence` object:

```json
{"id": 41, "method": "github.merge", "params": {"projectId": "p_…", "number": 619},
 "presence": {"signed": "{\"v\":2,\"kind\":\"presence\",\"pairing\":\"…\",\"device\":\"dev_…\",\"method\":\"github.merge\",\"params\":{…},\"nonce\":\"…\",\"at\":1764150000000}",
              "signature": "<base64 DER ECDSA P-256 SHA-256>"}}
```

- The phone makes it only after Face ID: signing with the presence key is what asks for Face ID ([3.2](#32-the-keys)), so there is no "Face ID passed" flag to forge; the signature is the proof.
- `signed` is the exact JSON text that was signed, so neither side has to put JSON in a canonical form. The engine parses it and checks that its `method` and `params` are deep-equal to the request's, its `device` is the connection's, `pairing` is this Mac's, and the signature verifies with the device's presence key (`node:crypto`).
- **Freshness.** On a channel, `nonce` is `<the attach challenge>:<n>`, with `n` rising with each presence signature in the session, and `at` within two minutes. In a sealed item, `nonce` is the item's id and `at` within 24 hours. The engine keeps the nonces it took for 48 hours and takes none twice, after a restart too (`pi2.deviceNonces`).
- A request with a presence signature it does not need is taken as it is; the signature is logged.

### 4.4 The devices' log

Every request a device sends that is not in the Reading row of [4.2](#42-what-a-device-may-send), taken or refused, is logged in `pi2.deviceLog`:

```ts
type DeviceLogEntry = {
	at: number;
	device: string;
	path: "relay" | "home" | "direct" | "mailbox";
	method: string;
	summary: string; // "Merged #617 “Sidebar badges” (pi2)"; made by `summarize(method, params)` in devices.ts
	presence: boolean; // a valid presence signature came with it
	outcome: "done" | "refused" | "failed";
	why?: string; // the refusal's or the error's message
};
```

Entries are kept 90 days, at most 10,000 (the oldest go first). The Devices page shows them by device (`devices.log { device, before? }`, the app's), and the phone its own (`devices.self`). A method with no line in `summarize` is logged with its name and the project or conversation its parameters name; the issue that lets a device send a new request adds its line.

## 5. Transport

### 5.1 The shape: one channel, two paths

The phone and the Mac talk through **one secure channel**, a Noise session between the phone and pi² Remote ([5.2](#52-the-secure-channel-noise)), which carries the engine's own requests and events ([5.6](#56-the-messages)). The channel runs over either of two paths, and nothing above it knows which:

- **The relay**, the main path: both ends connect *out* to the relay over a WebSocket with TLS, which passes the channel's bytes between them. Any two networks that allow a web page to load allow it: a phone on a mobile network and a Mac at home, behind any NATs and firewalls, with nothing set up by the person.
- **Direct**, an optimisation: when the two can see each other (the same network, found by Bonjour; or an address of the Mac's that the phone can reach, such as a private network's), the same channel runs over TCP between them, which is faster and costs the relay nothing.

The same keys, the same handshake, the same messages and the same checks hold on both. The phone tries both when it connects and keeps whichever comes first, and moves a session from one to the other as the networks change ([5.8](#58-resuming-and-moving-between-paths)). The relay is the only path that must always work; direct is tried because it is cheaper, never because something needs it.

### 5.2 The secure channel: Noise

**The Noise Protocol Framework**,[^noise] with the handshakes `Noise_IKpsk2_25519_ChaChaPoly_SHA256` to pair ([3.3](#33-the-pairing-exchange)) and `Noise_KK_25519_ChaChaPoly_SHA256` for every connection after ([3.4](#34-what-each-side-proves-at-every-connection)). Noise is what WireGuard is built on.[^wireguard] It is chosen over TLS because the channel must run inside the relay's WebSocket as well as over TCP, with either end in either role, and Apple's TLS (Network framework) runs only directly over TCP or UDP, with the connecting side always the client; and because both ends already know each other's keys from pairing, which Noise is built for and TLS would need certificates for.

- **Implemented once**, in `RemoteKit` ([section 8](#8-the-shared-package)), from the specification, on CryptoKit's Curve25519, ChaChaPoly and SHA-256, used by both pi² Remote and the phone. It is checked against the published Noise test vectors for these two protocols, and read in the step 0 and step 6 security readings (P1, P34). Nothing else of the cryptography is pi²'s own: Noise, HPKE (RFC 9180) and ECDSA P-256 are specified elsewhere, and CryptoKit implements their primitives.
- **Framing.** Each Noise message is at most 65,535 bytes.[^noise] On TCP, each is preceded by its length in two bytes; on the relay, each is one binary WebSocket message. Inside the channel, a frame is one byte of kind (`data`, `more`, `ack`, `ping`, `bye`) and its body; an engine line longer than a frame is split into `more` frames ending in a `data` frame.
- **Channel binding**: the handshake hash, which the device key signs at `pair` and `attach` ([3.4](#34-what-each-side-proves-at-every-connection)).
- A channel lasts at most 24 hours, then is made again; it is never rekeyed.

### 5.3 The relay

**What it is.** A Cloudflare Worker with one Durable Object for each pairing (P8), in this repository, in `relay/`. Each end holds one WebSocket to it; the pairing's object passes binary messages between the Mac's socket and each device's, keeps the pairing's small state, and sends pushes. It uses Durable Objects' WebSocket Hibernation, so a pairing whose sockets are idle costs nothing while they stay connected.[^dows]

**The relay's protocol**, inside `wss://<relay>/v1` (the address carries no id, since a platform's request logs keep URLs[^cflogs]):

- **Hello.** The first text message names the role and the pairing: `{ hello: { v: 1, role: "mac" | "device", pairing, device?, ext?: {} } }`, or `register` for a Mac with no pairing yet. `ext` is empty today and ignored where it holds what the relay does not know; it is where a proof of purchase would go if the relay were ever paid for ([9.5](#95-if-it-goes-to-the-app-store)), so that needs no new protocol. The relay answers a 32-byte challenge, which the end signs with its relay key (the Mac) or device key (a phone); a phone's slot must be listed. A Mac's `register` gives its relay public key and signs the challenge; the relay answers the new pairing's id.
- **Data.** Binary messages: from a device, the channel's bytes; to the Mac, the same with the device's 16-byte id in front; from the Mac, with the id of the device it is for in front. The relay reads nothing past that id.
- **Control** (text messages, the Mac's alone but `token`, `take` and `leave`; `leave` is a device removing itself, [3.6](#36-revoking-and-a-lost-phone)): `openJoin { tokenHash, expires }`, `closeJoin`, `addDevice { device, deviceKey, attestKeyId }`, `removeDevice { device }`, `deletePairing`, `push { device, kind, … }` ([section 7](#7-notifications)), `put { to, id, item }` and `state { device, item }` (the mailbox), `take` (an end asks for its mailbox), and `token { apns, environment }` (a device's push token).

**What it keeps**, per pairing, in its object's storage:

| What | Why | How long |
|---|---|---|
| The pairing's id, the Mac's relay public key | To know the Mac | Until deleted, or 60 days with no connection |
| Each device's id, device public key, App Attest key id | To know a device | Until removed |
| Each device's push token and its environment | To send pushes | Until removed or replaced |
| The join window's token hash and expiry | Pairing | Five minutes |
| **The mailbox**: for the Mac, up to 200 sealed items, 1 MB in all, each at most 16 KB; for each device, the latest sealed state and up to 100 sealed items | So that what one end writes while the other is away is not lost: the phone's answers while the Mac sleeps; needs, receipts and the last state while the phone is unreachable | 24 hours each, then deleted; an item is deleted once taken |
| Counters for the limits ([6.6](#66-abuse-and-cost)) | Limits | One day |

**Sealed items.** A mailbox item is sealed for its one reader with HPKE (RFC 9180) in its authenticated mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256 and AES-256-GCM, as CryptoKit provides it:[^hpke] the Mac seals to the device's record key and authenticates with its own; the phone the other way. HPKE's `info` is `pi2-item-v2`, the pairing, the reader and the item's id, so an item cannot be moved and still open. An item from the phone carries, inside, a request signed by the device key, as `{ v, request: { method, params }, signed, signature, presence? }` with `signed` = `{ v, kind: "request", pairing, device, method, params, nonce: <item id>, at }`. The Mac takes such an item only if `at` is at most 24 hours old, its nonce is new, its row of [4.2](#42-what-a-device-may-send) allows the mailbox, and (for an answer) the item still waits; it writes back a sealed receipt either way ("This is no longer waiting: it was answered or withdrawn." or "Not sent: more than a day passed before your Mac saw it.").

**Many pairings, nobody's in particular.** The relay is written for any number of pairings from the start, each in its own object with its own limits ([6.6](#66-abuse-and-cost)), even while it serves the owner's one. A pairing is identified by its keys and a random id, never by an account, a name, an e-mail address or an Apple Account: the relay has no accounts. Nothing of the owner's is in its code; what a deployment needs (its push key, the team and app ids App Attest checks against, its limits, its address) is its configuration and its secrets ([6.4](#64-what-the-owner-sets-up-once)), so another deployment, the person's own or a future paid one, is the same code with other settings.

**What the relay knows**: a pairing's id, the public keys it checks, its devices' ids and push tokens, when each end connects and from which address (while connected; it stores none), and the size and time of every message, item and push. **What it cannot know**: anything inside a channel or a sealed item. The one exception, which the person turns on for each Live Activity, is a Live Activity's counts ([7](#7-notifications)). Cloudflare, which runs it, sees the same, and terminates the outer TLS; it cannot read inside Noise or HPKE.

**What it must never log**: a message's or an item's bytes, a push's payload, a push token, a pairing's or a device's id with an address, or any key. Workers Logs and invocation logs are off in its configuration,[^cflogs] it writes nothing to the console, and a check in CI fails if either changes (P15). The only numbers it keeps are the counters of its limits and the per-hour totals its operator's bill needs.

### 5.4 Direct, at home

- Every path works on IPv6 alone, as App Review requires:[^ipv6] the relay is reached by name, over Cloudflare's network, which answers on IPv6; pi² Remote listens on both IPv4 and IPv6, and the Mac's addresses it sends include its IPv6 ones.
- pi² Remote listens on TCP while remote access is on, in a release build, and advertises `_pi2._tcp` with the Mac's name and a TXT record `v=2`, `p=<pairing>`. A development build or throwaway copy listens only on the loopback interface and advertises nothing ([10](#10-testing-with-no-phone-in-hand)).
- The phone lists `_pi2._tcp` in `NSBonjourServices` and has an `NSLocalNetworkUsageDescription`; browsing asks the phone's owner once for Local Network.[^lnp] It asks while in the foreground, during pairing, since an app in the background with the privilege undetermined is denied without being asked.[^lnp]
- The channel on this path is the same Noise channel as on the relay, on TCP, with the length framing of [5.2](#52-the-secure-channel-noise). A listener reached from anywhere answers only a Noise handshake with a paired device's static key, and closes anything else after ten seconds.
- The Mac sends its current addresses inside the channel whenever they change (the `device` event, [5.6](#56-the-messages)), so the phone can try them from any network: `home` when found by Bonjour, `direct` otherwise. A private network of the person's (Tailscale and the like) is used this way if they have one, with nothing set up in pi²; nothing relies on it.

### 5.5 Which program holds them

The Mac's ends of both paths, its keys, and the channels are held by **pi² Remote**, a small app bundle inside the app's (`Contents/Helpers/pi² Remote.app`, bundle id `dev.pi2.app.remote`, no Dock icon), written in Swift (P7, P10). **The engine starts it**, as it starts `pi2-peer`, whenever remote access is on and a device is paired or a pairing is open; it starts it again if it dies (waiting twice as long after each failure, up to a minute), and stops it when remote access goes off or the engine stops. So the Mac is reachable exactly while the engine runs, which outlives the app's window (the login item starts the engine with no app at all).

Why a helper, and not the engine itself:

- **The cryptography is Apple's.** Noise on CryptoKit's primitives, HPKE, the Secure Enclave and the data-protection Keychain are Swift-only; the engine (Node) would have to implement HPKE itself, and could keep its keys only where any command of the person's can read them (`/usr/bin/security`, [architecture.md](architecture.md#who-may-answer-for-the-person)).
- **macOS's Local Network privilege follows code signing.** Bonjour on macOS needs it, and a launchd agent (the engine's login item) is not exempt; macOS asks once, naming the responsible app.[^lnp] A signed bundle of pi²'s with its own usage description is asked once, by name, and the answer stays. The relay path asks for nothing: it is an outgoing connection to the internet.
- **One implementation of the channel**, shared with the phone through `RemoteKit`.

And not the app: the app may be quit while the engine works. **The engine stays the judge**: pi² Remote holds keys and passes lines, and every rule of [section 4](#4-who-is-speaking) is checked in the engine. A fault in pi² Remote can drop or delay a line; it cannot make the engine take a request the device's table refuses, nor a Face ID request without the device's own signature. pi² Remote talks to the engine on a control connection of its own (`remote.*` requests, and the `remote` event the engine sends only to it, which carries pushes to send and items to seal) and opens one more connection for each attached channel.

**When it asks macOS for anything.** Only the `home` path's Bonjour advertising, in a release build, once, when the person first turns remote access on; the Devices page says so first. If the macOS firewall is on, it may also ask whether pi² Remote may accept incoming connections: P7 finds out, on the owner's Mac and with the owner's word, what a Developer ID-signed helper is asked, and writes it here. With the home path off (a switch on the Devices page), nothing is asked at all and the relay carries everything.

### 5.6 The messages

**The engine's own requests and events, carried as they are**: one JSON line each, inside the channel, in both directions, as on the socket ([architecture.md](architecture.md#how-they-talk)). The shared package's client already speaks them ([section 8](#8-the-shared-package)), so the phone gets every request and event as the Mac app has them, and nothing has to be kept in step with a second protocol. What a phone may send is limited in the engine ([4.2](#42-what-a-device-may-send)); what it is sent, in the engine too ([5.7](#57-what-is-never-sent-to-a-phone)).

On top of them, only:

- the first lines of a channel: `pair`, or `challenge` and `attach`, answered by `paired` or `attached`, and `resume` ([5.8](#58-resuming-and-moving-between-paths));
- `presence` beside a request ([4.3](#43-face-id-the-presence-signature));
- a `device` event, sent to a device connection after the greeting and whenever its record changes: `{ event: "device", id, name, pairing, mac: { name }, addresses: string[], relay: boolean, revoked: boolean }`. A revoked device is sent `revoked: true` and closed.

The greeting on a device connection is the app's ([projects.md](projects.md#44-what-an-app-is-sent-on-connecting)), less [5.7](#57-what-is-never-sent-to-a-phone)'s events, then `device`.

### 5.7 What is never sent to a phone

- **Events**: `computer`, `browser`, `auth`, `local`, `local.progress` and `mcp` are not sent on a device connection (they are the app's host roles, sign-ins and the Mac's upkeep).
- **Secrets**: no event or answer carries a provider's key, a sign-in's token, an agent's variable's value or an MCP server's variables today, and none may. P5 adds a test that runs a demo session with known secrets set and fails if any of their values appears in a line sent to a device connection.
- **The test copy's key**, and anything from `test-copy.*`.
- **Files outside what a conversation shows**, but through `files.preview`: a text file under the conversation's own folder, at most 256 KB, refused for anything that is not UTF-8 text or that lies outside the folder after links are followed (P29).

What *is* sent: conversations as their transcripts hold them, which include what agents read and ran. That is the product. It travels only inside the channel.

### 5.8 Resuming, and moving between paths

- **A session** is the phone's attachment to the engine. pi² Remote keeps a device's engine connection for 60 seconds after its channel drops, and keeps the engine lines it sent that the phone has not acknowledged (the phone sends `ack` with the count it has, every second or 64 KB), up to 4 MB.
- **Resuming**: on a new channel, by either path, the phone's first line after the handshake may be `resume { session, received }` with the attach signature; pi² Remote sends what the phone has not had and carries on, without a new greeting. If the session is gone or its buffer was passed, it answers `resume: false` and the phone attaches afresh: the engine sends the greeting, as to an app that reconnects after the engine restarted, the phone asks again for the conversations it has open (`conversation.open` with `newestFirst`), and a message whose answer never came is sent again with the same request id, which the engine already takes without doubling it ([architecture.md](architecture.md#keeping-the-app-quick-while-agents-work)).
- **Moving**: on a relay channel, the phone tries the addresses of the `device` event in the background; once a direct channel attaches with `resume`, the session moves to it and the relay channel is closed. When a direct channel drops (the phone left home), the phone resumes over the relay at once. A streamed answer goes on across the move with at most the lines in flight sent twice, which the phone drops by their count.
- **After the phone slept**: it holds no channel in the background beyond the short time iOS gives it,[^bgtime] and on coming back resumes if it can, or attaches afresh. The Outbox is sent before anything new.

### 5.9 Battery and data

- The phone holds a channel only while in the foreground, and for the short times iOS wakes it (a notification's action, a background push). It never polls.
- The Mac holds one WebSocket to the relay at all times while remote access is on, with a ping every 30 seconds to keep its network's NAT open; the relay's object hibernates between messages.[^dows]
- The engine sends `activity` to a device connection at most once a second (to the app, four times), and `conversation` events only for conversations the phone has open, as for the app.
- A greeting is the size of the person's library and projects; P35 measures it, and a request for only what changed since a version is left to an issue of its own if it matters.
- P35 measures a day's battery and data for an ordinary day (the app open two hours, sixty notifications); this page promises no number.

## 6. Across any two networks: the ways compared

### 6.1 The three ways

| | (a) A relay pi² runs | (b) Peer to peer (STUN, TURN when needed) | (c) The person's iCloud only |
|---|---|---|---|
| **Any two networks** | Yes: both ends connect out over HTTPS, which every network allows | Mostly: a direct path through both NATs when they allow one, a TURN relay when not | Yes |
| **The live conversation** | Yes, a few tens of milliseconds behind the Mac | Yes; lower latency when direct | **No.** Each change is a record saved and fetched in a round trip; pushes about changes are merged and may drop data;[^dbsub] silent pushes are not guaranteed and are throttled past two or three an hour;[^bgpush] saving too often is refused with a time to wait.[^cklimit] A streamed answer would arrive in lumps, seconds apart at best, with no guarantee |
| **Pushes** | The relay sends them with pi²'s push key | Need a sender anyway: a relay, or iCloud | iCloud sends them for the Mac's records |
| **What else it needs** | Nothing more | Signalling, to exchange addresses before the first packet: the small relay of (a), or iCloud. Apple's frameworks have no ICE, so it needs Google's WebRTC library or an ICE of pi²'s own | Both devices on the same Apple Account; CloudKit and push entitlements on the Mac |
| **How often the fallback is needed** | — | Published measurements: about 70% of hole-punching attempts succeed;[^libp2p] 17.7% of one service's peer-to-peer calls needed TURN, with no figures published since 2017;[^turnpct] mobile networks put phones behind carrier-grade NAT, through which a direct path often cannot be made.[^tsnat] Plan for a third of phone sessions relayed, and for ICE to run again on every change of network | — |
| **What it costs to run** | Cloudflare: see [6.2](#62-what-the-relay-costs) | TURN at Cloudflare costs $0.05 a GB past 1,000 GB a month, shared;[^turn] a thousand people's relayed third is about 130 GB a month, so nothing; plus the signalling relay of (a) | Nothing to pi²: the private database is the person's own iCloud storage[^ck] |
| **What the owner sets up** | A Cloudflare account and a push key ([6.4](#64-what-the-owner-sets-up-once)) | The same, and TURN credentials | A CloudKit container |
| **Upkeep** | None to patch; deploys from CI | All of (a), plus a peer-to-peer stack on both ends to keep working as networks and NATs change | None |

**(a) on Fly.io instead**, a small container running the same relay: the smallest machine that stays on costs $2.19 a month, data out $0.02 a GB in North America and Europe, and there is no free tier;[^fly] for a thousand people about $16 a month (two machines in two regions, and about 400 GB of data out). It is a server to keep: its runtime to update, a restart that drops every socket, and, once there is more than one machine, a way to route a phone to the machine its Mac is on.

### 6.2 What the relay costs

On Cloudflare's Workers Paid plan, $5 a month with its included use, or the Free plan:[^cfworkers][^dopricing]

- A Durable Object is billed per request (1 million a month included, then $0.15 a million), where each WebSocket message it *receives* counts as one twentieth of a request and messages it sends count nothing; and per GB-second it is awake (400,000 included, then $12.50 a million), where an object waiting with hibernating sockets counts nothing. Data out costs nothing.[^dopricing][^cfworkers]
- The Free plan includes 100,000 requests a day and 13,000 GB-seconds a day, and fails operations past them.[^dopricing]

For one person on an ordinary day (the app open two hours, receiving about three engine lines a second while open; sixty pushes; thirty-five connections): about 23,000 messages received, so about 1,190 billed requests a day and 7 GB-seconds a day (2 ms awake for each message, 200 ms for each push's call to Apple). So:

| | Requests a month | GB-seconds a month | Cost a month |
|---|---|---|---|
| One person | 36,000 | 220 | **$0** on the Free plan; **$5** on the Paid plan (all within what it includes) |
| A thousand people | 36 million | 220,000 | **about $10** ($5, and $5.25 of requests) |
| A thousand, ten times as busy | 357 million | 2.2 million | **about $84** |

These are estimates from the price pages with the assumptions above; P35 measures the real numbers. A spending limit on the account bounds them ([6.6](#66-abuse-and-cost)).

### 6.3 The recommendation

**(a), a relay pi² runs, on Cloudflare Workers with Durable Objects**, which also sends the pushes.

- Only a relay carries a live conversation across any two networks with nothing for the person to set up, and (b) needs one anyway, for signalling and for the third of sessions it cannot connect.
- (b)'s gain, lower latency on a direct path, matters for voice and video, not for text events a few times a second; its cost is a peer-to-peer stack (Google's WebRTC library, or ICE of pi²'s own) on both ends, and a phone that must redo ICE whenever it changes network.
- (c) cannot stream ([6.1](#61-the-three-ways)).
- Cloudflare over Fly.io: no server to keep, sockets that cost nothing while idle, nothing to pay for one person and about $10 a month for a thousand, its network near both ends, and tests that run it locally (`wrangler`, the Workers Vitest integration[^cfvitest]). The relay's protocol is plain WebSockets, so it can move to a container later without changing either end.

**Pushes come from the relay**, not from iCloud, now that the relay is there anyway: a push is sent at once with Apple's high priority rather than merged with others;[^apns] it needs no shared Apple Account and no CloudKit on the Mac; and only a holder of the push key can update a Live Activity while the app is closed,[^lapush] which the relay can. Its content is sealed for the phone and opened by the phone's notification service extension ([section 7](#7-notifications)).

### 6.4 What the owner sets up once

1. **A Cloudflare account**, on the Workers Paid plan ($5 a month) with a spending limit and an e-mail alert, or the Free plan while the owner is the only one using it.[^cfworkers][^cfspend]
2. **An API token** for deploying Workers, kept as a secret of this repository's CI (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`), or the owner deploys by hand with `wrangler deploy`.
3. **An APNs authentication key** (a `.p8` file) from the Apple developer account, with its key id and the team id, given to the relay as Workers secrets (`APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`) with `wrangler secret put`; never in the repository.[^apnskey][^cfsecrets] One for the sandbox environment (development builds) and one for production (TestFlight and later). The team id and the app's id are also what the relay checks App Attest against; they are settings of the deployment, not written in its code.
4. **The app's records**: the App IDs of pi² for iPhone and its extensions with Push Notifications and App Attest, pi² Remote's with Keychain sharing, and the app in App Store Connect for TestFlight (P14).
5. **Optionally**, a domain for the relay (`relay.<domain>`); otherwise the address Cloudflare gives (`<name>.<account>.workers.dev`).

pi² does the rest: the relay's code and its configuration in `relay/`; a workflow that tests it on every pull request and deploys it, to a development relay and to the production one, when the owner runs it; the relay's address built into release builds (and a field on the Devices page for another); every key, made at pairing; registering each pairing; and nothing for the person to set up on the Mac or the phone beyond pairing. `docs/relay.md` (P9) is the owner's page for the list above.

### 6.5 When the relay is down, or the person wants none

- **At home it still works**, directly: the whole of pi² over the `home` path, with the same channel.
- **Away, over a private network** the person has (Tailscale and the like), it works directly too, at the Mac's addresses.
- **Otherwise, away**: the phone shows "pi²'s relay can't be reached", with its last state dated, and keeps what is written in the Outbox until a path returns.
- **No pushes** while the relay is down. When it returns, the Mac sends pushes only for what still waits, not the ones it missed.
- **The person who wants none** turns **Reach through pi²'s relay** off on the Devices page: home and private networks only, and no notifications while the app is closed.
- **The person's own relay**: the code in `relay/` deploys to anyone's Cloudflare account, and the Devices page takes its address. It passes channels and keeps mailboxes as pi²'s does. It can send pushes only to a build of the app signed by the same team as its push key, so a TestFlight or App Store build gets notifications only through pi²'s relay.
- Not built in this epic: a fallback that carries notifications through the person's iCloud when the relay is down (the first draft of this page describes one); it can be filed once the relay has run for a while, if it is wanted.

### 6.6 Abuse and cost

**Who can use the relay.**

- A Mac registers a pairing by proving its relay key. A pairing stays **pending** and is deleted after 15 minutes unless a phone joins it, and a phone joins only with an App Attest attestation of pi² for iPhone, signed by pi²'s team, checked by the relay against Apple's root,[^attest] together with the join token from the Mac's QR code. So the relay carries traffic only between a Mac and a genuine pi² for iPhone paired with it; anyone else can at most make pending pairings, which cost a row for 15 minutes.
- Registering is limited per address: 5 an hour, 20 a day. The address is held only as a keyed hash, with a key that changes daily, for the day.
- Under decision 3's recommended answer, only the owner's TestFlight builds exist, so only the owner's phone can join anything.

**Limits for each pairing**, after which its messages are held, and past twice the limit its sockets are closed for an hour and the Mac's Devices page says why:

| | Limit |
|---|---|
| Sockets | 6 (the Mac and five devices) |
| A message | 70 KB (a Noise message and its header) |
| Messages | 100 a second; 300,000 a day |
| Data | 2 MB a second; 500 MB a day |
| Mailbox | As [5.3](#53-the-relay) |
| Pushes | 120 alerts an hour per device, 60 background pushes, 60 Live Activity updates |

**Bounding the bill**: a spending limit on the Cloudflare account and an e-mail alert;[^cfspend] the relay answers "busy" rather than failing when a limit is reached.

**What a lost phone can do through the relay before it is revoked**: what [4.2](#42-what-a-device-may-send) allows, if unlocked (the device key works only then), on any network, within its pairing's limits; Face ID's answers need its owner's face. It can reach no other pairing, read no other device's mailbox, and send pushes to nobody (only the Mac can ask for a push). Revoking removes it from the relay at once ([3.6](#36-revoking-and-a-lost-phone)).

**A photographed QR code** is not enough to pair: it also takes a genuine pi² for iPhone, within five minutes, and a click on the Mac with matching digits.

## 7. Notifications

**Who sends them**: the engine decides, pi² Remote seals, the relay sends. The engine sends pi² Remote a `remote` event `{ push: { device, kind, title, body, need?, projectId? } }`; pi² Remote seals it to the device's record key and asks the relay to `push`; the relay signs a token with its APNs key and posts it to Apple's push service.[^apns][^apnskey]

**What triggers one.**

- A new item in Needs you (with the projects preview on; the Inbox's items with it off), one notification per item, for each paired device.
- A provider's limit reached, or work carrying on past it, as the Mac notifies today (`Notifier.limitNotices`).
- An orchestrator's finished answer, only for a message the person sent from the phone with **Tell me when it answers** on.
- When an item is answered or withdrawn, a background push so the phone takes its notification away (best effort; Apple may hold or drop these[^bgpush]), and the item's removal in the device's mailbox.

The phone's own settings turn each of the first three off.

**What the push carries.** An alert push with a generic alert ("pi²", "Something needs you"), `mutable-content` set, a `collapse-id` of the item's id, and one custom key, `sealed`: the notification's content sealed with HPKE for the device ([5.3](#53-the-relay)), within Apple's 4 KB.[^payload] No category, no thread, no project and no kind are visible outside the seal: the notification service extension sets them when it opens it.[^nse] The relay sees that an alert of so many bytes went to a device at a time, and nothing else.

**What the text may contain** (inside the seal):

- Title: the agent's name and the kind ("Forge needs approval", "Scribe has a question", "The orchestrator asks for more reach", "Forge proposes a rule", "Forge is held back by a limit"), as the Mac's `Notifier.needsYou` says it.
- Body: the project's name and the card's short line (`NeedItem.short`, the tool and its call's summary for an approval), at most 180 characters, after the engine has replaced every secret it knows that appears in it (agents' variables' values, providers' keys and tokens, MCP servers' variables) with "•••".
- Never: a command's output, a file's contents, a diff, an attachment, or any transcript text beyond the card's own short line.
- iOS shows the body on the Lock Screen only as the person's notification previews setting allows; the phone suggests "When Unlocked" during pairing, and does not require it.

**The notification service extension** (P21) opens `sealed` with the record key, which is usable after the first unlock, within the thirty seconds or so iOS allows it,[^nse] and sets the title, the body, the category of the item's kind and its thread (the project). If it cannot open it in time, the generic text stays. It also writes the item to the app's store, so the app and the widgets have it. While the phone is offline, Apple keeps only the last notification for the app;[^apns] the phone takes its mailbox whenever it next connects, so nothing is lost but the banner.

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

1. makes the request, signs it with the device key, and puts it in the Outbox;
2. asks iOS for more time to finish (`beginBackgroundTask`);[^bgtime]
3. connects (relay and home at once, four seconds), attaches, sends the request and waits for the answer;
4. if the Mac is not connected to the relay, puts it in the Mac's mailbox as a sealed item instead, and stops there: the receipt comes later;
5. takes the notification away, and leaves the Outbox entry until the Mac's answer or receipt says what became of it. If even step 4 could not be done before iOS ended the app's time, the app sends it the next time it runs, and a local notification tells the person once: "Your answer to Forge is not sent yet. pi² will send it when it can reach your Mac."

**A Live Activity** ([design](design/iphone.md#what-a-phone-adds)) is started on the phone, which sets its static part (the project's name) there; the relay updates it while the app is closed with Live Activity pushes,[^lapush] whose content Apple's system reads directly, so it cannot be sealed. So a Live Activity's pushes carry **numbers only**: `{ working, needs, finished, at }`. The relay can read those numbers. The person turns on each Live Activity, and the switch says so.

## 8. The shared package

What the Mac app knows of the engine moves into targets of `app/Package.swift` that build for macOS and iOS (the package's platforms gain `.iOS(.v18)`), and both apps build on them. In this order, each a pull request that moves before it changes:

| Order | Target | What moves into it | Issue |
|---|---|---|---|
| 1 | `PiModels` | `Models.swift`'s types (`JSONValue`, `ConversationSummary`, `Item`, `AgentProfile`, `InboxItem`, `ActivityRun`, `UsageSummary`, `OpenConversation`, `EngineError` and the rest), the projects' models (`ProjectRow`, `NeedItem` and the types beside them), `Formats`, and `TranscriptFeed`, which depends on the models alone | P2 |
| 2 | `EngineKit` | The client without AppKit: requests and answers, `call`, events read into observable stores (`update`, the per-event decoding of `EngineClient.handle`), `OpenConversation` handling, `outgoing` and its retry, and an `EngineTransport` protocol with the Unix socket as the Mac's transport (`EngineSocket.swift`) | P3 |
| 3 | `TranscriptKit` | Split: the page's loading and its messages (shared), the AppKit view and the page loaded ahead (Mac), a UIKit view (iPhone); `app/Web/transcript` gains rules for a narrow screen and touch, with nothing changed at the Mac's widths. The page is built into the phone app's bundle and loaded from there, never from the Mac or the network: an app may not download code that changes what it does[^selfcontained] | P4 |
| 4 | `RemoteKit` (new) | What pi² Remote and the phone share: Noise (the two handshakes, transport, framing), HPKE sealing of items and pushes, the pairing payload, `pair`, `attach`, `resume`, `presence`, the relay's protocol as a client, the notification kinds and categories | P6 (the channel and sealing), P10 (the relay client) |

**Only public interfaces.** Both the shared targets and the phone use Apple's public APIs alone,[^publicapi] and no framework a phone app may not ship; the Mac app keeps its own exceptions (Accessibility for computer use), which never reach the shared targets. Apple checks this at every upload to App Store Connect, TestFlight's included, so the owner's first internal build already proves it.

**Stays Mac-only**: starting and watching the engine (`EngineSpawn`, `EngineTrouble`, `LoginItemKit`), the app's host roles (`ComputerKit`, `BrowserKit` and their sessions), `PaneKit`, `WindowKit`, `FileLinkKit`, `ComposeKit`, `PeerKit`, `Notifier`, Sparkle, and every view. `EngineClient` stays as the Mac's object, holding an `EngineKit` session and what only the Mac does with it.

**How the Mac app's behaviour is proven unchanged.**

1. **Moves first.** A pull request that moves code changes nothing inside what it moves but `public` and imports; the reviewer reads it with `git diff -M --color-moved`, and behaviour changes come in a later pull request.
2. **A recorded session, replayed** (`pi2-client-check`, P2): the events a throwaway copy's engine sent while `scripts/test-copy fill --project` built two demo projects and their conversations, recorded once into a fixture, are fed to the client; every property the views read is written out and compared with a file made from the client as it was before P2. P3 and P4 run it unchanged; any difference fails.
3. **The checks that exist** (`pi2-transcript-check`, `pi2-layout-check`, `pi2-window-check`, `pi2-compose-check`, `pi2-file-link-check`, `pi2-computer-check`) pass as before.
4. **The same pictures.** P3 and P4 picture a throwaway copy's hub, Dashboard and a long conversation before and after, in both appearances, and say what differs (nothing should).

## 9. Who it is for, and how it is given out

This section is decision 3's one place. The owner has not made it yet, and asked what changes if the App Store is planned for from the start. This page is written for what is likely: **built so that the App Store stays possible, given out to the owner alone through TestFlight's internal testing first.** The App Store is not decided by this; it stays one decision later, and [9.5](#95-if-it-goes-to-the-app-store) says what it would still take.

### 9.1 Given out: TestFlight's internal testing

- **The owner alone**, as an internal tester, until step 6's security reading is done and the owner says otherwise.
- **What internal testing needs from the owner**: the Apple Developer Program membership already held; the app's record in App Store Connect; test information (a short description and a feedback address); and an answer about encryption with each build, which the app's `Info.plist` gives once and for all ([9.5](#95-if-it-goes-to-the-app-store)).[^exportkey] Internal testers are App Store Connect users of the owner's team, up to 100; builds reach them with no review by Apple, and each build can be tested for 90 days.[^tfinternal][^tfoverview]
- **What external testers would add**: up to 10,000 people who are not on the team, invited by e-mail or a public link; the first build sent to them goes to App Review against the App Review Guidelines, and later ones may.[^tfoverview][^tfexternal] A TestFlight beta should be meant for public release and follow the guidelines, and may not be given in exchange for payment.[^beta] So external testing asks for everything of [9.5](#95-if-it-goes-to-the-app-store)'s review part (the demo mode, the notes for review, a privacy policy), and the relay's limits of [6.6](#66-abuse-and-cost) start to matter, since strangers' Macs use it.
- **Identifiers** (P14): the iPhone app `dev.pi2.ios`, its notification service extension `dev.pi2.ios.notifications`, widgets `dev.pi2.ios.widgets`, share extension `dev.pi2.ios.share`; pi² Remote `dev.pi2.app.remote`. Release builds of the Mac app carry pi² Remote with its provisioning profile from P14 on.
- **Two relays** (P9): a development relay, for development builds and the sandbox push environment, and the production relay, for TestFlight builds and later. Throwaway copies use neither ([10](#10-testing-with-no-phone-in-hand)).
- **Behind a preview switch on the Mac**: Settings › Devices shows only **iPhone (preview)** until the owner turns it on (`remote.preview` in `pi2.devices`); with it off, the engine starts no helper and refuses every `devices.*` request but turning it on.
- **Builds**: a script (`scripts/iphone-release`, P14) archives and uploads to TestFlight with `xcodebuild` and Apple's own tools; no third-party build tools.

### 9.2 Nothing assumes one person

So that the App Store, or external testers, need no redesign:

- **A pairing is keys, not an account.** The Mac and each phone are known by public keys made at pairing and by random ids ([3.2](#32-the-keys)); there is no sign-in, no account of the owner's or anyone's, and no Apple Account in the protocol. Two strangers' Macs and phones are two pairings, exactly as the owner's is one.
- **The relay serves many pairings**, each in its own Durable Object with its own limits, and carries nothing of the owner's in its code: its push key, team and app ids, limits and address are its deployment's settings ([5.3](#53-the-relay), [6.4](#64-what-the-owner-sets-up-once)).
- **Only genuine copies of the app may join** (App Attest, [6.6](#66-abuse-and-cost)), and abuse is bounded per pairing, not by trusting who uses it.
- **The relay holds nothing to disclose**: channels end to end, items and pushes sealed for one reader, no logs of content ([5.3](#53-the-relay)). What it does hold (ids, public keys, push tokens, sizes and times) is the list a privacy label and policy would declare.
- **The phone's text is not the owner's**: no names, paths or projects of the owner's appear in the app; every string a person reads is written for anyone, as the Mac app's are.

### 9.3 Nothing App Review refuses on sight

- **Public APIs only**, in the phone and its extensions ([section 8](#8-the-shared-package)).[^publicapi]
- **No code downloaded**: the conversation's page ships in the app's bundle, and what comes from the Mac is data, never code the phone runs.[^selfcontained] What runs on the Mac is the Mac's; the phone runs none of it.
- **Background work only for its purposes**: remote notifications, the notification service extension, and short tasks to finish an answer; no audio, VoIP or location trick to keep a connection open.[^bgmodes]
- **IPv6-only networks work** ([5.4](#54-direct-at-home)).[^ipv6]
- **A native app, not a mirror of the Mac's screen**: every screen is drawn on the phone from the engine's data ([9.5](#95-if-it-goes-to-the-app-store) says why this matters).
- **The phone can delete what is kept about it**: **Unpair this iPhone** removes its slot, push token and mailbox at the relay and everything on the phone ([3.6](#36-revoking-and-a-lost-phone)).
- **A link to a privacy policy and a way to reach pi²** in the app's settings, from the first TestFlight build, so that nothing is added at the end.[^privacy][^devinfo]

### 9.4 The demo mode

A reviewer has no Mac running pi², and a person who has just installed the app has nothing to pair with yet. So the phone has a **demo mode**: the whole of the app against canned data, with no Mac and no network. App Review asks for a demo account, or a fully featured demo mode, with full access to the app;[^demo] pi² has no accounts, so the demo mode is how a reviewer sees everything.

- **Where**: the first screen offers **Try it without a Mac** under **Scan the code on your Mac**, and Settings offers it again until a Mac is paired. A bar across the top of every screen says **Demo**, with **Leave**.
- **How**: a transport of its own, `DemoTransport`, behind the same `EngineTransport` the channel uses ([section 8](#8-the-shared-package)), so every screen is the real one. It starts from a recorded greeting of demo projects (the same kind of recording as `pi2-client-check`'s, made with the scripted demo model, so it holds nothing of anyone's) and answers requests by script: answering a card takes it away and the agent carries on; a message to an orchestrator gets a streamed answer; a merge merges; Face ID is asked as in earnest and its signature checked by the script.
- **What it shows**: every screen of the design, a card of every kind, a notification of every kind (scheduled locally, with their buttons), the Work tab and a pull request's diff, the Live Activity and widgets with demo numbers.
- **What it never does**: connect anywhere, register for pushes, make keys in the Secure Enclave, or write outside its own folder; leaving it deletes what it wrote.
- **Kept true**: the recording is made again by a script from the current engine whenever the greeting's shape changes, and a test plays every screen against it (P36).

### 9.5 If it goes to the App Store

**Built in already** (9.2 to 9.4): pairing by keys, not accounts; a relay for many pairings with limits for each and nothing of the owner's in it; App Attest at the relay; sealing end to end, so the relay holds no content to disclose or lose; public APIs only; the page in the bundle; IPv6; a native app; unpairing that deletes what the relay keeps; a privacy link and contact in the app; the demo mode.

**Still to do and decide then**, each marked **design** if leaving it until then would force a redesign (and so is in the design now, above) or **work** if it is only work:

| | What | Then | Kind |
|---|---|---|---|
| 1 | **"An app that does nothing until paired."** App Review wants an app to work on its own without installing another app, and to be more than minimally useful.[^minimal] The demo mode shows all of it, and the notes for review explain the Mac app, with a link to download it | Notes for review; offer a demo video | design (the demo mode), done |
| 2 | **"Is it a remote desktop?"** A remote desktop client that mirrors specific software must stay on the local network.[^remote] pi² for iPhone is not one: it draws its own screens from data, nothing is rendered on the Mac's screen and streamed, and pairing starts on the Mac. If App Review read it as one, the relay path, which decision 1 requires, would be refused; this cannot be designed around except by staying a native app, which it is | Say so plainly in the notes for review; if refused, appeal with the design's screens | design, done; a risk to know of |
| 3 | **"It approves commands on my Mac."** No guideline forbids it: the phone runs no code ([9.3](#93-nothing-app-review-refuses-on-sight)); what it starts runs on the person's own Mac, with their permission, and the risky answers need Face ID. The notes for review say what a card does and that nothing happens without the person | Notes for review | work |
| 4 | **Login and accounts**: pi² has none, so there is no account to delete;[^deletion] Unpair this iPhone deletes what the relay keeps of the device | — | design, done |
| 5 | **The privacy label and policy.** "Collect" means data sent off the device that the developer can reach for longer than serving the request.[^labels] The relay keeps ids, public keys, push tokens and, for a day, sealed items it cannot open; the label is likely "Identifiers", not linked to the person and not used for tracking, and the policy says what [5.3](#53-the-relay) says. Settled with the owner then | A policy page; the label's answers in App Store Connect | work |
| 6 | **Export compliance.** The app uses encryption: Noise (a published specification) over Curve25519, ChaCha20-Poly1305 and SHA-256, HPKE (RFC 9180) and ECDSA P-256, all from CryptoKit; nothing proprietary. Apple's tables put standard algorithms not provided by the system at "a French declaration", and proprietary ones at a US classification (CCATS) as well;[^exportdocs] the algorithms are the system's, the protocol is pi²'s composition of them, so App Store Connect's questions decide which. Either way `ITSAppUsesNonExemptEncryption` is set in `Info.plist` so that each build does not ask,[^exportkey] and a yearly self-classification report may be due[^export] | Answer App Store Connect's questions; a French declaration if sold in France; the yearly report if asked | work, already met for TestFlight by P14's key |
| 7 | **The relay as a service for strangers.** Cost for each person: about a cent a month at a thousand people ($10 in all), about eight cents if they are ten times as busy ([6.2](#62-what-the-relay-costs)). Abuse: App Attest and the limits of each pairing ([6.6](#66-abuse-and-cost)). Uptime: Cloudflare's; a status page, an alert when the relay fails, and the app saying so plainly ([6.5](#65-when-the-relay-is-down-or-the-person-wants-none)) | Monitoring that counts without logging content; a status page | work (the many-pairings design is done) |
| 8 | **Whether it is paid for.** Free costs a few dollars a month at a thousand people. If it is charged for, a charge inside the iPhone app for what the app unlocks must go through Apple's in-app purchase,[^iap] and an app that also sells elsewhere must offer it in the app too;[^multiplatform] the relay would then take a signed proof of purchase in `hello`'s `ext` ([5.3](#53-the-relay)) and give a pairing its limits from it | Products in App Store Connect; checking Apple's signed transactions at the relay | work, with the hook in the protocol now |
| 9 | **The Mac app for people who are not its author.** It is given out signed with a Developer ID, notarised, outside the Mac App Store, and that need not change: the iPhone app on the App Store and the Mac app from pi²'s site are separate distributions. What it needs is onboarding a stranger can follow (Devices, pairing, what the relay is), and the preview switch gone | The Mac app's first run and Devices page written for anyone | work |
| 10 | **Support.** People need a way to reach the developer; an app's support URL must have one[^devinfo] | A support page, an address, a list of known problems | work |
| 11 | **The listing**: description, screenshots (from the demo mode, which shows no real data), age rating, category, notes for review | App Store Connect | work |

What would have forced a redesign had it been left: pairing by account, a relay for one, content readable at the relay, no demo mode, a page loaded from the Mac, private APIs, a screen mirror. None is left.

## 10. Testing with no phone in hand

**A relay on this Mac.** `relay/` runs locally under Cloudflare's own local runtime (`wrangler dev`, Miniflare[^cfvitest]) on the loopback interface, with a stand-in for Apple's push service that records the pushes it is given instead of sending them. It needs no Cloudflare account and touches neither of pi²'s relays.

**The simulator against a throwaway copy's engine.**

- `scripts/test-copy start <suffix> --remote` (P13) starts a local relay for the copy, then a copy whose engine starts pi² Remote in its **loopback mode**: it connects to that relay only, listens on 127.0.0.1 only for the `home` path, advertises nothing on Bonjour, registers for no push, and keeps its keys in a file in the copy's data folder. Loopback is not a local network, so nothing asks macOS for the Local Network privilege,[^lnp] and the copy's own rules ([CONTRIBUTING.md](../CONTRIBUTING.md#testing-safely)) hold: no permission prompt, nothing of the installed pi² touched. `stop` stops the local relay too. A development build's pi² Remote has no other mode.
- `scripts/test-copy pair <suffix>` opens a pairing through the copy's engine with the test copy's key, confirms it itself, and prints the `pi2://pair?…` URL; `xcrun simctl openurl booted '<url>'` hands it to the simulator's app, which pairs without scanning, over the local relay.
- The simulator has no Secure Enclave and no App Attest: a debug build of the phone makes its keys in software when `SecureEnclave.isAvailable` is false, and says so on screen; the local relay, and only it, takes a join without an attestation when started for tests. A release build of the phone has no such path, and neither of pi²'s relays takes one. Face ID is the simulator's own (Features › Face ID). Pushes are tried with `xcrun simctl push` and a payload the local relay's stand-in recorded, which runs the notification service extension.
- `scripts/test-copy relay-down <suffix>` and `relay-up` stop and start the local relay, to try [6.5](#65-when-the-relay-is-down-or-the-person-wants-none).

**What CI builds and runs**:

- the relay's tests (the Workers Vitest integration, locally, on Linux): the protocol, hello and challenges, register, join with a stand-in attestation checker, the routing, the mailbox and its expiry, the limits, pushes to the stand-in, revocation (P8); and that its configuration keeps logs off and its code writes nothing to the console (P15);
- **the check that the relay sees only sealed bytes** (P15): a session between pi² Remote in loopback mode and a RemoteKit test client, through a local relay built with a recorder that keeps every message, item and push it handles; the session sends known marker strings in every place content can be (a message, a transcript, a notification's text, a secret's value, a file preview, a sealed item); the check fails if any marker appears in what the relay recorded, in any encoding the test tries (UTF-8, UTF-16, base64), and if any data message is not a valid Noise message of that session;
- the shared targets' tests on macOS, and on the iOS simulator; RemoteKit's Noise against the published test vectors (P6);
- the iPhone app and its extensions built for the simulator, with its unit tests;
- the engine's tests for devices (`engine/test/devices.ts`, P5): pairing, attach, the device table for every handler, presence signatures (good, stale, replayed, wrong method or params, wrong key), sealed items from the mailbox, the log, revocation, the events never sent, and secrets never sent, with a stand-in for pi² Remote written in the test;
- a protocol test (P10): pi² Remote in loopback mode against an engine started as the engine's tests start one, a local relay, and a RemoteKit client in a test program that pairs, attaches, sends a request of each device class, moves from the relay path to the home path and back mid-answer, and takes its mailbox.

**What only a real phone can show**: the Secure Enclave, Face ID and App Attest; real pushes, how late they come, and the notification service extension's time; the Local Network prompts (the simulator does not have local network privacy[^lnp]); Bonjour on a real network; a mobile network, and moving between it and Wi-Fi mid-answer; how much time iOS gives a notification's action; a Live Activity's look and updates; how often widgets are redrawn; battery and data; what the Lock Screen shows. P34 and P35 try these on the owner's phone, with the owner, and write what they found here.

## 11. What the Mac cannot check

The engine checks what reaches it. About a phone and the relay, these lie outside, and nothing in the epic may claim otherwise:

- **That a device's keys are where they should be.** The Mac takes the public keys the phone sends at pairing. App Attest, checked by the relay, says a genuine pi² for iPhone joined; the Mac takes the relay's word for it, and cannot tell a key in the Secure Enclave from one in software.
- **Whose face.** A presence signature proves that the phone's enrolled Face ID passed. It cannot prove whose face is enrolled, or that the passcode that guards enrolling is strong.
- **What the phone keeps, and shows.** The Mac cannot see the phone's cache, its screenshots, its delivered notifications, its Lock Screen setting, or whether it is jailbroken.
- **Who holds an unlocked phone.** Every request but Face ID's is taken from whoever has the paired phone unlocked.
- **What the relay does with what it sees.** The channel and every sealed item are end to end, so the relay cannot read or change them unnoticed; but it can delay or drop them, see their sizes and times, and learn from those when the person works. The Mac and the phone cannot tell a relay that drops nothing from one that drops a little, beyond the acknowledgements of [5.8](#58-resuming-and-moving-between-paths). The same holds for Cloudflare.
- **That a push arrived.** Apple's push service is best effort;[^apns] a need answered nowhere stays under Needs you on the Mac, as today.
- **When something was written.** `at` in a sealed item is the phone's clock; the engine bounds it with its own (24 hours, and five minutes of difference besides).
- **What [projects.md section 11](projects.md#11-what-the-engine-cannot-check) already says** stays true: an agent's command can still write the data folder or start an engine of its own; the device rules do not sandbox commands.

## 12. The later issues

Thirty-six issues, in the roadmap's steps: the relay added five to the first draft's thirty, and planning for the App Store adds the demo mode. "Waits for" is what must be merged first; "owns" is what no other issue changes while it is open, so issues built side by side do not collide. Each issue updates the part of this page it built if the build had to differ, in the same pull request.

### 12.1 Who owns what several issues share

| Shared piece | Owner | Until then, and how others plug in |
|---|---|---|
| The device lists in `answers.ts`, `deviceMay`, `FOR_THE_HELPER`, and the start-up check | P5 | Every later issue that adds a request places it in the lists and tests its refusal from a device |
| `pi2.devices`, `pi2.deviceNonces`, `pi2.deviceLog`, `summarize`, the `devices` and `device` events | P5 | An issue that lets a device send a new request adds its `summarize` line |
| Presence verification in the engine | P5 | P17 signs; P22 signs from a notification |
| `remote.*` requests and the `remote` event | P5 | P10 adds `remote.mailboxIn`; P20 adds the event's `push` |
| `RemoteKit`'s channel and sealing (Noise, HPKE, framing, the pairing payload, `pair`, `attach`, `resume`, `presence`) | P6 | Others use it; a change they need is made in its own pull request by the issue that needs it |
| `RemoteKit`'s relay client | P10 | P12, P22, P23 use it |
| The relay: `relay/` (code, its tests, its configuration) | P8 | P20 adds the APNs client in `relay/src/apns.ts`; P15 adds the recorder in `relay/test/` |
| The relay's deployment: `.github/workflows/relay.yml`, the environments, `docs/relay.md` | P9 | — |
| `PiModels` | P2 | Other issues add types beside their own feature's |
| `EngineKit` and `EngineTransport` | P3 | P12 adds the channel's transport in `iphone/`, not in EngineKit |
| `TranscriptKit` and `app/Web/transcript`'s narrow layout | P4 | P18 and P29 use it |
| `app/Package.swift` | each target's issue adds its own lines | Conflicts there are lines added side by side; keep both |
| The `iphone/` Xcode project, its targets and signing | P12 | P12 makes the project with folders Xcode keeps in step by itself, so a source file added in a folder never changes `project.pbxproj`. A new target changes it: P21 (notification service), P31 (widgets, with the Live Activity), P33 (share); they land one at a time |
| Identifiers, capabilities, provisioning profiles | P14 | Until P14, everything runs against the local relay with software keys |
| `scripts/test-copy --remote`, `pair`, `relay-down`, `relay-up`; the iPhone CI workflow | P13 | Until P13, protocol tests run from P10's test program |
| The phone's store (cache, Outbox, protection, wiping) | P23 | Earlier screens keep state in memory only |
| `DemoTransport`, the demo recording and its script, the **Demo** bar | P36 | Every screen issue is drawn in the demo mode as well as against a copy; one whose screen needs a request the script does not answer adds that answer, in `iphone/Sources/Demo/Script/` |

### 12.2 Each issue

**Step 0: design and contract**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P1 A security reading of this contract | A second agent's reading: pairing, keys, Noise and its use, attach, presence, the device table, sealed items, the relay's knowledge and limits, what a lost phone keeps; findings as review comments, and changes to this page agreed by the owner | The owner's agreement of this page | Nothing outside its findings | Every finding is answered on the pull request that makes this page, or filed |

**Step 1: foundations, side by side**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P2 Shared models | `PiModels`; `pi2-client-check` and its recorded session | P1 | `app/Sources/PiModels`, `app/Sources/pi2-client-check`, its fixture | The Mac app builds on `PiModels`, the check passes, nothing else changed |
| P3 The engine's client in a package | `EngineKit`, `EngineTransport` and the Unix socket transport; `EngineClient` on top | P2 | `app/Sources/EngineKit`, `EngineClient.swift`, `EngineSocket.swift` | `pi2-client-check` passes unchanged; a copy's pictures match |
| P4 The conversation page for both | `TranscriptKit` split; the UIKit view; the page's narrow layout | P2 | `app/Sources/TranscriptKit`, `app/Web/transcript` (narrow rules), `pi2-transcript-check` | The Mac's check and pictures unchanged; the page drawn at 390 points in a test |
| P5 Devices in the engine | [Section 3](#3-pairing)'s engine side, [section 4](#4-who-is-speaking) whole, [5.6](#56-the-messages) and [5.7](#57-what-is-never-sent-to-a-phone), starting pi² Remote | P1 | `engine/src/devices.ts`, `engine/src/remote.ts`, the device lists in `answers.ts`, `engine/test/devices.ts` | Its tests of [10](#10-testing-with-no-phone-in-hand) pass with a stand-in helper |
| P6 The channel and sealing | `RemoteKit`: Noise (IKpsk2 and KK, 25519, ChaChaPoly, SHA-256), framing, HPKE items, the pairing payload, `pair`, `attach`, `resume`, `presence` | P1 | `app/Sources/RemoteKit` (but `Relay/`), its tests and the Noise test vectors | The published vectors pass; a pair and a KK session run between two test ends |
| P7 pi² Remote | The helper ([5.5](#55-which-program-holds-them)): the `home` path (TCP, Bonjour), loopback mode, its keys, the engine connections, attach, passing lines; its PeerKit requirement; embedding it in the app's bundle | P5, P6 | `app/Sources/pi2-remote` (but `Relay/`), the helper's requirement in `PeerKit`, `app/build.sh`'s lines for it | A test client attaches over loopback; a copy's helper never asks macOS for anything |
| P8 The relay | `relay/`: the Worker and the pairing's Durable Object with hibernating sockets ([5.3](#53-the-relay)): hello and challenges, register, join with App Attest, routing, the mailbox, limits ([6.6](#66-abuse-and-cost)), revocation; logs off; tests with the Workers Vitest integration | P1 | `relay/` (but `src/apns.ts`) | Its tests pass locally and in CI |
| P9 The relay's deployment | `relay/wrangler.jsonc`'s two environments, `.github/workflows/relay.yml` (test on every pull request; deploy when the owner runs it), the spending limit's instructions, `docs/relay.md` with the owner's list of [6.4](#64-what-the-owner-sets-up-once) | P8 | `relay/wrangler.jsonc`, `.github/workflows/relay.yml`, `docs/relay.md` | The owner, following `docs/relay.md`, deploys the development relay, and a test client registers there |
| P10 pi² Remote's relay end | `RemoteKit/Relay` (the client) and pi² Remote's use of it: register, join windows, the device list, the mailbox both ways (`remote.mailboxIn`), reconnecting; the protocol test | P7, P8 | `app/Sources/RemoteKit/Relay`, `app/Sources/pi2-remote/Relay`, the protocol test | The protocol test of [10](#10-testing-with-no-phone-in-hand) passes in CI |
| P11 The Devices page on the Mac | Settings › Devices: the preview switch, Reach from an iPhone, Reach through pi²'s relay, the home path, the relay's address and state, pairing with the QR code and the digits, the list, rename, revoke, accept a new Face ID key, the log, Forget this Mac at the relay | P5 | `app/Sources/pi2/DevicesSettings.swift`, its tab in `SettingsView.swift` | Every state drawn in a copy; pairing confirmed through it with a test client |
| P12 The iPhone app's shell | `iphone/`: the project, development signing, the first screen, scanning, pairing over the relay or home, the keys ([3.2](#32-the-keys)), App Attest, both paths, attach, the connection's states, an empty list | P3, P6, P10 | `iphone/` (project, `App/`, `Pairing/`, `Connection/`, `Keys/`) | Pairs with a copy from the simulator through the local relay and shows "Connected" |
| P13 Testing with no phone | [Section 10](#10-testing-with-no-phone-in-hand): `--remote` with a local relay, `pair`, `relay-down`, `relay-up`, the simulator script, the iPhone CI workflow, `docs/development.md`'s section | P10, P12 | `scripts/test-copy`'s remote commands and `scripts/test-test-copy`'s cases for them, `scripts/iphone-sim`, `.github/workflows/iphone.yml` | CI builds and tests the phone on every pull request that touches it |
| P14 Signing and TestFlight | [9.1](#91-given-out-testflights-internal-testing): identifiers, capabilities (push, App Attest, Keychain sharing), profiles, test information, `ITSAppUsesNonExemptEncryption`, the privacy policy's link and the contact in the app's settings ([9.3](#93-nothing-app-review-refuses-on-sight)), the upload script, `docs/releasing.md`'s section | P12 | `scripts/iphone-release`, the entitlements files, `docs/releasing.md`'s iPhone section | A build reaches the owner's TestFlight; a release Mac build carries pi² Remote signed with its profile |
| P15 The relay sees only sealed bytes | The recorder, the marker session and its check, the logs-off and no-console checks ([10](#10-testing-with-no-phone-in-hand)) | P10 | `relay/test/sealed.test.ts`, the recorder, the marker session's client | The check runs in CI and fails when a marker is planted in clear |

**Step 2: the first useful release, on any network**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P16 The projects list | The list with Needs you on top, the connection bar, chats, More, search | P12 | `iphone/Sources/Home/` | Drawn against a copy's demo projects in both appearances |
| P17 Needs you, answered | Every kind of card, answered; Face ID and the presence signature where [4.2](#42-what-a-device-may-send) asks | P5, P12 | `iphone/Sources/Needs/`, `iphone/Sources/Presence/` | Each kind answered from the simulator against a copy; the engine refuses a Face ID one without it |
| P18 The orchestrator's conversation | The transcript page, sending, dictation, photos and the camera, stop, queued messages, the outgoing chips | P4, P12 | `iphone/Sources/Conversation/` | A conversation read live and written to from the simulator through the local relay |
| P19 The hub, Now and the Dashboard | The tab bar, Now, the Dashboard's pages | P16 | `iphone/Sources/Hub/`, `iphone/Sources/Dashboard/` | Drawn against a copy's demo hub |
| P36 The demo mode | [9.4](#94-the-demo-mode): `DemoTransport`, the recording made from the scripted demo model and the script that answers, the **Demo** bar, Try it without a Mac, local notifications of every kind; a test that opens every screen in it | P3, P12 | `iphone/Sources/Demo/`, `scripts/demo-recording`, its fixture | Every screen of the design opens in the demo mode with no network, in the simulator, and the test runs in CI |

**Step 3: with the app closed, and the Mac out of reach**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P20 Pushes through the relay | The relay's APNs client (the token, HTTP/2, sandbox and production, the push limits); the engine's choice of what to push ([section 7](#7-notifications)); pi² Remote's sealing of it; push tokens | P8, P10 | `relay/src/apns.ts`, the push part of `engine/src/remote.ts`, `app/Sources/pi2-remote/Push` | A copy's need reaches the local relay's stand-in sealed; one real push reaches the owner's phone from the development relay |
| P21 The notification service extension | Opening `sealed`, the category and thread, the store, background pushes that take notifications away | P20 | `iphone/NotificationService/`, `iphone/Sources/Push/` | A recorded push, given to the simulator, shows its text and buttons |
| P22 Notification actions | [Section 7](#7-notifications)'s categories and actions, delivering in the background, the mailbox when the Mac is away, Face ID by opening the app | P17, P21 | `iphone/Sources/Notifications/` | Each kind's buttons answer a copy's need, over the local relay and, with the copy's relay end stopped, through the mailbox |
| P23 The Mac out of reach | The phone's store, dated; the Outbox; the mailbox's state and items; file protection; what is kept and wiped ([3.6](#36-revoking-and-a-lost-phone)) | P10, P12 | `iphone/Sources/Store/`, `iphone/Sources/Outbox/` | A copy stopped and started again: the phone shows the last state, then sends its Outbox |
| P24 Moving between paths | Trying the Mac's addresses, `resume`, moving a session from relay to direct and back mid-answer ([5.8](#58-resuming-and-moving-between-paths)) | P7, P10, P12 | `iphone/Sources/Connection/Paths.swift`, the session buffer in `app/Sources/pi2-remote/Session` | The protocol test moves mid-answer and loses no line |

**Step 4: the rest of the board**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P25 Work | The list, a piece of work, giving it to an agent, filing | P19 | `iphone/Sources/Work/` | Against a copy's demo work, kept by pi² and with `PI2_GH` |
| P26 A pull request | Checks, findings, files, one file's diff, merge with Face ID, send back | P25 | `iphone/Sources/PullRequest/` | Against `PI2_GH`'s stand-in |
| P27 Agents, Rules, Notes, Branches | The board's other tabs and templates, with Face ID where asked | P19 | `iphone/Sources/Board/` | Each drawn and changed against a copy |
| P28 Settings, limits, usage, schedules | A project's settings and limits, the plan's windows, today's spending, schedules, the app's settings a phone may change | P19 | `iphone/Sources/Settings/`, `iphone/Sources/Usage/` | Each drawn and changed against a copy |
| P29 Agents' conversations, and the rest | An agent's own conversation, other conversations, chats, the archive, background commands; a new project from a folder the Mac offers; `projects.folders` and `files.preview` in the engine | P18 | `iphone/Sources/Conversations/`, `engine/src/folders.ts` | Each opened from the simulator; `files.preview` refuses outside the folder |

**Step 5: what only a phone can do**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P30 Live Activity and the Dynamic Island | For a followed project: started on the phone, updated by the relay with numbers only ([7](#7-notifications)), dated | P20, P31 | `iphone/Widgets/LiveActivity/`, the Live Activity part of `relay/src/apns.ts` | Started, updated from the local relay's stand-in and ended, in the simulator |
| P31 Widgets | Needs you, Who is working, Today's spending, from the app's store | P21, P23 | `iphone/Widgets/` (the extension) | Drawn from a stand-in store in every size |
| P32 Shortcuts and Siri | App Intents: ask an orchestrator, what needs me, stop a project | P18 | `iphone/Sources/Intents/` | Each run from the Shortcuts app in the simulator |
| P33 The share sheet | Sending a link, text, photo or file to an orchestrator or agent | P18 | `iphone/ShareExtension/` | A link and a photo sent from the simulator's Safari and Photos |

**Step 6: before others use it**

| Issue | Builds | Waits for | Owns | Done when |
|---|---|---|---|---|
| P34 A second security reading, and a lost phone tried | The whole read again as built, the Noise implementation and the relay above all; a revoked and a lost phone tried on the owner's phone, on a mobile network | P1 to P33 | Its findings, and [section 11](#11-what-the-mac-cannot-check) | Findings fixed or filed; [3.6](#36-revoking-and-a-lost-phone) shown true on a real phone |
| P35 Battery, data and the relay's cost measured | A day's battery and data on the owner's phone; the greeting's size; the pushes' delays; the relay's requests and GB-seconds for a week, against [6.2](#62-what-the-relay-costs) | P22, P24 | Its measurements, in [5.9](#59-battery-and-data) and [6.2](#62-what-the-relay-costs) | Numbers written here, and issues filed for what costs too much |

An Apple Watch glance and an iPad layout are not issues of this epic; if wanted, each is filed as an idea once step 2 is in use.

## 13. Decisions this contract made

1. **One table decides what a device may send** ([4.2](#42-what-a-device-may-send)), checked on every request of a device connection whatever its class, and on every sealed item; every handler is placed in it, or the engine will not start.
2. **Face ID is a signature, not a flag**: the key that signs asks for Face ID, so the engine checks a signature over that one request, fresh and used once.
3. **One channel over two paths**: the relay is the path that must always work; direct is an optimisation with the same keys, handshake and messages, chosen when the two can see each other, and a session moves between them.
4. **Noise, not TLS**, because the channel must run inside a WebSocket as well as over TCP, either end in either role, between ends that already know each other's keys; implemented once, in RemoteKit, against the published test vectors.
5. **The device key in the Secure Enclave binds the channel key, which cannot be there**, by signing the handshake hash at every connection.
6. **pi² Remote holds both paths, the keys and the channels**, started by the engine and living as long as it; the engine stays the judge ([5.5](#55-which-program-holds-them)).
7. **The engine's own requests and events are carried as they are**, filtered in the engine both ways.
8. **The relay can read nothing**: channels are end to end, mailbox items and pushes are sealed with HPKE for one reader, no category or kind is visible on a push, and the relay logs nothing of them; the one exception is a Live Activity's numbers, which the person turns on.
9. **The relay serves only genuine pi² for iPhone**: a pairing is pending until a phone with an App Attest attestation and the QR code's token joins it.
10. **The relay keeps a small mailbox**, 24 hours, so that an answer written while the Mac sleeps, or a need while the phone is away, is not lost.
11. **Pushes come from the relay**, with pi²'s push key, not from iCloud.
12. **Pairing only on the Mac**, with a five-minute code and six digits worked out from the channel, confirmed by a click in the app; on any network.
13. **A new Face ID key must be accepted on the Mac.**
14. **Every notification button asks for the phone to be unlocked**; the Face ID ones open the app.
15. **A notification says who, what kind, which project and the card's short line**, secrets replaced, all inside the seal.
16. **The phone's cache is small, protected and wiped.**
17. **Moves before changes** in the shared package, proven by a recorded session replayed against the client.
18. **Throwaway copies use a relay on the same Mac and listen on loopback only**, so testing asks macOS for nothing and touches neither of pi²'s relays.
19. **Behind a preview switch on the Mac**, as projects were, until the owner says otherwise.
20. **Built for the App Store, given out by TestFlight**: pairings are keys, not accounts; the relay serves many pairings with nothing of the owner's in it; public APIs only, the page in the bundle, IPv6; [9.2](#92-nothing-assumes-one-person) and [9.3](#93-nothing-app-review-refuses-on-sight).
21. **A demo mode through its own transport**, so a reviewer, and a person before pairing, see every real screen against canned data with no Mac ([9.4](#94-the-demo-mode)).
22. **The phone can unpair itself**, which deletes what the relay keeps of it, with or without the Mac ([3.6](#36-revoking-and-a-lost-phone)).
23. **The relay's `hello` has room for a proof of purchase** (`ext`), unused, so that charging for the relay later needs no new protocol.

## 14. Questions for the owner

Beyond decision 3, still open in [section 2](#2-the-decisions-and-where-each-lives); the owner has answered 1 and 2. The page is written as if each recommended answer were given; each can be answered yes, or changed.

1. **The way across networks.** *Recommended:* (a), a relay pi² runs on Cloudflare Workers with Durable Objects, end-to-end encrypted, on the Paid plan ($5 a month, with a spending limit), about $10 a month for a thousand people ([section 6](#6-across-any-two-networks-the-ways-compared)). The owner sets up once what [6.4](#64-what-the-owner-sets-up-once) lists.
2. **Pushes.** *Recommended:* from the relay, with the content sealed for the phone; iCloud is not used.
3. **The channel's protocol.** *Recommended:* Noise, implemented once in RemoteKit on CryptoKit's primitives and checked against the published test vectors. The other way is TLS 1.3 through Apple's open-source SwiftNIO and its TLS package, which can run TLS inside a WebSocket but adds two packages and BoringSSL to both apps.
4. **The helper.** *Recommended:* pi² Remote, a helper app inside pi²'s bundle, started by the engine, holds both paths and the keys; the home path asks macOS for Local Network once, by pi²'s name, and can be turned off so that nothing is asked.
5. **What asks for Face ID.** *Recommended:* the rows marked Face ID in [4.2](#42-what-a-device-may-send); and a Face ID key enrolled again works only once accepted on the Mac.
6. **What the phone keeps, and what a notification says.** *Recommended:* the last state and the last 300 entries of at most 20 conversations of the last seven days, readable only while unlocked and wiped on revocation or after 30 days without the Mac; a notification names the agent, the kind, the project and the card's short line, with every secret the Mac knows replaced.
7. **A Live Activity's numbers.** *Recommended:* allow a Live Activity, which the person turns on for a project, to be updated by the relay with counts only (working, needing the person, finished), which the relay and Apple can read; without it, a Live Activity changes only while the app runs.
8. **How many devices, and the oldest iPhone.** *Recommended:* up to five devices; iOS 18 or later on an iPhone with Face ID.
9. **An Xcode project in the repository.** *Recommended:* one, in `iphone/`, holding only the app's shell and its extensions, with all shared code in `app/Package.swift`'s targets, and folders Xcode keeps in step by itself so that adding a file never touches the project file.

## Notes

[^se]: Apple, [Protecting keys with the Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave): it "works only with NIST P-256 elliptic curve keys" and "can't encode preexisting keys".
[^passcode]: Apple, [kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessiblewhenpasscodesetthisdeviceonly): accessible only while unlocked, "never migrate to a new device", and "Disabling the device passcode causes all items in this class to be deleted."
[^biocurrent]: Apple, [SecAccessControlCreateFlags.biometryCurrentSet](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/biometrycurrentset): "The item is invalidated if … the user re-enrolls for Face ID."
[^attest]: Apple, [Establishing your app's integrity](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity): App Attest makes a key in the Secure Enclave and has "Apple servers … certify that the key belongs to a valid instance of your app"; the attestation embeds the hash of a one-time challenge from the server. [DCAppAttestService](https://developer.apple.com/documentation/devicecheck/dcappattestservice) is available from iOS 14.
[^noise]: Trevor Perrin, [The Noise Protocol Framework](https://noiseprotocol.org/noise.html), revision 34: the handshake patterns IK and KK and the `psk2` modifier (sections 7.5, 9.4), the 25519 DH functions, ChaChaPoly and SHA256 (section 12), a maximum message length of 65,535 bytes (section 3), and channel binding by the handshake hash (section 11.2).
[^wireguard]: WireGuard, [Protocol & Cryptography](https://www.wireguard.com/protocol/): built on Noise_IKpsk2.
[^lnp]: Apple, [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy): "All Bonjour operations require local network access"; on macOS "The exception for launchd daemons doesn't apply to launchd agents", and macOS asks for the responsible app; an iOS app in the background with the privilege undetermined is denied without the alert; a local network is one on a broadcast-capable interface, "but not cellular (WWAN) or VPN"; "The simulator doesn't support local network privacy."
[^hpke]: Apple, [HPKE](https://developer.apple.com/documentation/cryptokit/hpke): hybrid public key encryption as RFC 9180 describes it, which "optionally incorporates sender authentication".
[^dows]: Cloudflare, [Use WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/): with the Hibernation WebSocket API "Clients remain connected while the Durable Object is not in memory" and "Billable Duration (GB-s) charges do not accrue during hibernation"; and [Lifecycle of a Durable Object](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/).
[^cflogs]: Cloudflare, [Workers Logs](https://developers.cloudflare.com/workers/observability/logs/workers-logs/): observability is on by default for new Workers; a fetch's invocation log records its method and URL, and invocation logs can be turned off.
[^dopricing]: Cloudflare, [Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/): Free plan 100,000 requests and 13,000 GB-s a day, failing past them; Paid plan 1 million requests a month then $0.15 a million, 400,000 GB-s then $12.50 a million; "a 20:1 ratio is applied to incoming WebSocket messages"; "no charge for outgoing WebSocket messages"; objects "idle and eligible for hibernation are not billed for duration".
[^cfworkers]: Cloudflare, [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/): the Paid plan is "a minimum charge of $5 USD per month", including Durable Objects use; "There are no additional charges for data transfer (egress)"; a WebSocket connection to a Worker is charged as one request, and "WebSocket messages routed through a Worker do not count as requests".
[^cfspend]: Cloudflare, the spending limits and e-mail alerts named on the [Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/) and [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/) pages.
[^cfsecrets]: Cloudflare, [Secrets](https://developers.cloudflare.com/workers/configuration/secrets/): "encrypted text values" attached to a Worker, for "API keys and auth tokens".
[^cfvitest]: Cloudflare, [Vitest integration](https://developers.cloudflare.com/workers/testing/vitest-integration/): runs tests "inside the Workers runtime", "fully-locally using Miniflare".
[^turn]: Cloudflare, [TURN Service](https://developers.cloudflare.com/realtime/turn/) and [Realtime pricing](https://developers.cloudflare.com/realtime/pricing/): $0.05 a GB of egress, "The first 1,000 GB each month is free", shared with the SFU.
[^fly]: Fly.io, [Resource pricing](https://fly.io/docs/about/pricing/): "The smallest always-on app costs $2.19 per 30 days"; outbound data $0.02 a GB in North America and Europe; "New organizations don't have a free tier".
[^libp2p]: Protocol Labs, [NAT hole punching measurement campaign](https://github.com/probe-lab/network-measurements/blob/main/results/rfm15-nat-hole-punching.md): "The hole punching success rate is around 70%".
[^turnpct]: LUMND, [The "20% of calls need a relay" number](https://www.lumnd.com/insights/webrtc-turn-relay-percentage/), tracing the figures to their sources: 17.7% of peer-to-peer calls through TURN in ten million appear.in records (2017), 22% of conferences at callstats.io (2016), and nothing comparable published since.
[^tsnat]: Tailscale, [How NAT traversal works](https://tailscale.com/blog/how-nat-traversal-works): "hard" (endpoint-dependent) NATs need a relay or heavy probing, and carrier-grade NAT puts a second NAT the user cannot configure in the path.
[^ck]: Apple, [CloudKit](https://developer.apple.com/icloud/cloudkit/): "Store private data securely in your users' iCloud accounts".
[^dbsub]: Apple, [CKDatabaseSubscription](https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription): "Because the system coalesces notifications, don't rely on them for specific changes. CloudKit can omit data to keep the payload size under the APNs size limit."
[^cklimit]: Apple, [CKError.Code.requestRateLimited](https://developer.apple.com/documentation/cloudkit/ckerror/code/requestratelimited): CloudKit rate-limits requests and says how many seconds to wait; it publishes no rate.
[^bgpush]: Apple, [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app): "the system doesn't guarantee their delivery … don't try to send more than two or three per hour"; the app then has 30 seconds.
[^apns]: Apple, [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns): APNs is "a best-effort service"; it "stores only one notification per bundle ID" for a device that is offline; `apns-priority` 10 sends "immediately", 5 and 1 may be grouped; `apns-collapse-id` merges notifications.
[^apnskey]: Apple, [Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns): a `.p8` signing key from the developer account, a key id and the team id; tokens are ES256 JSON Web Tokens refreshed at least once an hour; keys can be limited to the sandbox or production environment.
[^payload]: Apple, [Generating a remote notification](https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification): "the maximum payload size is 4 KB (4096 bytes)".
[^nse]: Apple, [Modifying content in newly delivered notifications](https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications): the extension "has only about 30 seconds", runs only for pushes with `mutable-content` and an alert, and is meant among other things to "Decrypt data sent in an encrypted format".
[^bgtime]: Apple, [Extending your app's background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time): five seconds after moving to the background, more on asking with `beginBackgroundTask`.
[^auth]: Apple, [UNNotificationActionOptions.authenticationRequired](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/authenticationrequired): "The action can be performed only on an unlocked device."
[^fg]: Apple, [UNNotificationActionOptions.foreground](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/foreground): "The action causes the app to launch in the foreground."
[^actions]: Apple, [Declaring your actionable notification types](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types): categories and their actions are declared when the app launches; on a choice "the system launches your app in the background"; users "can respond to actions while the device is locked".
[^lapush]: Apple, [Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications): remote updates come from the developer's server over a token-based connection to APNs; and [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities): a Live Activity "can't access the network", lasts up to eight hours, and its data is at most 4 KB.
[^ipv6]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 2.5.5: "Apps must be fully functional on IPv6-only networks." (The guidelines cited here are those last updated on 16 October 2026.)
[^publicapi]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 2.5.1: "Apps may only use public APIs and must run on the currently shipping OS."
[^selfcontained]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 2.5.2: apps "may not … download, install, or execute code which introduces or changes features or functionality of the app".
[^bgmodes]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 2.5.4: "Multitasking apps may only use background services for their intended purposes".
[^demo]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), "Before You Submit": "If your app includes account-based features, provide either an active demo account or fully-featured demo mode, plus any other hardware or resources that might be needed to review your app (such as login credentials or a sample QR code)"; and 2.1(a): a built-in demo mode in place of a demo account "with prior approval by Apple. Ensure the demo mode exhibits your app's full features and functionality."
[^minimal]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 4.2: "If your App doesn't provide some sort of lasting entertainment value or adequate utility, it may not be accepted"; 4.2.3(i): "Your app should work on its own without requiring installation of another app to function."
[^remote]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 4.2.7: a remote desktop app that "acts as a mirror of specific software or services rather than a generic mirror of the host device" must "only connect to a user-owned host device … and both the host device and client must be connected on a local and LAN-based network"; "All account creation and management must be initiated from the host device"; "Thin clients for cloud-based apps are not appropriate for the App Store."
[^deletion]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 5.1.1(v): "If your app supports account creation, you must also offer account deletion within the app"; and [Offering account deletion in your app](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion).
[^privacy]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 5.1.1(i): "All apps must include a link to their privacy policy in the App Store Connect metadata field and within the app in an easily accessible manner", saying what data is collected, its uses, its retention and how to have it deleted.
[^devinfo]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 1.5: "Make sure your app and its Support URL include an easy way to contact you."
[^labels]: Apple, [App privacy details on the App Store](https://developer.apple.com/app-store/app-privacy-details/): "'Collect' refers to transmitting data off the device in a way that allows you and/or your third-party partners to access it for a period longer than what is necessary to service the transmitted request in real time."
[^export]: Apple, [Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations): an app that uses encryption and is distributed outside the U.S. or Canada is an export of encryption software; encryption built into the operating system is typically exempt from documentation; an app using exempt encryption may have to file a year-end self-classification report.
[^exportkey]: Apple, [ITSAppUsesNonExemptEncryption](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption): without the key, "App Store Connect walks you through an export compliance questionnaire every time you upload a new version".
[^exportdocs]: Apple, [Export compliance documentation for encryption](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption): encryption "limited to that within the Apple operating system", no documentation; "an industry standard algorithm, not provided within the Apple operating system", a French encryption declaration (only for France); "proprietary encryption algorithms not accepted by international standard bodies", a US CCATS as well. [Overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance) defines non-standard cryptography as unpublished or proprietary protocols not adopted by a standards body.
[^iap]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 3.1.1: "If you want to unlock features or functionality within your app, (by way of example: subscriptions …), you must use in-app purchase."
[^multiplatform]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 3.1.3(b): content or features bought on other platforms may be used in the app "provided those items are also available as in-app purchases within the app".
[^beta]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 2.2: "Any app submitted for beta distribution via TestFlight should be intended for public distribution and should comply with the App Review Guidelines", and may not be given to testers "in exchange for compensation of any kind".
[^tfoverview]: Apple, [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview): up to 10,000 external testers and up to 100 internal testers ("App Store Connect users with access to your content"); "If you invite external testers, your beta build may require review … A review is required only for the first build"; "You can test a build for up to 90 days."
[^tfinternal]: Apple, [Add internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers): internal testers are App Store Connect users with a role on the team; "Internal testers can download and test all builds for 90 days."
[^tfexternal]: Apple, [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers): external testers "aren't App Store Connect users", invited by e-mail or a public link, up to 10,000 per app.
