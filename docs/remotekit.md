# RemoteKit: the channel and sealing, byte by byte

`app/Sources/RemoteKit` is the one implementation of the channel between a phone and pi² Remote, and of the sealed items that wait in the relay's mailbox ([iphone.md 5.2](iphone.md#52-the-secure-channel-noise), [5.3](iphone.md#53-the-relay), [section 8](iphone.md#8-the-shared-package)). pi² Remote and the iPhone app both build on it; the engine, which checks the signatures again in Node, reads what this page says. It uses CryptoKit and nothing else, and nothing of the Mac app, so it builds for iOS too. Its relay client, `RemoteKit/Relay`, is #678's and is not described here.

The contract says what each piece is for. This page says exactly how each is written, where the contract left that open (#674). A change to any of it is a change to what both ends and the engine read, and goes through the owner's review ([12.3](iphone.md#123-before-anything-is-built-the-repository-p0)).

## Everywhere

- **Bytes in text** are base64url without padding (RFC 4648 section 5). A reader takes only the one way of writing given bytes: no padding, no other alphabet, no white space, and the unused bits of the last character zero (`Base64URL`).
- **Public keys**: a P-256 key (identity, record, device, presence) is its SPKI DER, and only the encoding CryptoKit writes for it is taken; a channel key is its 32 raw Curve25519 bytes (`PublicKeys`).
- **Signatures** are ECDSA P-256 over SHA-256 of the exact `signed` text, written as their 64 raw bytes, r then s (IEEE P1363). The engine checks them with `crypto.verify("sha256", Buffer.from(signed), { key, dsaEncoding: "ieee-p1363" }, signature)`.
- **`signed`** is always a JSON text the signer wrote compactly (`JSON.write`); a reader checks the signature over its bytes before reading it, and then reads it strictly: RFC 8259's grammar, no white space before or after, no key twice, valid UTF-8 with no lone surrogate, at most 32 levels, every field present and none unknown. Texts read from outside are compared byte for byte, never by Swift's `==`, which takes canonically equivalent texts (the Kelvin sign and K) as equal where JavaScript does not.
- **Ids**: a pairing's id and an item's id are 16 bytes in base64url (22 characters); a device's id is `dev_` and the same; a session's id, which the engine chooses, is 1 to 64 letters, digits, `_` and `-`.
- **Times** (`at`) are milliseconds since 1970, by the writer's clock.
- **Errors** name what was refused and why in fixed words (`RemoteKitError`), never a key, the secret, a tag or a plaintext; `pi2-remote-check` checks every refusal it makes against the keys and the secret it used.
- **Comparisons** of tags, keys, bindings, challenges and digits take a time that depends on their length alone (`Bytes.constantTimeEqual`); CryptoKit compares the AEAD tags itself.

## The pairing payload

`pi2://pair?v=2&p=…&n=…&c=…&i=…&r=…&s=…&u=…&a=…&e=…`, in that order, each value written as JavaScript's `encodeURIComponent` writes it, so the engine can make it with that function (`PairingPayload`). The reader takes each parameter exactly once and no other, refuses `+` (which form encoding writes for a space) and anything not valid UTF-8, and checks each value: `p` an id, `n` 1 to 128 bytes with no control character, `c` a channel key, `i` and `r` P-256 keys, `s` 32 bytes, `u` `wss://host[:port]/path` (or `ws://` to `localhost`, `127.0.0.1` or `[::1]`, for a relay on this Mac in tests), `a` at most 16 `a.b.c.d:port` or `[v6]:port` (no zone: a link-local address needs one, so pi² Remote leaves those out), `e` seconds, at most 4,096 bytes in all. A payload's `description` leaves `s` out.

## The handshakes

| | Pairing | Every connection after |
|---|---|---|
| Protocol | `Noise_IKpsk2_25519_ChaChaPoly_SHA256` | `Noise_KK_25519_ChaChaPoly_SHA256` |
| Prologue | `pi2-pair-v2`, a zero byte, the pairing's id as text | `pi2-v2`, a zero byte, the pairing's id, a zero byte, the device's id, as text |
| Pre-shared key | `s` | none |
| First message | 96 bytes: e, s and two tags | 48 bytes: e and a tag |
| Second message | 48 bytes | 48 bytes |

No handshake message carries a payload, and a reader refuses one that does (`ChannelHandshake`). The lengths tell the two first messages apart on a path that does not say which it is.

- **Which device is calling**, on a path with no device id in front (TCP): `ChannelHandshake.respond(toFirstMessage:…)` tries the paired devices' keys in turn, at most eight, and answers the device whose key the message was made for. The device's id is never sent in clear on the local network.
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

A body is at most 65,516 bytes (65,535 less the tag and the header). The phone pads every frame to the next multiple of 256 bytes. A line is never empty and holds no line break (one would let one line pass as two where pi² Remote writes them to the engine); a reader takes at most 64 MB in one line unless given another limit. A channel that refuses a message is over; a channel lasts at most a day and is never rekeyed (`Channel`).

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
- **From the phone**: `{"v":2,"request":{"method":…,"params":…},"signed":…,"signature":…,"presence":…}`, `signed` = `{"v":2,"kind":"request","pairing":…,"device":…,"method":…,"params":…,"nonce":<the item's id>,"at":…}` by the device key, `presence` by the presence key over the same text, and `request` exactly what `signed` says (`RequestItem`).
- **From the Mac**: `{"v":2,"signed":…,"signature":…}`, `signed` = `{"v":2,"kind":…,"pairing":…,"device":…,"nonce":…,"at":…,"body":…}` by the identity key, with `"number"` before `body` in a `state` and in nothing else (`MacItem`). A kind is a lower-case letter and up to 31 letters, never `mac`, `pair`, `attach` or `request`. A revocation left in the mailbox is a Mac item of kind `revoked`.
- **Rising state numbers**: the phone keeps the highest number it has shown and refuses an older state (`StateNumbers`).
- **A record key in the Secure Enclave** ([3.2](iphone.md#32-the-keys), "which P6 finds out"): CryptoKit's HPKE takes one, as a reader's key and as a writer's, from iOS 17 and macOS 14 (`SecureEnclave.P256.KeyAgreement.PrivateKey` conforms to `HPKEDiffieHellmanPrivateKey`), and `SealedItem` takes any such key. `pi2-remote-check` checks this when it compiles; it makes no Secure Enclave key, so whether one opens items in the notification service extension while the phone is locked is P12's and P21's to try on a phone.

How old an item may be, whether its nonce was seen, and which requests the mailbox carries are the engine's ([4.3](iphone.md#43-face-id-the-presence-signature)).

## How it is checked

`pi2-remote-check` and `pi2-remote-fuzz` run in CI ([development.md](development.md#remote-channel-checks)).

- **Noise** against the published test vectors for both protocols, each source fetched at a pinned commit with its SHA-256 recorded in `vectors/noise.json`, which `vectors/extract.mjs` makes again: for KK, cacophony (1 vector), snow (1), noise-c (1) and flynn/noise (4); for IKpsk2, cacophony (1) and flynn/noise (4). Both sides of each vector run from their own keys, and every message, the handshake hash where given, and every transport message must be the published bytes.
- **HPKE** against RFC 9180's published vectors (the JSON its Appendix A points to) for mode_auth with DHKEM(P-256, HKDF-SHA256), HKDF-SHA256 and AES-256-GCM: one vector, its 257 encryptions opened in turn and its 3 exports. CryptoKit makes the sender's ephemeral key itself, so the sender's side is checked by opening what the vector's own sender key seals.
- **Not against a published vector**, since none exists for them: the channel above Noise (prologues, framing, lines), the signed texts, the digits, the join token and the items' `info`. They are checked between two ends of the check's own, a phone and a stand-in for pi² Remote: a pairing over the TCP framing, a KK connection, a resume, each refusal, and sealed items both ways.
- **The fuzzer** runs every parser above against mutated and random input from a fixed seed: base64url, ids and keys, JSON, frames, lines, the TCP framing, the payload, the channel's lines, both handshakes from both sides (only the messages made for them may be taken), the identification of a device by trial, transport messages, sealed items, and the items' contents, each read back as itself where it was taken.
