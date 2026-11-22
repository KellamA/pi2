# The relay

The relay is the path between a Mac and its paired phones that must always work ([docs/iphone.md 5.3](../docs/iphone.md#53-the-relay), #676): a Cloudflare Worker and one Durable Object for each pairing, which pass sealed bytes they cannot read, keep a small mailbox for an end that is away, and serve only genuine pi² for iPhone. It is written for any number of pairings ([9.2](../docs/iphone.md#92-nothing-assumes-one-person)): nothing of the owner's is in its code, and a deployment is this code with its own settings.

This folder is an owner's path (`.github/CODEOWNERS`): a pull request that changes it waits for the owner's review. Nothing here deploys anything. Deploying is #677 (P9), and waits for the owner ([docs/relay.md](../docs/relay.md)).

## Files

| File | What it holds |
|---|---|
| `src/index.ts` | The Worker: takes a WebSocket at `/v1` and hands it to its pairing's object; counts registrations against their address |
| `src/pairing.ts` | `Pairing`, the pairing's Durable Object: its sockets (hibernating), hello and challenges, register, join, routing, the Mac's requests, `leave`, revocation, deletion, its alarms |
| `src/protocol.ts` | Every message, read strictly; the fixed words of a refusal; builds; what an end signs |
| `src/join.ts` | What a join's attestation is checked against, and what this deployment takes of Apple's category and bundle version |
| `src/attest.ts` | The one import of App Attest's verifier, the engine's own file ([The verifier](#the-verifier)) |
| `src/claims.ts` | `AttestKey`, one object for each App Attest key: the pairing and device it is tied to |
| `src/addresses.ts` | `Address`, one object for each registering address, named by a keyed hash that changes daily: its count |
| `src/mailbox.ts` | The mailbox, in the pairing's SQLite storage |
| `src/limits.ts` | The pairing's limits and their counters |
| `src/settings.ts` | The deployment's settings, read and checked |
| `src/bytes.ts`, `src/crypto.ts` | Base64url and the other texts of bytes, read strictly; P-256 keys and signatures, SHA-256, HMAC |
| `src/types.d.ts` | One type the engine's verifier needs that Workers' types say otherwise |
| `test/` | The tests ([Tests](#tests)) |
| `scripts/check-bundle.mjs` | Checks the bundle Wrangler makes for a deploy, without deploying ([The verifier](#the-verifier)) |
| `wrangler.jsonc` | The Worker's configuration for local runs and tests: its objects, logs off, no settings |

`src/apns.ts` (pushes, #689) and the recorder in `test/` (#683) are other issues'.

## Tests

```bash
cd relay
npm ci
npm run check         # the type-check, which includes engine/src/appattest.ts as the relay bundles it
npm test              # the tests, inside workerd
npm run check-bundle  # the verifier in the deploy bundle is the engine's file
```

The tests run inside the Workers runtime (workerd, through `@cloudflare/vitest-plugin`), on this computer, with no Cloudflare account; never in Node's `vm` contexts, where the verifier refuses every byte array as another context's. Their settings, in `vitest.config.ts`, are a test deployment's: Apple's sample attestation's team and bundle ids. They move the clock themselves (`vi.setSystemTime`), so nothing depends on how fast the computer is. CI runs all three in the job **Relay (tests)**.

- `protocol.test.ts`: the Worker's door, register and hello with their challenges, builds below the minimum, a second Mac refused and the connected one told, a Mac socket gone quiet replaced, the ten seconds to prove oneself, strict reading.
- `join.test.ts`: join with a stand-in for the verifier: the window, the token, the three tries, what the verifier is asked, Apple's category and bundle version, App Attest keys tied to one pairing and device, a joined slot added or let go.
- `verifier.test.ts`: the verifier is the engine's file; it runs in workerd; Apple's sample (engine/test/appattest.json) through `join` with the real verifier, and refused for the relay's own client data, at today's time, for another key, and altered.
- `routing.test.ts`, `mailbox.test.ts`, `limits.test.ts`, `revoke.test.ts`: routing and its notices; the mailbox, its bounds and its expiry; the limits, and that only authenticated traffic counts; `removeDevice`, `leave`, `deletePairing`, and pairings deleted when pending or idle.

To run it locally, `npm run dev` with every setting given, as `--var NAME:VALUE` after `--` or in a `.dev.vars` file here (which git ignores); it listens on 127.0.0.1. Wrangler sends no metrics from this project (`send_metrics` in `wrangler.jsonc`).

## The verifier

App Attest's verifier is `engine/src/appattest.ts` (#672, P37), which the engine's pairing claim uses too. The relay imports that very file by its relative path (`src/attest.ts`), and Wrangler bundles it into the Worker: there is one file and no copy. If it ever needs a change to run in a Worker, the change is a pull request of its own to that file, never a fork here.

Three checks hold it so:

- `test/verifier.test.ts` imports the verifier both through `src/attest.ts` and from the engine's path, and checks they are the same functions, one module; and runs Apple's sample through it inside workerd.
- `scripts/check-bundle.mjs` builds the Worker as a deploy would (`wrangler deploy --dry-run`, which uploads nothing) and checks that the bundle's inputs include `engine/src/appattest.ts`, that every other input is in `relay/src`, that none of them defines a verifier or a root of its own, and that the bundle carries the engine's pinned root.
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
| The Mac | `openJoin { tokenHash, expires }`, `closeJoin {}`, `addDevice { device, deviceKey, attestKeyId }`, `removeDevice { device }`, `deletePairing {}`, `state { device, id, item }` | `ok { what }` or `refused { what, why }` |
| Either | `put { to, id, item, presence? }`, `take {}` | `ok`, or the items as `item { from, id, item, presence }`, a phone's `state { id, item }`, then `taken { count }` |
| A listed phone | `token { apns, environment }`, `leave { signature }` | `ok`; a leave closes the socket |
| Either | `{"ping":{}}` | `{"pong":{}}`, answered without waking the object |

**Notices** the relay sends: to the Mac, `online { device }`, `offline { device }` (also when it sends to a phone not connected), `joined { device, deviceKey, keyId }`, `left { device }`, `anotherMac {}`; to a phone, `mac { online }`; to either, `mail {}` when something arrives for it, and `busy { until }` past a limit.

**Binary messages** are the channel's bytes: a phone's reach the Mac with its 16-byte id in front; the Mac's start with the id of the phone they are for, which the relay takes off. The relay reads nothing past the id. A message is at most 70 KB.

**Refusals** end with `{"refused":{"why":…}}` and the socket closed with that word as its reason; a request of the Mac's or a `put` that is refused leaves the socket open. The words are fixed (`Why` in `src/protocol.ts`); nothing a client sent is ever said back.

## What it decides

Where the contract left something open, or the relay had to choose:

- **The pairing's object is found by a header.** The first message cannot choose the object that holds the socket, since the socket must be accepted by that object to hibernate; so the pairing is named in `Pi2-Pairing` as well, and `hello` must name the same.
- **A join's client data hash** is SHA-256 of the 32-byte challenge followed by the device key's SPKI DER, so the attested copy of the app vouches for this device key on this connection (6.6), as step 4's does for the Mac.
- **What a join takes of Apple's extensions.** The verifier gives the validation category and the bundle version without judging them. The relay takes a category only if the deployment lists it; an attestation with neither (an iOS before 27, which adds both) only if the deployment lists `none`; one with only one of them, never. The bundle version must be a build at or above `MIN_BUILD_DEVICE`.
- **An attested key is tied to one pairing and device.** Each App Attest key has an object of its own, named by its id, which records the pairing and device it was tied to at a join or an `addDevice`. A join, or an `addDevice`, whose key is tied elsewhere is refused (`attest-key-taken`). The tie goes when the device is removed, leaves, its slot lapses with the window, or the pairing is deleted. A phone that joined under one slot and is added by the Mac under another id has its key moved, and the old slot closed.
- **A join window** takes three refused joins of any kind (a wrong token, a refused attestation, a key already tied), after which it is closed, and three phones that joined: one more than the engine needs to see a second claim and close the window itself (3.3 step 6). A phone that joined has a slot that carries the channel to the Mac and nothing else until the Mac adds it; the slot goes with the window.
- **Only a phone that joined can be added.** `addDevice` names a phone that joined this pairing at the relay: by the slot it joined with, or by the App Attest key it joined with, under the id the engine gave it (its slot is then let go, and its socket closed so that it says hello under its id). Anything else is refused (`not-joined`). Otherwise a "Mac" of someone's own making could list devices of its own making and use the relay with no genuine app at all, which 6.6 rules out. The device key must be the one the phone joined with. If the Mac checked another App Attest key of the same phone at step 4, that key is tied to the device too. What follows: a phone paired over the home path alone, with the relay out of reach while it paired, has no slot at the relay until it joins a window, which for now means pairing again.
- **A pairing is pending** until its first `addDevice`, and deleted 15 minutes after `register` if none came.
- **A second Mac** is challenged as any Mac is. One that signs the challenge with the relay key is refused while the connected Mac is alive, and the connected Mac is told (3.4); one that cannot is refused for its signature, and the connected Mac hears nothing, so a stranger who knows the pairing's id cannot raise the alarm.
- **A Mac socket gone quiet.** One that has sent nothing, not even a ping, for 90 seconds (three of its pings) is taken for gone, so that a Mac whose network dropped can connect again; the old socket is closed as `replaced`.
- **A phone that connects again** closes its own older socket.
- **Past a limit** the relay answers `busy` and passes nothing on; past twice a limit it closes every socket of the pairing and refuses it for an hour, saying so in the refusal. The counts are of authenticated traffic only: a message counts once its socket has proved itself.
- **Waiting sockets.** At most 16 sockets wait to prove themselves in a pairing; a newer one closes the oldest. A socket has ten seconds.
- **Registrations** are counted by an object named by HMAC-SHA256 of the address, keyed with HMAC-SHA256 of `ADDRESS_KEY` over `pi2-address` and the date: the name changes every day, and the object deletes itself after a day.
- **The Mac's `state`** carries the item's id, which its reader needs to open it (HPKE's `info` holds it).

## Not here yet

- **Pushes**: `token` is kept and deleted with its device; `push` is P20's (#689), with `src/apns.ts`.
- **The check that logs stay off** and that the code writes nothing to the console is P15's (#683). Logs are off in `wrangler.jsonc`, and nothing in `src` writes to the console.
- **A join without an attestation**, which only a local relay for tests may take ([10](../docs/iphone.md#10-testing-with-no-phone-in-hand)), is P13's (#681) to add when the simulator needs it; this relay takes none.
- **The deployments**: their environments, settings and minimum builds in `wrangler.jsonc`, and the workflow that deploys, are P9's (#677).
