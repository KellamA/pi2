
# pi² Remote: the Mac's end of a phone's channel

pi² Remote is the helper inside the app's bundle that holds the Mac's ends of the paths to a paired phone, the Mac's keys and the channels ([iphone.md 5.5](iphone.md#55-which-program-holds-them), decision 6). The engine starts it and stays its judge: every attach, resume and request is checked again in the engine ([section 4](iphone.md#4-who-is-speaking)). This page says what the helper does, what each kind of build does and never does, and what has not yet been run on a Mac. The channel's bytes are [remotekit.md](remotekit.md)'s; the engine's side is `engine/src/remote.ts` and `engine/src/devices.ts`.

| Where | What |
|---|---|
| `app/Sources/pi2-remote` | The helper's code, a library so that its check can drive it. `Relay/` is the relay's end (#678); later issues add `Session/` and `Push/` here |
| `app/Sources/pi2-remote-helper` | Its program, one line. `app/build.sh` copies it into the app as `Contents/Helpers/pi² Remote.app/Contents/MacOS/pi² Remote`, an app bundle of its own with no Dock icon, bundle id the app's and `.remote` (`dev.pi2.app.remote` in a release) |
| `app/Sources/pi2-remote-helper-check` | Its check ([below](#how-it-is-checked)) |

All three are the owner's paths (`.github/CODEOWNERS`), and `scripts/check-protected-targets` holds `app/Package.swift` to building them from their own folders as they are.

## Starting

The engine starts pi² Remote whenever the preview and remote access are on and a device is paired or a pairing is open, only once it is ready, from the fixed path in its app's bundle, with no argument and an empty environment, and with its control connection as descriptor 3: one end of a Unix socket pair it made (`remote.ts`). In this order (`Helper.swift`), so that a copy not started by the engine exits before it reads any key (decision 24):

1. **Which kind of build** (`Build.swift`). The development paths are compiled only under `PI2_DEVELOPMENT`, which `app/Package.swift` defines for a debug build and `build.sh optimised` passes; the Keychain, Secure Enclave and Bonjour calls are compiled only without it. A helper compiled for development that is signed with a Developer ID (Apple's anchor) is neither, and stops.
2. **The start-up checks** (`Startup.swift`), each a refusal that ends the process with exit code 78:
   - descriptor 3 is open, a Unix stream socket, its other end (`LOCAL_PEERPID`) is this process's parent, and that parent is run by this user (`LOCAL_PEERCRED`);
   - the data folder ([below](#the-data-folder)) is a real folder, this user's, writable by nobody else, and its `engine.pid` names the parent;
   - in a release build, the parent's executable is the Node in the app's bundle (`Contents/Resources/node`), and its code, found from the socket's audit token, satisfies that file's designated requirement, as `PeerKit` checks the app.
3. **Only then the keys** and pi² Remote's own list of devices ([below](#the-keys-and-the-list-of-devices)).
4. It waits for the engine's `start` and does only what the engine's events say.

It reads no argument and none of its own environment variables, in any build; `pi2-remote-helper-check` checks that no source file names `CommandLine`, the environment, `getenv` or user defaults. Before the data folder is known, a refusal is said on standard error, which the engine discards; after it, on `remote.log` in the data folder (0600, kept under a megabyte, never a key, the pairing's secret, the digits, a signature or a line a device or the engine sent).

### The data folder

- **A release build**: the usual data folder, `~/Library/Application Support/pi2`, its home folder taken from the user database, never from the environment. A release copy run on another data folder (`PI2_HOME`, as `app/check-release-build.mts` runs one) finds no `engine.pid` naming its engine there and exits: it has no remote access.
- **A development build**, and every throwaway copy: the data folder its engine runs on, read from the engine's own environment (`PI2_HOME`, which the app and the tests always set; `KERN_PROCARGS2` of the parent), or failing that the one the app's bundle id names, as `DevelopmentBuild` names it. Never the usual data folder, however it is written.

## The two kinds of build

| | A development build, and every throwaway copy | A release build |
|---|---|---|
| Keys | `remote-keys.json` in its data folder, 0600, refused if others can read it or it is a link | The identity, relay and record keys in the Secure Enclave where there is one, the channel key and the rest in the data-protection Keychain, service `dev.pi2.remote` ([decision 30](iphone.md#13-decisions-this-contract-made)) |
| Its own list of devices | `remote-devices.json`, the same way | The Keychain, the same service |
| The home path | Listens on 127.0.0.1 alone, while **Find on this network** is on | Listens on every address, IPv4 and IPv6, while **Find on this network** is on |
| Bonjour | Nothing advertised | `_pi2._tcp` with `v=2` and the tag ([below](#bonjour)) |
| The relay | A `register` is answered with a pairing's id it makes itself, until the relay's client is here (#678) | Not yet (#678) |
| What it can ask macOS for | Nothing: its executable names no Keychain item, no Secure Enclave key made or read, no Bonjour call (the check reads it with `nm`) | Local Network, once, when it first advertises; and the firewall may ask whether it may take incoming connections ([iphone.md 5.5](iphone.md#55-which-program-holds-them)) |

## The keys and the list of devices

The Mac's four keys are made the first time and read after ([iphone.md 3.2](iphone.md#32-the-keys)); their public halves go to the engine in `remote.hello`, with `secureEnclave` saying whether the identity and relay keys are in a Secure Enclave. A key the Keychain holds as being in the Secure Enclave that cannot be used there (the Keychain was carried to another Mac) is a refusal, never a new key made in silence, which would unpair every phone.

**Its own list of the paired devices' keys** (3.4, 5.5) is written only when the engine says it paired a device (`paired`), and attaches no device outside it: a device written into the engine's store by hand is never attached. `start`, which the engine builds from its own store, is used only to drop devices: one the list holds that `start` does not name was revoked while pi² Remote was not running, and goes. `revoke` drops a device at once.

## The control connection

One JSON object a line, each way (`EngineLink.swift`): pi² Remote's requests (`remote.hello`, `remote.state`, `remote.pairClaim`, `remote.pairWrong`, `remote.attachBegin`, `remote.attach`, `remote.sessionEnd`) and their answers; a device's lines, `{"session","message"}`, passed on as their bytes, never read; and the `remote` event, of which it acts on `start`, `settings`, `register`, `openJoin`, `closeJoin`, `paired`, `pairRefused`, `revoke` and `sessionClosed`. A line from the engine longer than 64 MB (RemoteKit's limit on an attached device's lines) ends pi² Remote, and the engine starts it again. When the engine ends the connection, pi² Remote exits.

## The home path

`Addresses.swift`, `PhoneConnection.swift` ([iphone.md 5.4](iphone.md#54-direct-at-home)). Plain BSD sockets, so that in loopback mode nothing can ask macOS for the Local Network privilege.

- **Who it takes.** With **Direct from any address** off, only link-local, private (RFC 1918), unique-local (fc00::/7) and shared (100.64.0.0/10) addresses, and loopback; an IPv4 peer of the dual-stack socket is read as IPv4 (decision 32).
- **Before anything is authenticated**: at most eight connections in all and four from one address; ten seconds to attach, or for a pairing claimer to send its first transport message; one first message per connection, of exactly a first message's length (48 bytes, or 96 while a pairing window is open), read before any key agreement and closed otherwise; at most 20 first messages a minute from one address and 60 in all; once the trial has found the device, at most six handshakes a minute for it.
- **The channel**: Noise with RemoteKit's length framing. On a connection, the Mac's proof carries the engine's challenge (`remote.attachBegin`). Until the device is attached, its lines are held to RemoteKit's 64 KB; once attached, to 64 MB. A phone that reads nothing does not make the Mac hold more than 16 MB on its socket: the channel is closed, and its session keeps what a resume needs.

### Bonjour

A release build advertises `_pi2._tcp` with the Mac's name as macOS gives it, and a TXT record `v=2` and `t=<tag>`. The tag is HMAC-SHA256 of the UTC day, written `YYYY-MM-DD`, keyed with SHA-256 of `pi2-tag`, a zero byte, the Mac's channel key's 32 raw public bytes, a zero byte and the pairing's id; its first 8 bytes, in 16 lower-case hexadecimal digits. The phone has the channel key and the pairing's id from pairing; the relay, which knows the pairing's id, never sees the channel key; anyone else learns nothing that follows the Mac from network to network. A phone takes the day before, the day and the day after. The tag is written in pi² Remote (`HomeTag`) for now; it belongs in RemoteKit, where the phone can share it.

## Pairing on the home path

([iphone.md 3.3](iphone.md#33-the-pairing-exchange)) While the engine holds a window open (`openJoin`), a 96-byte first message is answered as IKpsk2 with its secret. The Mac's first transport message is its proof with a challenge of its own; the claimer's `pair` is checked (its device key signed this channel's binding for this pairing, and the channel key it names is the one the handshake proved) and passed to the engine as `remote.pairClaim` with the claim as the phone wrote it, the binding, **that exact challenge** and the path. The engine's `paired` adds the device to pi² Remote's own list first, then the phone is sent `paired`, and the channel ends; `pairRefused` ends it.

**Wrong tries.** psk2 mixes the secret in at the second message, so a wrong secret shows only after it. A try is counted (`remote.pairWrong`) when the claimer's first transport message fails to open, or when the connection closes, or ten seconds pass, after the second message with none; never for a first handshake message that fails, which anyone on the network could send. Anyone who once saw a QR code holds the Mac's channel key and the pairing's id, which outlive the window, and so can use up its three tries: that blocks pairing until the person opens another window, and is no way in. Nothing is shown on the Mac until the claimer's first transport message has opened.

## Attaching, sessions, resuming

([iphone.md 3.4](iphone.md#34-what-each-side-proves-at-every-connection), [5.8](iphone.md#58-resuming-and-moving-between-paths))

- **Attach.** The phone's `attach` must be for the device the trial found, signed by **the device key on pi² Remote's own list** over this channel's binding, before anything reaches the engine. A build below the engine's minimum (`start`'s `minimumBuild`) is closed. It is passed as `remote.attach` with exactly `attach` (`signed`, `signature`, `presence`), `binding` and `path`: `received` is pi² Remote's alone. The path is `home` for a phone on the Mac's own network (loopback, link-local, private and unique-local addresses) and `direct` for any other (a private network's shared range, as Tailscale's, or anywhere with **Direct from any address** on): the Mac cannot see how the phone found it, only where it calls from. The engine checks it again, with both signatures, and answers the session.
- **A session's lines.** Every line from the phone is read strictly as one JSON object, with no line break, before it is put in a line to the engine, so that nothing in it can end that line or name another session; `{"sessionEnd":{}}` ends the session (`remote.sessionEnd`). The Mac acknowledges the phone's lines every second or 64 KB.
- **The buffer.** pi² Remote keeps the engine's lines the phone has not acknowledged, up to 4 MB, and the session 60 seconds after its channel drops. A resume on a new channel, by either path, is a new attach the engine checks as any other; pi² Remote then sends what the phone has not had, without a new greeting. A session whose phone did not come back within 60 seconds, or that dropped owing lines it no longer holds, is ended in the engine (`remote.sessionEnd`), and the phone attaches afresh.
- **Closed by the engine** (`sessionClosed`): the channel ends, two seconds later, so that a `revoke` the engine sends after closing a revoked device's sessions can still reach the phone.
- **Revoked**: the phone is sent `revoked`, signed by the identity key, then its channels end, and it is dropped from the list.

## What a throwaway copy's pi² Remote does, and never does

A copy made with `scripts/test-copy` from a development build runs the development build's helper:

- it runs only as its engine's child, on its engine's data folder (never the usual one);
- it keeps its keys and its list of devices in files in that folder;
- it listens on 127.0.0.1 alone, and only while **Find on this network** is on;
- it **never** calls the Keychain, makes or reads a Secure Enclave key, advertises on Bonjour, or listens beyond 127.0.0.1: none of those calls is compiled into it.

So it can set off no Keychain prompt, no Local Network prompt and no firewall prompt ([CONTRIBUTING.md](../CONTRIBUTING.md#testing-safely)).

## Not yet run on any Mac

What only a release build does was written and checked with stand-ins, and built by `./app/build.sh release`, but never run: no agent may run it on a Mac where pi² is in real use. The owner runs it first, on a release build signed with pi²'s Developer ID and its Keychain access group (P14, #686):

- the Keychain items (`KeychainItems`) and the Secure Enclave keys (`SecureEnclaveKeys`), and whether HPKE takes a Secure Enclave record key in practice;
- Bonjour (`BonjourAdvertiser`), what the Local Network prompt says, and whether the macOS firewall asks too ([iphone.md 5.5](iphone.md#55-which-program-holds-them) asks P7 to find out; it waits for the owner);
- the listener on every address, and the address ranges on a real network;
- the check of the parent's code against the bundle's Node on a real release engine (it is run, in the check, on the check's own process).

## How it is checked

`pi2-remote-helper-check` ([development.md](development.md#pi-remote-checks)), in CI's App (build) job:

- in its own process: the address ranges and the listener's limits, the minimum build, the Bonjour tag, the data folder's choice, a release build's Keychain and Secure Enclave logic with stand-ins for both, a development build's key files, the session lines, the parent's code check on its own connection, no setting read from outside, and that the development helper's executable names no Keychain, Secure Enclave or Bonjour call;
- the helper as a process, whatever its arguments and environment say: it exits with no descriptor 3, with a pipe or a file as descriptor 3, with a socket whose other end is another process than its parent, with no `engine.pid`, and with another process's id in it, and none of these leaves a key file or a log;
- the helper with the check as its engine and a RemoteKit phone, over loopback: the listener on 127.0.0.1 alone; first messages of the wrong length or with no window closed before the engine hears of them; a wrong secret counted and a junk first message not; `remote.pairClaim` with the exact challenge; the device on the list only once paired; `remote.attach` without `received`; a session's lines both ways as written; a resume that is sent what it lacked; a line that is not one JSON object closed and never passed on; `sessionEnd`; an attach signed by another key and one below the minimum build closed before the engine hears of them; a session closed by the engine; `revoked`; the resume window ending a session after 60 seconds; and the list against `start`;
- with `--engine ../engine/src/main.ts`, a real engine on a temporary data folder, which starts the helper from a stand-in app bundle: a phone pairs with the digits it shows typed on the Mac, attaches over loopback, is greeted, asks the engine, is refused what the Mac keeps, resumes on a new channel, and is told when it is revoked; the helper has no socket but on 127.0.0.1 (`lsof`), and stops when remote access goes off.
