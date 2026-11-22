# The relay

The relay is the path between a Mac and its paired phones that must always work ([docs/iphone.md 5.3](../docs/iphone.md#53-the-relay), #676): a Cloudflare Worker and one Durable Object for each pairing, which pass sealed bytes they cannot read, keep a small mailbox for an end that is away, and serve only genuine pi² for iPhone. It is written for any number of pairings ([9.2](../docs/iphone.md#92-nothing-assumes-one-person)): nothing of the owner's is in its code, and a deployment is this code with its own settings.

This folder is an owner's path (`.github/CODEOWNERS`): a pull request that changes it waits for the owner's review. Nothing here deploys anything. Deploying is #677 (P9), and waits for the owner ([docs/relay.md](../docs/relay.md)).

## Files

| File | What it holds |
|---|---|
| `src/index.ts` | The Worker: takes a WebSocket at `/v1` and hands it to its pairing's object; refuses a request with an `Origin` (a web page's); counts every connection, and registrations, against their address |
| `src/pairing.ts` | `Pairing`, the pairing's Durable Object: its sockets (hibernating), hello and challenges, register, join, routing, the Mac's requests, `leave`, revocation, deletion, its alarms |
| `src/protocol.ts` | Every message, read strictly; the fixed words of a refusal; builds; what an end signs |
| `src/join.ts` | What a join's attestation is checked against, and what this deployment takes of Apple's category and bundle version |
| `src/attest.ts` | The one import of App Attest's verifier, the engine's own file ([The verifier](#the-verifier)) |
| `src/claims.ts` | `AttestKey`, one object for each App Attest key the relay checked: the pairing and device it is tied to, for a week |
| `src/addresses.ts` | The group an address is counted in (an IPv6 address by its /64), and `Address`, one object for each, named by a keyed hash that changes daily: its connections, in memory, and its registrations |
| `src/mailbox.ts` | The mailbox, in the pairing's SQLite storage |
| `src/limits.ts` | The limits of each end of a pairing, and their counters |
| `src/settings.ts` | The deployment's settings, read and checked |
| `src/bytes.ts`, `src/crypto.ts` | Base64url and the other texts of bytes, read strictly; P-256 keys and signatures, SHA-256, HMAC |
| `src/types.d.ts` | One type the engine's verifier needs that Workers' types say otherwise |
| `test/` | The tests ([Tests](#tests)) |
| `scripts/check-bundle.mjs` | Checks the bundle Wrangler makes for a deploy, without deploying ([The verifier](#the-verifier)) |
| `scripts/isolated.mjs` | Runs Wrangler, Vitest or TypeScript with a throwaway home folder, Wrangler's usage events off, and no Cloudflare credential ([Tests](#tests)) |
| `wrangler.jsonc` | The Worker's configuration for local runs and tests: its objects, logs off, Node's modules off, no settings |

`src/apns.ts` (pushes, #689) and the recorder in `test/` (#683) are other issues'.

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
- `addresses.test.ts`: the group an address is counted in, in every spelling, and what is not an address; registrations by /64 and mapped IPv4; connections a minute and an hour, with nothing written, 429 and `Retry-After`, a held address refused by the Worker without asking its object, a household's worst minute.
- `routing.test.ts`, `mailbox.test.ts`, `limits.test.ts`, `revoke.test.ts`: routing and its notices; the mailbox, its bounds and its expiry; the limits of each end, an end held off with `busy` and never another, the Mac's revoking never held off, only authenticated traffic counted, text in bytes, the join windows a minute and their writes; `removeDevice`, `leave`, `deletePairing` (with the App Attest key's object failing, and nothing of a removed device passing meanwhile), and pairings deleted when pending or idle.

To run it locally, `npm run dev` with every setting given, as `--var NAME:VALUE` after `--` or in a `.dev.vars` file here (which git ignores); it listens on 127.0.0.1.

**What the tools write and send.** Left to themselves, Wrangler 4.166 writes a device id and logs under the home folder's preferences and sends Cloudflare usage events, and Vitest writes a token under the home folder's application support. `send_metrics: false` in `wrangler.jsonc` turns Wrangler's command events off, but not every event this version sends (`deploy`'s project set-up sends its own). So every script in `package.json` that runs a tool goes through `scripts/isolated.mjs`, which gives it a throwaway home folder for the run, `WRANGLER_SEND_METRICS=false`, and no `CLOUDFLARE_*` variable from the caller; `check-bundle` does the same itself, with `--config`, and passes nothing but `PATH` on. Run the tools through those scripts, not with `npx`, and give any other command of Wrangler's both `WRANGLER_SEND_METRICS=false` and a throwaway `HOME`, in CI too.

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
- **An address is counted by its group**: an IPv4 address whole, an IPv6 address by its /64 (a home or a phone network is given a whole /64 and may use any address in it, so counting each address would count nothing), an IPv4-mapped IPv6 address (`::ffff:192.0.2.1`) as its IPv4 address. `CF-Connecting-IP` is read strictly, by hand, in every spelling RFC 4291 allows (a zone id is taken off); a request without one that reads as an address is refused with 400 before any object is woken. Cloudflare sets the header on every request from the internet and overwrites a client's own, so no real client lacks one, and one shared count for such requests would be one that a deployment set up wrong fills for everyone. `CF-Connecting-IPv6` is never read, since a client could send its own; so the deployment's zone keeps Pseudo IPv4 off, its default, under which `CF-Connecting-IP` holds the IPv6 address itself. A home given a /56 or a /48, as many are, has many /64s; counting by the /64 is a fence for one place, and the deployment's own rate-limiting rule (#677) sits in front of it.
- **Each address's object** is named by HMAC-SHA256 of its group, keyed with HMAC-SHA256 of `ADDRESS_KEY` over `pi2-address` and the date: the name changes every day, and the object keeps no address. It counts **registrations**, 5 an hour and 20 a day, in its storage, which it deletes a day after the first; and **every connection to `/v1`**, a registration's too, 120 in a clock minute and 1,200 in the last sixty, in memory only, so that a connection costs the relay one call to that object and no write. Past either, the Worker answers 429 with `Retry-After`, the seconds until there is room, and wakes no pairing; pi² Remote waits a minute at least after a 429. A connection refused is not counted, so people behind one address get in as soon as there is room. The Worker's isolate remembers an address held for its connections until the object's time, and refuses it without calling the object, so a flood from one address costs the Worker's own work and nothing more; an object that does not answer (overloaded, most likely by that same address) is answered 503, not passed uncounted. The connections' limit is a fence against one address opening thousands, not a budget: a household's Mac and five phones all coming back after their network dropped make a few dozen connections in the first minute (each end's backoff then brings it back about once a minute), and the hour's 1,200 is twenty a minute for an hour. Behind one carrier's or company's IPv4 address, hundreds of ends would have to reconnect in the same minute to reach it, and those refused come back a minute later; at the hour's limit, the address is let in again at the rate its oldest minutes leave the hour. An object evicted for being idle forgets its counts, which only a quiet address brings about.
- **Join windows**: the Mac may open at most 10 in any minute; past them it is held off with `busy { until }`, as past any other limit, until the oldest of the ten is a minute old. Opening a window writes its record (and the alarm, when it moves earlier) and closing one writes again, so a Mac spending its whole allowance on windows would make hundreds of writes a second; a person pairing a phone, and trying again a few times, opens a handful in a minute. They are counted in memory: a pairing's object hibernates only after some seconds with nothing to do, and a Mac that waits that long between windows is well inside the limit anyway.
- **`presence` on `put`** marks an item whose request is a `"face"` one (a widening answer, 4.2): kept an hour, not a day. Every item a phone writes carries a presence signature inside its seal (4.3); the relay sees only the flag.
- **The Mac's `state`** carries the item's id, which its reader needs to open it (HPKE's `info` holds it).

## Not here yet

- **Pushes**: `token` is kept and deleted with its device; `push` is P20's (#689), with `src/apns.ts`.
- **The check that logs stay off** and that the code writes nothing to the console is P15's (#683). Logs are off in `wrangler.jsonc`, and nothing in `src` writes to the console.
- **A join without an attestation**, which only a local relay for tests may take ([10](../docs/iphone.md#10-testing-with-no-phone-in-hand)), is P13's (#681) to add when the simulator needs it; this relay takes none.
- **The deployments**: their environments, settings and minimum builds in `wrangler.jsonc`, and the workflow that deploys, are P9's (#677).
