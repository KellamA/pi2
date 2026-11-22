# Retaking the README's pictures

The pictures in `docs/images/` that the README and the guide show (all but `providers.png`, `models.png` and `icon.png`) are staged with this kit in a throwaway copy of pi² (#729, #757). The demo model can only give its canned answers, so the copy is given an endpoint, "Ollama", that points at `server.mjs`: a stand-in OpenAI-compatible server on 127.0.0.1 whose answers come from `scenario.mjs`. The tools run for real in the copy, on three small sample repositories made from `samples/`, so every tool step, approval, report, wake, work item and token count is pi²'s own. The README says under its first picture that the answers are scripted.

Everything goes through `scripts/test-copy`, which refuses any copy this checkout did not start and keeps to the rules in [Testing safely](../../CONTRIBUTING.md#testing-safely); the kit adds no guard of its own. Nothing here calls a real provider.

## Steps

From the checkout, with a development build (`./app/build.sh`) and `jq`:

1. `node scripts/readme-pictures/server.mjs` (in the background; it prints a line for each request).
2. `scripts/test-copy start test-N --show dashboard`, then `scripts/test-copy size test-N 1360 860`.
3. `scripts/readme-pictures/stage.sh test-N /Users/Shared/Projects`. The folder is where the sample repositories go, and shows in the hub's bar, so choose one whose path reads neutrally. It returns once Forge's `git push` is the one approval left, and prints the conversations' numbers.
4. Take the pictures (`scripts/test-copy shot test-N docs/images/<file>`; look at each before keeping it). The hub, Dashboard and panes need Atlas still running its end-to-end suite, about 9 minutes from the start:

| File | Before the shot |
|---|---|
| `hero.png` | `show test-N 'project:storefront#now' --hub both`, once Scout's decision is on the Now tab |
| `dashboard.png` | `show test-N dashboard` |
| `needs-you.png` | `show test-N 'project:storefront#agent:Forge' --hub both` |
| `panes.png` | after `needs-you.png`: `size test-N 1600 940`, then `show test-N beside:<Atlas's conversation>` |
| `hero-light.png` | `reopen test-N --show 'project:storefront#now' --appearance light`, `size test-N 1360 860`, the `show` of `hero.png`; then `reopen … --appearance dark` |
| `chat.png` | `show test-N chat:<the chat>` |
| `usage.png` | once Atlas has finished: `reopen test-N --show usage`, `size test-N 1360 860` |
| (`computer-use.png`) | `reopen test-N --show 'agent:<Scout>#computer'` (an agent's `#section` is reached at launch, not by `show`). Not in the README for now: in a copy both permissions show as not granted, and the section ends with a sentence only a development build has. |

5. `scripts/test-copy stop test-N`, stop the server, and `scripts/readme-pictures/reset.sh /Users/Shared/Projects --remove`.

## Changing the scenario

A turn of `scenario.mjs` is chosen by the newest message from the person, or a wake (`[pi² woke you …`), and its steps by how many answers have followed it; each step is text and tool calls. The server reads the file again at every request, so it can be corrected while a copy runs. Match a turn on words only its own message has: a sub-chat's task often repeats its orchestrator's words.

Give each `work` `file` call a step of its own. Calls in one answer run at once, so the items' numbers come in any order, and the `assign` calls that follow name them by number.
