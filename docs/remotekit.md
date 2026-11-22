# RemoteKit: the channel and sealing, byte by byte

`app/Sources/RemoteKit` is the one implementation of the channel between a phone and pi² Remote, and of the sealed items that wait in the relay's mailbox ([iphone.md 5.2](iphone.md#52-the-secure-channel-noise), [5.3](iphone.md#53-the-relay), [section 8](iphone.md#8-the-shared-package)). pi² Remote and the iPhone app both build on it; the engine, which checks the signatures again in Node, reads what this page says. It uses CryptoKit and nothing else, and nothing of the Mac app, so it builds for iOS too. Its relay client, `RemoteKit/Relay`, is #678's and is not described here.

The contract says what each piece is for. This page says exactly how each is written, where the contract left that open (#674). A change to any of it is a change to what both ends and the engine read, and goes through the owner's review ([12.3](iphone.md#123-before-anything-is-built-the-repository-p0)).

## Everywhere

- **Bytes in text** are base64url without padding (RFC 4648 section 5). A reader takes only the one way of writing given bytes: no padding, no other alphabet, no white space, and the unused bits of the last character zero (`Base64URL`).
- **Public keys**: a P-256 key (identity, record, device, presence) is its SPKI DER, and only the encoding CryptoKit writes for it is taken; a channel key is its 32 raw Curve25519 bytes (`PublicKeys`).
- **Signatures** are ECDSA P-256 over SHA-256 of the exact `signed` text, written as their 64 raw bytes, r then s (IEEE P1363). The engine checks them with `crypto.verify("sha256", Buffer.from(signed), { key, dsaEncoding: "ieee-p1363" }, signature)`.
- **`signed`** is always a JSON text the signer wrote compactly (`JSON.write`) and read back with the strict reader before signing it, so nothing is signed that a reader would refuse or read otherwise (a key twice, a `JSONValue.number` that is not one number). A reader parses it strictly, then checks the signature over its exact bytes, and acts on nothing in it until that check has passed. Strictly means RFC 8259's grammar, no white space before or after, no key twice, valid UTF-8 with no lone surrogate, at most 32 levels, every field present and none unknown. Texts read from outside are compared byte for byte, never by Swift's `==`, which takes canonically equivalent texts (the Kelvin sign and K) as equal where JavaScript does not.
- **Ids**: a pairing's id and an item's id are 16 bytes in base64url (22 characters); a device's id is `dev_` and the same; a session's id, which the engine chooses, is 1 to 64 letters, digits, `_` and `-`.
- **Times** (`at`) are milliseconds since 1970, by the writer's clock.
- **Errors** name what was refused and why in fixed words (`RemoteKitError`), never a key, the secret, a tag or a plaintext. **Descriptions and mirrors** (`description`, `debugDescription`, `dump`) of a payload, a handshake or a channel show no key material either: a payload's leave out `s`, a handshake's and a channel's say only what they are and how far along. `pi2-remote-check` checks every refusal it makes, and the descriptions and dumps of every payload, handshake and channel it made, against the keys and the secret it used, and that no dump shows bytes.
- **Names shown to the person** (the Mac's name, a device's name, model and system) hold no control character and none of the invisible or direction-changing formatting characters U+200B to U+200F, U+202A to U+202E, U+2066 to U+2069 and U+FEFF (`ShownText`), so one name cannot pass for another, as when the Mac offers to replace a device by its name. The engine must keep them out of the Mac's name it gives pi² Remote.
- **Comparisons** of tags, keys, bindings, challenges and digits take a time that depends on their length alone (`Bytes.constantTimeEqual`); CryptoKit compares the AEAD tags itself.

## The pairing payload

`pi2://pair?v=2&p=…&n=…&c=…&i=…&r=…&s=…&u=…&a=…&e=…`, in that order, each value written as JavaScript's `encodeURIComponent` writes it, so the engine can make it with that function (`PairingPayload`). Each payload has one spelling: the reader takes each parameter exactly once and no other, refuses `+` (which form encoding writes for a space), a lower-case escape, an escape of a character `encodeURIComponent` leaves as it is, and anything not valid UTF-8, and checks each value: `p` an id, `n` 1 to 128 bytes that are a name to show (above), `c` a channel key, `i` and `r` P-256 keys, `s` 32 bytes, `u` `wss://host[:port]/path` (or `ws://` to `localhost`, `127.0.0.1` or `[::1]`, for a relay on this Mac in tests), `a` at most 16 `a.b.c.d:port` or `[v6]:port` (no zone: a link-local address needs one, so pi² Remote leaves those out), `e` seconds, at most 4,096 bytes in all. 

## The handshakes

| | Pairing | Every connection after |
|---|---|---|
| Protocol | `Noise_IKpsk2_25519_ChaChaPoly_SHA256` | `Noise_KK_25519_ChaChaPoly_SHA256` |
| Prologue | `pi2-pair-v2`, a zero byte, the pairing's id as text | `pi2-v2`, a zero byte, the pairing's id, a zero byte, the device's id, as text |
| Pre-shared key | `s` | none |
| First message | 96 bytes: e, s and two tags | 48 bytes: e and a tag |
| Second message | 48 bytes | 48 bytes |

No handshake message carries a payload. A reader refuses one that does, and the handshake has then failed: it writes, reads and gives a channel no more (`ChannelHandshake`). The lengths tell the two first messages apart on a path that does not say which it is.

- **Which device is calling**, on a path with no device id in front (TCP): `ChannelHandshake.respond(toFirstMessage:…)` tries the paired devices' keys and answers the device whose key the message was made for. The device's id is never sent in clear on the local network. A message that is not exactly 48 bytes is refused before any key agreement. Every call makes eight trials, whatever the number of devices: the paired devices' keys, then keys no device holds in the places of those the Mac does not have; none stops early, so neither how many devices are paired nor a device's place in the list shows in the time it takes. A failed trial leaves nothing behind. How often a peer may try is pi² Remote's to limit (#675).
- **A wrong pre-shared key.** psk2 mixes `s` in at the second message, so pi² Remote cannot tell a wrong `s` from the first message; the claimer cannot read the second. pi² Remote sees it when the claimer's first transport message fails, or when none comes within the ten seconds of [3.4](iphone.md#34-what-each-side-proves-at-every-connection). Either counts as one of the window's three wrong tries ([3.1](iphone.md#31-what-the-mac-shows-and-the-phone-scans)); P7 counts them.
- An ephemeral or static key of small order, which gives an all-zero DH output, is refused (the specification's section 12.1 allows either).

## Framing

- **TCP**: each Noise message preceded by its length, two bytes, big-endian; a length below 16 (a tag) is refused (`LengthFraming`). **The relay**: one Noise message per binary WebSocket message.
- **Inside the channel**, each transport message's plaintext is one frame: its kind (one byte), its body's length (two bytes, big-endian), its body, then padding, all zeros (`Frame`). A frame with anything else after its body is refused.

| Kind | Byte | Body |
|---|---|---|
| `data` | 1 | The last or only piece of a line |
| `more` | 2 | A piece of a line that goes on; never empty |
| `ack` | 3 | The count of lines received in all, eight bytes, big-endian |
| `ping` | 4 | Empty |
| `bye` | 5 | Empty |

A body is at most 65,516 bytes (65,535 less the tag and the header). The phone pads every frame to the next multiple of 256 bytes. A line is never empty and holds no line break (one would let one line pass as two where pi² Remote writes them to the engine).

**How long a line may be.** A channel takes lines of at most **64 KB** (`Lines.firstLinesMaxLength`) until the device is attached: a pairing channel always, and a connection until `attached`. Its own first lines are a few kilobytes, so a pairing claimer, who needs only `s`, or a device that has not attached, can make the other end hold no more than that. Once attached, each end raises the limit (`Channel.maxLineLength`); `Lines.defaultMaxLength`, 64 MB, is the usual one, since a greeting is the size of the person's library. A frame that would take a line past the limit is refused before its bytes are held. `LengthFraming` reads the messages of a push where they lie and moves what is left once, so a push costs time in proportion to its size.

## One state, however many hold it

`NoiseHandshake`, `NoiseTransport`, `ChannelHandshake` and `Channel` are final classes with their state behind a lock (`Mutex`), not values. A copied value would hold the same key and nonce, and two lines sealed from the copies would reuse ChaCha20's keystream and Poly1305's key. A second reference shares the one state instead, so its nonces follow the first's, and a failure seen through one is seen through every other: a channel that refused a message is over for all who hold it. A handshake gives one transport and one channel; a second `split()` or `channel()` is refused. Classes rather than noncopyable values (`~Copyable`), because pi² Remote and the phone keep channels in dictionaries and hand them between tasks, which noncopyable values cannot go into, and because a lock is needed for that sharing anyway. The compiler checks that they are `Sendable`, so a channel shared between tasks cannot be raced; that a channel is not used after it failed, and that a handshake gives one channel, are checked when they run, and `pi2-remote-check` checks both.

A channel lasts at most a day, counted on `ContinuousClock`, which keeps counting while the Mac or the phone sleeps and does not follow the wall clock when it is set: setting the clock back cannot keep a channel alive. It is never rekeyed (`Channel`).

## The channel's own lines

| Line | Who | Form |
|---|---|---|
| The Mac's proof | pi² Remote, first, on every channel | `{"challenge":<32 bytes>,"mac":{"signed":…,"signature":…}}`, `signed` = `{"v":2,"kind":"mac","pairing":…,"binding":<the handshake hash>}` by the identity key. On a connection, the challenge is the engine's for the attach |
| `pair` | The phone | `{"pair":{"v":2,"device":{"name","model","system","build","deviceKey","presenceKey","channelKey","recordKey"},"attestation":<bytes or null>,"keyId":<text or null>,"signed":…,"signature":…}}`, `signed` = `{"v":2,"kind":"pair","pairing":…,"binding":…}` by the device key. pi² Remote also checks that `channelKey` is the key the handshake proved |
| `paired` | pi² Remote | `{"paired":{"device":…,"pairing":…,"name":…,"addresses":[…]}}` |
| `attach` | The phone | `{"attach":{"signed":…,"signature":…,"presence":…}}`, and `"received":<count>` beside them when it resumes, for pi² Remote's buffer. `signed` = `{"v":2,"kind":"attach","pairing":…,"device":…,"session":<null or the session>,"binding":…,"challenge":…,"build":…,"at":…}` by the device key; `presence` is the presence key's signature over the same text |
| `attached` | pi² Remote | `{"attached":{"session":…,"resume":<true or false>}}` |
| `revoked` | pi² Remote | `{"revoked":{"signed":…,"signature":…}}`, `signed` = `{"v":2,"kind":"revoked","pairing":…,"device":…,"at":…}` by the identity key |
| `sessionEnd` | The phone | `{"sessionEnd":{}}` |

`ControlLine.parse` reads exactly one of these and refuses anything else, the engine's own lines among them; which lines a channel expects when is pi² Remote's and the phone's to keep.

- **The digits** ([3.3](iphone.md#33-the-pairing-exchange) step 7): HMAC-SHA256 keyed with `s` over `pi2-digits`, a zero byte and the handshake hash; the first four bytes as a big-endian number, modulo a million, written with six digits.
- **The join token** (step 2): HMAC-SHA256 keyed with `s` over `pi2-join`, a zero byte and the pairing's id as text. The relay is given SHA-256 of it.
- **App Attest's client data hash** (step 4): SHA-256 of the challenge, the device key's SPKI DER and the handshake hash, one after the other.
- **An attach's time**: `at` within two minutes of the reader's clock, either way.

## Sealed items

- HPKE (RFC 9180) in its authenticated mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM, with no associated data. `info` is `pi2-item-v2`, then a zero byte before each of the pairing's id, the reader (`mac`, or the device's id) and the item's id, as text. An item is HPKE's encapsulated key (65 bytes, an uncompressed point) and then the ciphertext; at most 16 KB (`SealedItem`).
- **From the phone**: `{"v":2,"request":{"method":…,"params":…},"signed":…,"signature":…,"presence":…}`, `signed` = `{"v":2,"kind":"request","pairing":…,"device":…,"method":…,"params":…,"nonce":<the item's id>,"at":…}` by the device key, `presence` by the presence key over the same text, and `request` exactly what `signed` says (`RequestItem`). Every request item carries both signatures ([4.3](iphone.md#43-face-id-the-presence-signature)): one without `presence` can be neither made nor read. Mac items carry none. The relay's `put` has a flag also named `presence` ([5.3](iphone.md#53-the-relay)); it marks an item whose request is a `"face"` one, which lives an hour, not a day, and is the relay client's to set (#678), not part of the item.
- **From the Mac**: `{"v":2,"signed":…,"signature":…}`, `signed` = `{"v":2,"kind":…,"pairing":…,"device":…,"nonce":…,"at":…,"body":…}` by the identity key, with `"number"` before `body` in a `state` and in nothing else (`MacItem`). A kind is a lower-case letter and up to 31 letters, never `mac`, `pair`, `attach` or `request`. A revocation left in the mailbox is a Mac item of kind `revoked`.
- **Opened, read and verified in one call**: `SealedItem.openRequest` (the Mac's side) and `SealedItem.openMacItem` (the phone's) open an item, read what it holds and check its signature, its pairing, its writer or reader and its nonce, and give nothing back unless all of that holds; a request's presence signature, which every request carries, must be the presence key's. The separate steps are only for the checks (`@_spi(Vectors)`), so no caller can act on an item it did not verify.
- **Rising state numbers**: the phone keeps the highest number it has shown and refuses an older state (`StateNumbers`).
- **A record key in the Secure Enclave** ([3.2](iphone.md#32-the-keys), "which P6 finds out"): as far as compiling shows, CryptoKit's HPKE takes one, as a reader's key and as a writer's, from iOS 17 and macOS 14 (`SecureEnclave.P256.KeyAgreement.PrivateKey` conforms to `HPKEDiffieHellmanPrivateKey`), and `SealedItem` takes any such key. `pi2-remote-check` checks this when it compiles; it makes no Secure Enclave key, so whether one opens items in the notification service extension while the phone is locked is P12's and P21's to try on a phone.

How old an item may be, whether its nonce was seen, and which requests the mailbox carries are the engine's ([4.3](iphone.md#43-face-id-the-presence-signature)).

## How it is checked

`pi2-remote-check` and `pi2-remote-fuzz` run in CI ([development.md](development.md#remote-channel-checks)).

- **Noise** against the published test vectors for both protocols, each source fetched at a pinned commit with its SHA-256 recorded in `vectors/noise.json`, which `vectors/extract.mjs` makes again: for KK, cacophony (1 vector), snow (1), noise-c (1) and flynn/noise (4); for IKpsk2, cacophony (1) and flynn/noise (4). Exactly these 12 are expected, so a fixture that lost one fails. Both sides of each vector run from their own keys, and every message, the handshake hash where given, and every transport message must be the published bytes. The check checks itself: each vector run again with one bit changed in each message in turn, in each side's prologue and in each pre-shared key must fail.
- **HPKE** against RFC 9180's published vectors (the JSON its Appendix A points to, at the commit the RFC cites, `5f503c5`) for mode_auth with DHKEM(P-256, HKDF-SHA256), HKDF-SHA256 and AES-256-GCM: one vector, its 257 encryptions opened in turn and its 3 exports. CryptoKit makes the sender's ephemeral key itself, so the sender's side is checked by opening what the vector's own sender key seals. One bit changed in a ciphertext, the encapsulated key, `info` or an export must fail.
- **Not against a published vector**, since none exists for them: the channel above Noise (prologues, framing, lines), the signed texts, the digits, the join token and the items' `info`. They are checked between two ends of the check's own, a phone and a stand-in for pi² Remote: a pairing over the TCP framing, a KK connection, a resume, each refusal, and sealed items both ways.
- **The fuzzer** runs every parser above against mutated and random input from a fixed seed: base64url, ids and keys, JSON, frames, lines, the TCP framing, the payload, the channel's lines, both handshakes from both sides (only the messages made for them may be taken), the identification of a device by trial, transport messages, sealed items, and the items' contents, each read back as itself where it was taken; an item whose signature verifies must hold exactly a text its key signed. It refuses an argument it does not know, or a value it cannot read, with exit code 2, so a typo cannot quietly change a run.
- **What `app/Package.swift` builds them from.** That file is not an owner's path, since other pull requests add shared targets to it all the time; but it decides what RemoteKit and its checks are built from. `scripts/check-protected-targets`, an owner's path run in CI's App (build) job, reads `swift package dump-package` and fails unless each protected target is built from `app/Sources/<its name>` with no sources list, no other excludes than it has (`vectors` for the check), no resources, settings, unsafe flags or plugins, RemoteKit with no dependency and its checks with RemoteKit alone; unless no other target is built from inside their folders; unless no product of the package names one of the two checks (a product for RemoteKit itself is the phone's issue's to add); and unless the package depends on no other package than Sparkle. It also fails if any Swift file outside RemoteKit and its two checks names `@_spi(Vectors)`. `scripts/test-check-protected-targets` checks that each of those tamperings fails it. The issue that adds a protected target (pi² Remote, #675) adds its line to the script's list.
