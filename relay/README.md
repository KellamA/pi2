# The relay

The relay is the path between a Mac and its paired phones that must always work ([docs/iphone.md 5.3](../docs/iphone.md#53-the-relay), #676): a Cloudflare Worker and one Durable Object for each pairing, which pass sealed bytes they cannot read, keep a small mailbox for an end that is away, and serve only genuine pi² for iPhone. It is written for any number of pairings ([9.2](../docs/iphone.md#92-nothing-assumes-one-person)): nothing of the owner's is in its code, and a deployment is this code with its own settings.

This folder is an owner's path (`.github/CODEOWNERS`): a pull request that changes it waits for the owner's review. Nothing here deploys anything. Deploying is #677 (P9), and waits for the owner ([docs/relay.md](../docs/relay.md)).

## Files

| File | What it holds |
|---|---|
| `src/index.ts` | The Worker: takes a WebSocket at `/v1` and hands it to its pairing's object; refuses a request with an `Origin` (a web page's); counts registrations against their address |
| `src/pairing.ts` | `Pairing`, the pairing's Durable Object: its sockets (hibernating), hello and challenges, register, join, routing, the Mac's requests, `leave`, revocation, deletion, its alarms |
| `src/protocol.ts` | Every message, read strictly; the fixed words of a refusal; builds; what an end signs |
| `src/join.ts` | What a join's attestation is checked against, and what this deployment takes of Apple's category and bundle version |
| `src/attest.ts` | The one import of App Attest's verifier, the engine's own file ([The verifier](#the-verifier)) |
| `src/claims.ts` | `AttestKey`, one object for each App Attest key the relay checked: the pairing and device it is tied to, for a week |
| `src/addresses.ts` | `Address`, one object for each registering address, named by a keyed hash that changes daily: its count |
| `src/mailbox.ts` | The mailbox, in the pairing's SQLite storage |
| `src/limits.ts` | The limits of each end of a pairing, and their counters |
| `src/settings.ts` | The deployment's settings, read and checked |
| `src/bytes.ts`, `src/crypto.ts` | Base64url and the other texts of bytes, read strictly; P-256 keys and signatures, SHA-256, HMAC |
| `src/types.d.ts` | One type the engine's verifier needs that Workers' types say otherwise |
| `test/` | The tests ([Tests](#tests)) |
| `test/protocol/` | The relay as the protocol test runs it: its own Worker with App Attest's stand-in (#678) |
| `test/sealed/` | The relay as the sealed-bytes check runs it, with the recorder at its edge, the check, its markers and allow-list ([The relay sees only sealed bytes](#the-relay-sees-only-sealed-bytes)) |
| `scripts/check-bundle.mjs` | Checks the bundle Wrangler makes for a deploy, without deploying ([The verifier](#the-verifier)) |
| `scripts/isolated.mjs` | Runs Wrangler, Vitest or TypeScript with a throwaway home folder, Wrangler's usage events off, and no Cloudflare credential ([Tests](#tests)) |
| `wrangler.jsonc` | The Worker's configuration for local runs and tests: its objects, logs off, Node's modules off, no settings |

`src/apns.ts` (pushes, #689) is another issue's.

## Tests

```bash
cd relay
npm ci
npm run check         # the type-check, which includes engine/src/appattest.ts as the relay bundles it
npm test              # the tests, inside workerd
npm run check-bundle  # the verifier in the deploy bundle is the engine's file
```

The tests run inside the Workers runtime (workerd, through `@cloudflare/vitest-plugin`), on this computer, with no Cloudflare account; never in Node's `vm` contexts, where the verifier refuses every byte array as another context's. Their settings, in `vitest.config.ts`, are a test deployment's: Apple's sample attestation's team and bundle ids. They move the clock themselves (`vi.setSystemTime`), so nothing depends on how fast the computer is. Vitest prints warnings that `node:inspector` is not available: with Node's modules off (`wrangler.jsonc`), its own optional look for the inspector fails, which changes nothing; no one line of configuration quiets it without turning Node's modules back on for the tests. CI runs all three in the job **Relay (tests)**.

- `protocol.test.ts`: the Worker's door, register and hello with their challenges, builds below the minimum, a second Mac refused and the connected one told, a Mac socket gone quiet replaced, the ten seconds to prove oneself, strict reading.
- `join.test.ts`: join with a stand-in for the verifier: the window, the token, the three tries, what the verifier is asked, Apple's category and bundle version, App Attest keys tied to one pairing and device, the contract's pairing end to end with two App Attest keys, a joined slot added under the engine's id or let go.
- `verifier.test.ts`: the verifier is the engine's file; it runs in workerd; Apple's sample (engine/test/appattest.json) through `join` with the real verifier, and refused for the relay's own client data, at today's time, for another key, and altered.
- `sealed.test.ts`: logs off in the configuration and every environment of it, as Wrangler works each out (no Workers Logs, invocation logs, traces, Issues, Logpush or tail Workers), held to `wrangler.jsonc` and to a copy of the deployments' (`test/sealed/fixtures/deployment.jsonc`, a frozen copy of #821's file at `33bd066`, to be removed once #821 is on main); the test configurations' copies of the runtime settings and objects match the relay's; no use of the console in `src` or the bundled verifier, and nothing written to it through a whole session with every console method watched; the recorder and the check of [The relay sees only sealed bytes](#the-relay-sees-only-sealed-bytes) on a session of the test's own, which passes, and with a marker planted in clear, which fails; and the check's forms and allow-list one by one.
- `routing.test.ts`, `mailbox.test.ts`, `limits.test.ts`, `revoke.test.ts`: routing and its notices; the mailbox, its bounds and its expiry; the limits of each end, an end held off with `busy` and never another, the Mac's revoking never held off, only authenticated traffic counted, text in bytes; `removeDevice`, `leave`, `deletePairing` (with the App Attest key's object failing, and nothing of a removed device passing meanwhile), and pairings deleted when pending or idle.

To run it locally, `npm run dev` with every setting given, as `--var NAME:VALUE` after `--` or in a `.dev.vars` file here (which git ignores); it listens on 127.0.0.1.

**What the tools write and send.** Left to themselves, Wrangler 4.166 writes a device id and logs under the home folder's preferences and sends Cloudflare usage events, and Vitest writes a token under the home folder's application support. `send_metrics: false` in `wrangler.jsonc` turns Wrangler's command events off, but not every event this version sends (`deploy`'s project set-up sends its own). So every script in `package.json` that runs a tool goes through `scripts/isolated.mjs`, which gives it a throwaway home folder for the run, `WRANGLER_SEND_METRICS=false`, and no `CLOUDFLARE_*` variable from the caller; `check-bundle` does the same itself, with `--config`, and passes nothing but `PATH` on. Run the tools through those scripts, not with `npx`, and give any other command of Wrangler's both `WRANGLER_SEND_METRICS=false` and a throwaway `HOME`, in CI too.

## The relay sees only sealed bytes

Decision 8 of the contract ([docs/iphone.md 13](../docs/iphone.md#13-decisions-this-contract-made)): the relay can read nothing. The check that proves it (#683, P15) runs the relay on this computer with a recorder at its edge, and a session of RemoteKit's two ends through it that sends known markers every way the relay carries anything; then it looks for them in everything the relay saw and kept ([docs/development.md](../docs/development.md#the-relay-sees-only-sealed-bytes) says how to run it).

- **The recorder** (`test/sealed/recorder.ts`) stands in front of the relay's own Worker and passes every connection on to it, keeping its request (address and headers), every message in and out, text or bytes, in order, and how each side closed. `dump` reads back what an object keeps: its key-value pairs, its tables, its sockets' attachments. `test/sealed/worker.ts` is the protocol test's relay with the recorder in front and its objects able to `dump`; `GET /recording` gives all of it. It is in `test/` only, so it is in no bundle: `check-bundle` refuses one with an input outside `src`.
- **The marker session** is `pi2-relay-check --sealed` (`app/Sources/pi2-relay-check/Sealed.swift`), with the markers of `test/sealed/markers.json`: the device's name, model and system, the Mac's name, methods, a message, a transcript, a notification's text, a secret's value, a file's preview, a project's name, a line long enough to be cut into frames with a marker across the cut, a request item's answer, a receipt, the Mac's state, the Mac's home and private addresses in `paired`, and a `device` event. Each end checks that every marker reached the other, opened.
- **The check** (`test/sealed/scan.ts`, run by `test/sealed/check.mjs` after the session) fails on any marker in UTF-8, UTF-16 either way, Latin-1, hex either case, base64 and base64url at each alignment, percent and JSON escapes; on any of the ends' private keys, the public keys the relay is never given (the Mac's identity, record and channel keys, the phone's presence, record and channel keys), the pairing's secret, a channel's binding or `pair`'s attestation, as bytes, hex or base64; in every message alone and every socket's bytes run together, every object's storage read back, every file of the relay's local state read raw, and what the local runtime printed. The relay runs at log level `log` for it, and the recording relay writes two fresh canaries with `console.log` and `console.debug` on every run, which the check fails without: so what the relay wrote to the console would be read. Every binary message must be one of the session's Noise messages, a Mac's for one of the session's devices; every item put or kept one of its sealed items; the relay key and device key the only keys the session gave for those fields; and every object with a file in the relay's state read back. It fails too if the recording missed a message of the session, or the storage or the files an item it left, so a recorder that stopped working cannot pass.
- **What the relay may see** is an allow-list in `scan.ts`, of what 5.3 lists: every control message each way with each field's kind (ids, keys, signatures, sealed items, times, counts, builds, fixed words), the headers a connection brings, and every key, field and table the objects keep. A field, header, table or message it does not list fails the check until the list names it, in a pull request the owner reviews. Headers are held to their values too, as URLSession and the local runtime send them, and a connection the relay took must carry `User-Agent` and `Accept-Language`, exactly the relay client's fixed `pi2-relay-client` and `*` (#678's security read, S2): so the system's, which say the program's and the system's versions and the person's languages, fail the check if they come back.
- **The check's own test**: `pi2-relay-check --plant` plants a marker in clear in the channel's bytes (both ways), in an item (in a text, a table row and the files), and in the relay's console (through the recording relay), and the check must find it in each. A marker in a header, the address, a stored key or value, a close's reason or the relay's own texts is shown to be found by `sealed.test.ts`'s tests of the check, not planted in the live run.
- **Not covered yet**: pushes, which the relay sends none of until P20 (#689), whose stand-in for Apple's service hands each request to `Recorder.push` to be checked like the rest; a deployed relay, whose platform (Cloudflare's own logs, its TLS, headers its edge passes on) this check does not reach; `presence`, `resume` and `revoked` lines, and a session id long enough to look for; bytes written as a JSON array of numbers, or compressed.

## The verifier

App Attest's verifier is `engine/src/appattest.ts` (#672, P37), which the engine's pairing claim uses too. The relay imports that very file by its relative path (`src/attest.ts`), and Wrangler bundles it into the Worker: there is one file and no copy. If it ever needs a change to run in a Worker, the change is a pull request of its own to that file, never a fork here.

Three checks hold it so:

- `test/verifier.test.ts` imports the verifier both through `src/attest.ts` and from the engine's path, and checks they are the same functions, one module; and runs Apple's sample through it inside workerd.
- `scripts/check-bundle.mjs` builds the Worker as a deploy would (`wrangler deploy --dry-run`, which uploads nothing) and checks that the bundle's inputs include `engine/src/appattest.ts`, and that every other input is in `relay/src` and holds nothing of a copy: no definition of a name the engine's file exports, no line of its pinned root's base64, no fingerprint, AAGUID or object identifier of its; and that the bundle carries the pinned root's fingerprint exactly once. It catches a copy whose names were changed. It is a tripwire, not a proof: a copy rewritten throughout would pass it, which is what the review of this folder is for.
- `npm run check` type-checks the engine's file as the relay bundles it. Workers' types say `TextEncoder.encode` returns an array over any buffer, where TypeScript's own say an `ArrayBuffer`; `src/types.d.ts` says the latter for the relay, which is what both runtimes do. That is a type only.

The verifier takes only byte arrays made in its own runtime: the relay gives it `new Uint8Array(…)` of what it decoded.

## Settings

Every one is required, and none has a default: a relay missing any, or given one that is not well formed, answers 503 to every connection. `wrangler.jsonc` holds none; the deployments' environments are P9's.

| Setting | What it is |
|---|---|
| `APP_ATTEST_TEAM_ID` | The App ID prefix App Attest checks against: ten upper-case letters or digits |
| `APP_ATTEST_BUNDLE_ID` | The phone app's bundle id |
| `APP_ATTEST_ENVIRONMENTS` | The App Attest environments a join takes: `production`, `development`, or `development,production` |
| `APP_ATTEST_CATEGORIES` | Apple's validation categories a join takes, comma-separated, of 1 to 6 and 10, and `none` to take an attestation that carries none (iOS before 27). For a relay serving TestFlight and App Store builds: `2,4,none`; a development relay for builds signed for development: `3,none` |
| `MIN_BUILD_MAC`, `MIN_BUILD_DEVICE` | The lowest build each role may connect with (6.5: raising them turns old builds off) |
| `ADDRESS_KEY` | A secret of at least 32 characters, from which the day's key for hashing addresses is made |

## The protocol

Everything is inside one WebSocket at `wss://<relay>/v1`. The address carries no id, since a platform's request logs keep URLs. A connection names its pairing in the `Pi2-Pairing` header, only so that the Worker can hand it to that pairing's object; the object takes nothing on its word, and the end's `hello` names the pairing again. A connection without the header is a Mac registering a new pairing.

**Text messages** are one JSON object with one member, named for the message, whose value is an object, written exactly as JavaScript's `JSON.stringify` writes it: compact, no key twice, no escape that need not be one. Anything else is refused. Bytes are base64url without padding, keys are P-256 SPKI DER, signatures 64 bytes (r then s) over SHA-256, ids as RemoteKit writes them (#674's `docs/remotekit.md`, in pull request #767): a pairing's and an item's id 16 bytes, a device's `dev_` and 16 bytes. An App Attest key id is as `DCAppAttestService` gives it, 32 bytes in standard base64.

**Proving.** After `hello` or `register`, the relay answers `{"challenge":"<32 bytes>"}`, and the end answers `{"proof":{"signature":…}}` over the UTF-8 bytes of `pi2-relay-v1`, then, each after a zero byte, what it proves (`mac`, `device` or `register`), the pairing's id (empty at `register`), the device's id (empty for a Mac) and the challenge's text: with its relay key (a Mac) or device key (a phone). A `leave` is signed the same way, with `leave`, over the challenge of the connection it is sent on.

| From | Message | Answer |
|---|---|---|
| A Mac with no pairing | `register { v: 1, build, relayKey, ext? }` | `challenge`, then after its proof `registered { pairing }` |
| The Mac | `hello { v: 1, role: "mac", pairing, build, ext? }` | `challenge`, then `ready { devices: [{ device, online }], left, pending, mail }` |
| A listed phone | `hello { v: 1, role: "device", pairing, device, build, ext? }` | `challenge`, then `ready { mac, mail }` |
| A phone with no slot | `hello { v: 1, role: "device", pairing, build }`, then `join { pairing, deviceKey, attestation, keyId, token }` | `challenge`, then `joined { device }` |
| The Mac | `openJoin { tokenHash, expires }`, `closeJoin {}`, `addDevice { device, deviceKey, attestKeyId }` (the engine's id for the phone, its device key, and the App Attest key the Mac checked), `removeDevice { device }`, `deletePairing {}`, `state { device, id, item }` | `ok { what }` or `refused { what, why }`; a `removeDevice` for a device already gone is `ok` |
| Either | `put { to, id, item, presence? }`, `take {}` | `ok`, or the items as `item { from, id, item, presence }`, a phone's `state { id, item }`, then `taken { count }` |
| A listed phone | `token { apns, environment }`, `leave { signature }` | `ok`; a leave closes the socket |
| Either | `{"ping":{}}` | `{"pong":{}}`, answered without waking the object |

**Notices** the relay sends: to the Mac, `online { device }`, `offline { device }` (also when it sends to a phone not connected), `joined { device, deviceKey, keyId }`, `left { device }`, `anotherMac {}`, `held { device, until }` (a phone closed past a limit, for the Devices page); to a phone, `mac { online }`; to either, `mail {}` when something arrives for it. Past a limit, an end is sent `busy { until }` and its socket is closed.

**Binary messages** are the channel's bytes: a phone's reach the Mac with its 16-byte id in front; the Mac's start with the id of the phone they are for, which the relay takes off. The relay reads nothing past the id. A message is at most 70 KB.

**Refusals** end with `{"refused":{"why":…}}` and the socket closed with that word as its reason; a request of the Mac's or a `put` that is refused leaves the socket open. The words are fixed (`Why` in `src/protocol.ts`); nothing a client sent is ever said back.

## What it decides

Where the contract left something open, or the relay had to choose:

- **The pairing's object is found by a header.** The first message cannot choose the object that holds the socket, since the socket must be accepted by that object to hibernate; so the pairing is named in `Pi2-Pairing` as well, and `hello` must name the same.
- **A join's client data hash** is SHA-256 of the 32-byte challenge followed by the device key's SPKI DER, so the attested copy of the app vouches for this device key on this connection (6.6), as step 4's does for the Mac.
- **What a join takes of Apple's extensions.** The verifier gives the validation category and the bundle version without judging them. The relay takes a category only if the deployment lists it; an attestation with neither (an iOS before 27, which adds both) only if the deployment lists `none`; one with only one of them, never. The bundle version must be a build at or above `MIN_BUILD_DEVICE`.
- **An attested key is tied to one pairing and device.** Each App Attest key the relay checked at a join has an object of its own, named by its id, which records the pairing and device it is tied to. A join whose key is tied elsewhere is refused (`attest-key-taken`). The tie moves with the phone when the Mac adds it under the engine's id, and is untied when the device is removed, leaves, its slot lapses with the window, or the pairing is deleted. Untying is best effort: the socket is closed and the record gone first, and a tie that a failed call leaves behind goes by itself. **A tie lasts a week**: longer than an attestation can be checked (its leaf is valid until about two days after it is made, with a day for a clock that is off), and App Attest attests a key only once, so no newer attestation of the same key can come.
- **A join window** takes three refused joins of any kind (a wrong token, a refused attestation, a key already tied), after which it is closed, and three phones that joined: one more than the engine needs to see a second claim and close the window itself (3.3 step 6). A phone that joined has a slot that carries the channel to the Mac and nothing else until the Mac adds it; the slot goes with the window.
- **Two App Attest keys, and only a phone that joined can be added.** App Attest attests a key once (`DCError.invalidKey` after), so the phone has two: one attested to the relay at `join`, one to the Mac in `pair` (3.2). `addDevice { device, deviceKey, attestKeyId }` carries the engine's id for the phone and the Mac's key, which the relay never saw. The relay finds the phone's joined slot **by its device key** (if the same phone joined more than once, its socket having dropped, the slot whose socket is live, else the latest; the others are let go with their ties), which both attestations bind (SHA-256 of the challenge and the device key here; of the challenge, the device key and the handshake hash at the Mac), and which only that copy of the app holds. It moves its own key's tie from the slot to the engine's id, and records the Mac's key id without tying it, since it never checked that attestation. The phone's socket carries on under the engine's id, so the pairing exchange on it is not cut. A device key that joined no slot of this pairing is refused (`not-joined`): otherwise a "Mac" of someone's own making could list devices of its own making and use the relay with no genuine app at all, which 6.6 rules out. What follows: a phone paired over the home path alone, with the relay out of reach while it paired, has no slot at the relay until it joins a window, which for now means pairing again; and pi² Remote must send `addDevice` before `closeJoin` and before the window expires, which drop the joined slots.
- **A pairing is pending** until its first `addDevice`, and deleted 15 minutes after `register` if none came. Registering needs only a key of one's own, so a pending pairing's Mac has a small allowance (`PENDING_LIMITS`: 10 messages and 64 KB a second, 200 messages and 2 MB a day), every message it sends counts, its control messages included, and past the day's allowance it is held off for the hour, past the pairing's life. A registration costs a row for 15 minutes and a few hundred writes at most. The first pairing fits with room: a few windows opened and closed, a join, the Mac's side of the pairing exchange, `addDevice`.
- **Writes on reconnecting.** The time an end was last connected (for the 60 days) is written at most once a minute, and an alarm writes only what changed, so 50 reconnects of a phone in a minute make a handful of writes (the tests count six: the time once, and the ten seconds' alarm set again at most every ten seconds; on the platform each alarm that fires sets the next, so about twice that).
- **A second Mac** is challenged as any Mac is. One that signs the challenge with the relay key is refused while the connected Mac is alive, and the connected Mac is told (3.4); one that cannot is refused for its signature, and the connected Mac hears nothing, so a stranger who knows the pairing's id cannot raise the alarm.
- **A Mac socket gone quiet.** One that has sent nothing, not even a ping, for 90 seconds (three of its pings) is taken for gone, so that a Mac whose network dropped can connect again; the old socket is closed as `replaced`.
- **A phone that connects again** closes its own older socket.
- **Limits are counted for each end apart**: the Mac, each listed phone, and each phone that has only joined, which gets a much smaller allowance (20 messages and 256 KB a second, 2,000 messages and 16 MB a day) since it carries only the pairing exchange. Past a limit, the relay closes **that end's** socket with `busy { until }`: it never drops a message from the middle of a channel, whose Noise nonces would then break it for good, and a closed socket reconnects and resumes (5.8). Past its day's limit, an end is held off for an hour, and again each hour while it is still past it: a phone's hello is answered `busy` too; the Mac's hello is always taken, but its own counted messages close it again. Once a phone has been added, the Mac's `removeDevice`, `closeJoin` and `deletePairing` are not counted when they take something away (a device that exists, an open window, the pairing), which happens a few times in a pairing's life; when there is nothing to take, they are counted like anything else and write nothing, so that a registrant cannot make the relay write without limit. No end's traffic counts against another, so nothing can keep the Mac from revoking. Only authenticated traffic counts: a message counts once its socket has proved itself; and text counts in bytes.
- **A removed device, or a deleted pairing**, is cut at once: its socket is closed before anything waits on another object, and every message is checked against the pairing's devices as they stand when it arrives, so nothing of it passes in the meantime.
- **No web page.** A request with an `Origin` header is refused (403) before anything is counted or any object woken: a browser always sends one, pi² Remote and the phone send none (#678 and the phone must keep it so), and a page could otherwise make its visitors' browsers register pairings.
- **Waiting sockets.** At most 16 sockets wait to prove themselves in a pairing; a newer one closes the oldest. A socket has ten seconds.
- **Registrations** are counted by an object named by HMAC-SHA256 of the address, keyed with HMAC-SHA256 of `ADDRESS_KEY` over `pi2-address` and the date: the name changes every day, and the object deletes itself after a day.
- **`presence` on `put`** marks an item whose request is a `"face"` one (a widening answer, 4.2): kept an hour, not a day. Every item a phone writes carries a presence signature inside its seal (4.3); the relay sees only the flag.
- **The Mac's `state`** carries the item's id, which its reader needs to open it (HPKE's `info` holds it).

## Not here yet

- **Pushes**: `token` is kept and deleted with its device; `push` is P20's (#689), with `src/apns.ts`.
- **A join without an attestation**, which only a local relay for tests may take ([10](../docs/iphone.md#10-testing-with-no-phone-in-hand)), is P13's (#681) to add when the simulator needs it; this relay takes none.
- **The deployments**: their environments, settings and minimum builds in `wrangler.jsonc`, and the workflow that deploys, are P9's (#677).
