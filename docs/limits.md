# Plan limits

Subscriptions such as Claude Pro/Max or ChatGPT Plus/Pro are not billed per token. They give an allowance counted in windows: a 5-hour window, a week, for some plans a month or a window per model. The top of **Usage** shows, for each subscription that is signed in, how much of each window is used and when it resets.

None of the sources below is a documented, stable interface. They are what the providers' own clients read, and they can change without notice. pi² reads them carefully: an answer it cannot read says **Could not read the limits** with the time, and the last good figures stay on screen; it never shows a number it had to guess.

## What is shown

Under **Plan limits**, one card per signed-in subscription:

- the provider and, when it says, the plan ("Plus", "Pro");
- a bar per window with the share used, tinted above 80% and red when used up;
- "resets in 2 h 14 min", with the exact time on hover; a window whose reset has passed since it was read is dimmed until it is read again;
- when it was last checked, and how (asked the provider, or read from the answer to a request);
- a button to check now, for providers pi² can ask;
- what went wrong, if the last check failed.

A subscription whose provider does not report its limits says so in one line. When no subscription is signed in, the section is not there.

## Where the figures come from

pi² learns them two ways:

- **From the answers it already gets.** Some providers put the figures in the headers (or, for Codex over a WebSocket, an event) of every answer to a subscription request. pi² reads them as they pass. This costs nothing and is what the providers' own clients rely on.
- **By asking.** Some providers have a usage address that answers for the signed-in account. pi² asks it when you press the button, when you open **Usage** and the last check was more than an hour ago, when you sign in, when the engine starts and the last reading is more than 10 minutes old, and about 15 seconds after a run on that subscription if the answers did not carry the figures. It asks each provider at most about once a minute, and after a "too many requests" answer it leaves that provider alone for at least five minutes (longer if the provider says so).

The token for asking comes from pi-ai's own sign-in handling, which renews it when it is about to expire and stores the renewed one. It is only ever sent to that provider's usage address (redirects are refused), and it is never written to a log, an error message, the app or `limits.json`.

| Subscription | From its answers | By asking | How sure |
|---|---|---|---|
| Anthropic (Claude Pro/Max) | `anthropic-ratelimit-unified-5h-*` and `-7d-*` headers: used as a fraction 0–1, reset as Unix seconds | `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`: `five_hour`, `seven_day` and sometimes per-model weekly windows (`seven_day_opus`, …), used as 0–100, reset as ISO 8601 | Undocumented by Anthropic. Field names agree across many independent open-source tools and write-ups; Claude Code itself reads the headers. The usage address is known to answer "too many requests" readily, so the headers are the main source |
| OpenAI Codex (ChatGPT Plus/Pro) | `x-codex-primary-used-percent`, `-window-minutes`, `-reset-at` and the same for `secondary` (HTTP); a `codex.rate_limits` event (WebSocket) | `GET https://chatgpt.com/backend-api/wham/usage` with `chatgpt-account-id`: `plan_type`, `rate_limit.primary_window` / `secondary_window`, `additional_rate_limits` for particular models | Read from the open-source Codex client (github.com/openai/codex), which uses exactly these; not documented as a public API |
| GitHub Copilot | `x-quota-snapshot-premium_interactions` (and `-chat` on the free plan): allowance, percent remaining, reset date | — (Copilot's usage address needs the GitHub token itself, which pi-ai does not hand out through its sign-in handling) | Read from VS Code's open-source Copilot Chat extension. Until the first request in pi², the card says the figures appear after the next request |
| Kimi Code (subscription) | — | `GET https://api.kimi.com/coding/v1/usages`: a weekly allowance and rolling windows | Best effort. Only open-source monitors describe it, and the shape has changed over time; pi² reads the shapes they describe |
| OpenAI (ChatGPT subscription, api.openai.com) | — | — | Does not report its limits: apps only learn of them from the error when one is reached |
| xAI (Grok/X subscription), Meta (Muse) | — | — | Does not report its limits: nothing reliable is known |

The 5-hour and weekly windows are labelled from the window's length when the provider gives one (Codex), or from the provider's own names for them (Anthropic, Kimi).

## When a limit is reached

A run whose request a provider refuses for its limit does not end. It waits, and asks again by itself, for as long as it takes, within the bounds below. This covers:

- **rate limits**: HTTP 429, or an error that says "rate limit", "too many requests" or "usage limit" (a subscription's window used up, ChatGPT's usage limit);
- **an overloaded provider**: HTTP 529, or an error that says "overloaded".

**How long it waits.** As long as the provider says, when it says: `retry-after-ms`, `retry-after` (seconds or a date), a Claude subscription's `anthropic-ratelimit-unified-reset` when that window refused (`anthropic-ratelimit-unified-status: rejected`), or ChatGPT's `resets_at` / `resets_in_seconds` in the error. Of several times, the latest counts. To that it adds a little at random, a tenth of the wait (at least one second, at most 30), so that runs refused together, such as ten sub-chats on one subscription, do not all ask again in the same second. When the provider names no time, it backs off: the first wait is 7.5 to 15 seconds, and each refusal after it doubles that, up to 5 to 10 minutes, each a random point in the second half of its step.

**The longest it waits by itself.** When the provider names no time, 6 hours from the first refusal; then the run ends, and its error says it stopped waiting and that continuing the conversation tries again. When it names a time, until that time, as long as it is within 8 days (a week's window and a day to spare); a time further off is not believed, and the run ends at once with the same kind of error. Six hours is long, but the other choice is work stopped with nobody watching, which is how this was met (#183): ten sub-chats ran at once on one subscription, four of them were refused and ended within half a minute, and they carried on only because someone typed "continue" in each.

**What is not waited for.** An error that is not a limit ends the run at once, as before: a bad key, a refused request, a model that does not exist. So do refusals that waiting does not cure, even with HTTP 429: money or an allowance used up for good (`insufficient_quota`, billing, a monthly cap, "credit balance is too low", a plan that does not include the model), a workspace cap only its admin can raise, and a single request larger than the limit itself ("request too large"). Other passing errors (a dropped connection, a 500) are retried three times, 2, 4 and 8 seconds apart, as before; attempts spent waiting for a limit do not use those three up.

**What is shown.** The conversation says who refused, why, and until when it waits ("Anthropic refused the request for its rate limit. The run waits until 14:32, the time it named, then carries on by itself. Stop ends it."), and whether that time is the provider's or pi²'s own backoff. Activity shows the run with "rate limit · until 14:32" (or "provider overloaded") in place of the spinner, and the menu bar's list says "waiting for limit" for one that is not a sub-chat. Each refusal stays in the transcript as a failed attempt; attempts that failed in a row show as one row, which says how many there were. The run is busy all the while, so a sub-chat's `delegate` call keeps waiting for it, and a message typed meanwhile is queued as usual.

**Stopping it.** Stop, in the conversation or in Activity, ends the run as it ends any run. Stopping the conversation a sub-chat belongs to stops the sub-chat too.

**A restart.** The wait is the run's own stored sleep (pi durable's retry, see below), so it survives the engine stopping or being killed: the next engine goes on waiting until the same time, without asking in between, and the conversation and Activity show it again. (Killed in the instant between storing the sleep and noting the wait, the next engine notes the wait again from the sleep; it then no longer knows when the wait began, so the six hours count from the restart.) If the engine stops while the request after a wait is on its way, that request counts as one of the three ordinary retries, as any request cut off by a restart does.

**engine.log** has a line when a wait starts (who refused, until when, and whether the provider named the time), and when it ends: the run carried on (after how long, and how many refusals), it was stopped, the provider answered with another error, or it gave up. The lines name the conversation, as in `conversation 12 is waiting for Anthropic's rate limit: until 2026-11-17T20:15:03Z, the time it named`. A refusal in between has no line of its own; the transcript has each. A run that ends on an error from the provider all the same, a limit or any other, has a line of its own too, with the provider's message (see [The logs](architecture.md#the-logs)).

**A sub-chat.** A sub-chat that waits keeps the `delegate` call that started it waiting. One whose run ends on the provider's error all the same gives `delegate` a result that says so in the provider's words, and that the sub-chat can be carried on by passing its number as `chat` ([architecture.md](architecture.md#sub-chats)).

## Telling an agent that hands out work, and the person

An agent that hands out work to sub-chats ([architecture.md](architecture.md#sub-chats)) can run many at once, and so use up a window quickly. Since a refused run waits and carries on (above), nothing is lost when it does, but an agent or the person may want to start fewer runs, or none, on a subscription that is nearly used up. pi² tells them three ways, all from the same readings Usage shows.

**In `delegate`'s result.** When a window of the subscription the sub-chat ran on (its own model's, whatever the agent that handed out the work runs on) is 80% used or more, the result ends with one line that names the subscription, since one agent may hand work to agents on different ones, and each such window, how much of it is used and when it resets, in the Mac's local time and from now:

> Plan limits: the Anthropic subscription (Max), which this sub-chat runs on, has 5-hour window 84% used, resets at 15:30 (in 1 h 12 min). A run the provider refuses for its limit waits for the reset and carries on by itself.

Below 80%, and for a model that is not on a subscription, the result says nothing of the windows. A window whose reset has passed since it was read is not counted. The line comes with a sub-chat that finished and one that did not, new or continued.

**In `sub_chats`' list.** The line above only comes once a sub-chat has finished, so an agent can also ask before it starts any: `sub_chats` with `list` ends with every signed-in subscription's windows, how much of each is used and when it resets, when they were read, and which subscription the conversation itself and each agent it can hand work to runs on (an agent with no model of its own runs on the default one):

```
Plan limits, as last read. A run the provider refuses for its limit waits for the reset and carries on by itself.
- Anthropic subscription (Max), which this conversation, Forge and Scout run on: 5-hour window 62% used, resets at 15:30 (in 2 h 10 min); this week 91% used, resets on Friday 20 November at 09:00 (in 3 days). Read 2 min ago.
- OpenAI Codex subscription (Plus), which Worker runs on: 5-hour window 12% used, resets at 17:02 (in 3 h 42 min). Read 40 s ago, from the answer to a request.
```

This is not a tool of its own: `sub_chats` is offered only with `delegate`, so an agent that cannot hand out work is sent nothing more in its prompt, and one that can is sent a sentence more in `sub_chats`' description. Listing asks no provider; it says what was last read, and how long ago.

**In the Inbox, for the person.** When a window of a signed-in subscription passes 90% while runs on that subscription are going (conversations whose model is on it, sub-chats included, with work running), a notice goes to the Inbox: which subscription and window, how much is used, when it resets, and which runs were going, each a link to its conversation. It is information, not a request: it says that a run the provider refuses waits for the reset and carries on by itself, and that nothing needs doing. It is not counted in the Dock's badge or the menu bar, which count what waits on the person, and posts no notification; the sidebar's Inbox row counts it in grey. engine.log has a line for it too.

A window is noticed once per reset: not again while it stays above 90%, nor after the notice is dismissed, until its reset time has passed or, for a window whose provider gives none, a reading shows it below 80%. A notice leaves the Inbox by itself when its window resets, and with its subscription when that is signed out. A window past 90% with no run on its subscription is not noticed until a run on it starts. Notices, and which windows were noticed, are kept in `limits.json`, so a restart neither loses nor repeats one.

### How it works

The retrying is pi durable's: a failed request becomes a stored sleep in the run's checkpoint (`pi.live`'s `generation.retry`), which a restart resumes and Stop ends. Unpatched, it retries three times, 2, 4 and 8 seconds apart, and reads nothing of what the provider said, which only reaches it as the error's text: pi-ai turns a refused response into an error message and drops its status and headers. So:

- each model request is made with a `fetch` of the engine's that notes a refused response's status and headers, and the body of a 429 or 529, in memory only, and matches the note to the error the request ends with (`noticingRefusals` in `engine/src/limitwait.ts`). Providers that do not use `fetch` (Codex over a WebSocket) are judged by the error's text alone;
- a patch to pi durable (`engine/scripts/patch-dependencies.ts`) asks the engine about each failed request before its own rule: how long to wait, or to end the run, and how many attempts were spent on such waits, which then do not count against its three retries;
- the engine keeps each wait (when it began, until when, how many refusals, whose) in a session document, `pi2.limitWaits`, for what is shown, the log, and the 6 hours.

The same knowledge of the plan's windows that **Usage** shows is not used to hold back a run before it is refused; see the Known limits.

## What is kept

The last good reading of each signed-in subscription (plan, windows, when it was read) is kept in `limits.json` in the data folder, so it shows at once after a restart. It holds no token. Signing a subscription out removes its reading.

## For developers

The engine sends `{ event: "limits", providers: [...], notices: [...] }` to an app as it connects and whenever something changes. Each provider is:

```
{ id, name, plan, note, reports: "usage" | "responses" | "none",
  windows: [{ id, label, usedPercent, resetsAt }],
  fetchedAt, source: "usage" | "responses" | null, error, errorAt, refreshing }
```

and each notice:

```
{ id, provider, name, plan, window, label, usedPercent, resetsAt, at,
  runs: [{ conversationId, rootConversationId, title, agentName, subChat }], more? }
```

Times are milliseconds since 1970; `usedPercent` is 0–100. `limits.refresh` (optionally `{ id }`) asks again, within the limits above, and answers with the same event. `limits.dismiss` `{ id }` takes a notice away.

The limits feature answers `planLimits()` ([features.ts](../engine/src/features.ts)) with the providers above, which `delegate` (`engine/src/extensions.ts`) and `sub_chats` (`engine/src/subchats.ts`) put in words with `nearlyUsedUp` and `limitsReport` from `engine/src/limits.ts`. The notices are its own: it looks for a window to notice when a reading comes and when what is running changes, and only reads which model a running conversation is on when some window is past 90% and not yet noticed. `engine/test/planwindows.ts` checks the wording, then runs an engine with two stand-in subscriptions signed in under a test Keychain service: Claude, whose usage address is a stand-in on 127.0.0.1, and GitHub Copilot, whose requests go to a stand-in over TLS that sets the premium requests in its answers' headers and can hold an answer back so a run is going when they arrive.

For tests, the usage addresses can be pointed elsewhere with `PI2_LIMITS_ANTHROPIC_URL`, `PI2_LIMITS_CODEX_URL` and `PI2_LIMITS_KIMI_URL`, and the minimum time between two requests to one provider set with `PI2_LIMITS_MIN_INTERVAL_MS`.

A conversation's state has `limitWait` while its run sleeps for a limit, and its row in the `activity` event has `limit` while it waits; both are `{ kind: "rate_limit" | "overloaded", since, until, told, refusals, provider }`, with times in milliseconds since 1970, `told` saying whether the provider named `until`, and `provider` its name. `engine/test/limitwait.ts` checks the reading of refusals and the waits, and runs an engine against a stand-in provider on 127.0.0.1 that refuses with 429 and 529, with and without a time; `PI2_LIMIT_BACKOFF_MS` sets the first backoff step (15 seconds otherwise) and `PI2_LIMIT_WAIT_MAX_MS` the longest wait when no time is named (6 hours otherwise).

## Known limits

- Every source is undocumented and may change. A change shows as "Could not read the limits", not as wrong figures, but it needs a fix in `engine/src/limits.ts`.
- Anthropic's usage address may refuse to answer ("too many requests") for a while; the figures then come from the next answer to a request on that subscription.
- Copilot's figures appear only after a request in pi², and premium requests are the only allowance shown (chat and completions are unlimited on paid plans).
- The figures from answers are as of the start of that answer.
- Signing in again to a different account of the same provider, without signing out first, keeps showing the old account's figures until they are next read.
- Nothing holds a run back before a provider refuses it, however full a window is: the wait starts with the first refusal. An agent that hands out work and the person are told how the windows stand ([above](#telling-an-agent-that-hands-out-work-and-the-person)), and what to do about it is theirs.
- What a conversation runs on is read when a notice is considered and kept while its work goes on, so a model changed in the middle of a run counts from that run's end.
- A summary of earlier messages (compaction) that a provider refuses for its limit is still retried only three times, and then fails as it did before.
