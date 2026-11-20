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

**What is not waited for.** A bad key, a refused request or a model that does not exist can end a run at once. So do refusals that waiting does not cure, even with HTTP 429: money or an allowance used up for good (`insufficient_quota`, billing, a monthly cap, "credit balance is too low", a plan that does not include the model), a workspace cap only its admin can raise, and a single request larger than the limit itself ("request too large"). One exception: a plan's short window used up, such as OpenCode Go's "usage limit reached (5-hour, resets in 2h 17m)", is waited out when it names a reset no more than twelve hours off, in words or otherwise; the same error for a month's allowance, or with no time named, still ends the run (#560). Other passing errors (such as HTTP 500) still use the ordinary three retries, 2, 4 and 8 seconds apart. Attempts spent waiting for a limit or for the network do not use those three up.

**What is shown.** A run that waits for a limit is shown as waiting, not working, wherever a run is shown (#343):

- **The conversation** says who refused, why, and until when it waits ("Anthropic refused the request for its rate limit. The run waits until 14:32, the time it named, then carries on by itself. Stop ends it."), and whether that time is the provider's or pi²'s own backoff.
- **Its row in the sidebar**, and its pane's header and its row in Branches, have an hourglass in place of the spinner, and the sidebar row "until 14:32"; the full sentence is on hover. A conversation whose sub-chats are folded away says "3 at limit" when three of them wait.
- **Activity** shows the run with "waiting for Anthropic's limit · until 14:32" (or "Anthropic overloaded · until 14:32") in place of the spinner, and counts it apart: "11 running, 8 waiting for a limit" at the top, "11 running" and "8 at limit" in the sidebar.
- **The conversation that handed out the work** has one line above its message field, kept up to date rather than repeated: "8 sub-chats wait for Anthropic's limit until 18:20. They carry on by themselves; Stop on a sub-chat ends its wait.", a part for each provider when they differ.
- **The menu bar** says the same of each conversation in its list: "waiting for Anthropic's limit · until 14:32", or "working · 8 sub-chats at limit".
- **The Inbox, and a notification**, once when a provider's limit is reached and once when work carries on ([below](#in-the-inbox-and-as-a-notification)).

All of it comes from Activity's `limit`, so it is shown as long as the run waits: between two refusals as well as during a sleep. Each refusal stays in the transcript as a failed attempt; attempts that failed in a row show as one row, which says how many there were. The run is busy all the while, so a sub-chat's `delegate` call keeps waiting for it, and a message typed meanwhile goes with the first request after the wait (**A message meanwhile**, below).

**Carrying on with another model** (#358). On the waiting line in the conversation, choose **Carry on with…**, then pick a different model from the ones you have connected. The run ends its wait and sends the next request to that model, with any queued message to steer. On a parent's sub-chat waiting line, one choice moves its waiting sub-chats to the same model without changing the parent's model or stopping its `delegate` calls. Runs no longer asleep are left alone. The transcript says you changed the model and names the old and new models. The choice stays in effect; use the toolbar's model menu to change it back. Nothing switches by itself, and a billing or plan refusal that does not start a wait has no **Carry on with…** control.

**Stopping it.** Stop, in the conversation or in Activity, ends the run as it ends any run. Stopping the conversation a sub-chat belongs to stops the sub-chat too.

**A message meanwhile** (#324). A message sent to the waiting conversation cannot be answered before the limit resets, so it does not end the wait: the provider would only refuse it, and a run ended to read it would start again into the same refusal. Sent to steer, the default, it stays queued until the wait ends, and is then placed in the conversation before the request after the wait is made, so that request carries it: the first answer after the reset reads it. Until then its chip above the message field says "After Anthropic's limit, 18:20", and removing it takes it back. Before it is sent, the line above the message field says the same: "Atlas reads this after the wait for Anthropic's limit, at 18:20; until then you can take it back." Stop is beside it. Sent queued, it keeps its meaning and is read once the agent has answered. Stop ends the run at any time; a message still queued then is kept, as for any run stopped, and goes with the next one. Until #324 a steer waited for the answer to the request after the wait, and so for an answer to the conversation as it was before the message. A sub-chat's limit is another matter: a message to the conversation that waits on that sub-chat with `delegate` ends that wait at once, as any message does ([architecture.md](architecture.md#a-message-while-an-agent-waits)), and the sub-chat goes on waiting by itself.

**A restart.** The wait is the run's own stored sleep (pi durable's retry, see below), so it survives the engine stopping or being killed: the next engine goes on waiting until the same time, without asking in between, and the conversation and Activity show it again. (Killed in the instant between storing the sleep and noting the wait, the next engine notes the wait again from the sleep; it then no longer knows when the wait began, so the six hours count from the restart.) If the engine stops while the request after a wait is on its way, that request counts as one of the three ordinary retries, as any request cut off by a restart does.

**engine.log** has a line when a wait starts (who refused, until when, and whether the provider named the time), and when it ends: the run carried on (after how long, and how many refusals), it was stopped, the provider answered with another error, or it gave up. The lines name the conversation, as in `conversation 12 is waiting for Anthropic's rate limit: until 2026-11-17T20:15:03Z, the time it named`. A refusal in between has no line of its own; the transcript has each. A run that ends on an error from the provider all the same, a limit or any other, has a line of its own too, with the provider's message (see [The logs](architecture.md#the-logs)).

**A sub-chat.** A sub-chat that waits keeps the `delegate` call that started it waiting. One whose run ends on the provider's error all the same gives `delegate` a result that says so in the provider's words, and that the sub-chat can be carried on by passing its number as `chat` ([architecture.md](architecture.md#sub-chats)).

## When the network drops

If pi² cannot look up the provider's name or connect, or the connection is reset or times out, the run asks again on its own. So it does when the provider closes the stream before or during an answer (#550): HTTP/2 ends a stream with a code of its own — `NGHTTP2_ENHANCE_YOUR_CALM`, which asks for fewer streams at once, or `NGHTTP2_REFUSED_STREAM` — or the connection is reset (`ECONNRESET`, `UND_ERR_SOCKET`, undici's “terminated” and “other side closed”). It waits about 2, 5, 15 and 30 seconds, then a minute at a time, up to about ten minutes from the first failure; one that asked for less begins at 15 seconds. A successful request resets the count, even if that request only asked to use a tool. A provider's error response is not a closed connection: a 4xx with a message, a refusal, a content flag, and a limit that names a time end the run or wait as they did before. An answer cut off part way through is not kept: the whole request is asked again, so nothing the model wrote appears twice. [Models on this Mac](local-models-running.md#when-it-cannot-start-or-stops-unexpectedly) and provider limits keep their own retries.

The conversation shows one line while it waits: **No network just now. Trying again…**, or, when the provider closed the stream, **The provider closed the connection. Trying again…** When a request succeeds, the conversation says it carried on and how long it waited, in the manner of “The network is back.” or, after a closed stream, “The provider answered again.” Neither the notice nor the intervening failed attempts are sent to the model. A message sent to steer during a pause goes with the next request, just as it does during a limit wait. Stop ends the pause immediately. The pause survives an engine restart.

This works in sub-chats too. A `delegate` call waiting on a sub-chat stays waiting while it tries again. If an outage outlasts the wait, the run ends on the original kind of error, without a new message about the wait. `delegate` still gives the provider error and tells the agent how to carry on the sub-chat.

## Telling an agent that hands out work, and the person

An agent that hands out work to sub-chats ([architecture.md](architecture.md#sub-chats)) can run many at once, and so use up a window quickly. Since a refused run waits and carries on (above), nothing is lost when it does, but an agent or the person may want to start fewer runs, or none, on a subscription that is nearly used up. pi² tells them three ways, all from the same readings Usage shows.

**In `delegate`'s result.** When a window of the subscription the sub-chat ran on (its own model's, whatever the agent that handed out the work runs on) is 80% used or more, the result ends with one line that names the subscription, since one agent may hand work to agents on different ones, and each such window, how much of it is used and when it resets, in the Mac's local time and from now:

> Plan limits: the Anthropic subscription (Max), which this sub-chat runs on, has 5-hour window 84% used, resets at 15:30 (in 1 h 12 min). A run the provider refuses for its limit waits for the reset and carries on by itself.

Below 80%, and for a model that is not on a subscription, the result says nothing of the windows. A window whose reset has passed since it was read is not counted. The line comes with a sub-chat that finished and one that did not, new or continued. Separately, `delegate`'s answer, later answers and `sub_chats`' list and `wait` give the sub-chat's own [usage so far](architecture.md#sub-chats), regardless of its subscription.

**In `sub_chats`' list.** The line above only comes once a sub-chat has finished, so an agent can also ask before it starts any: `sub_chats` with `list` ends with every signed-in subscription's windows, how much of each is used and when it resets, when they were read, and which subscription the conversation itself and each agent it can hand work to runs on (an agent with no model of its own runs on the default one):

```
Plan limits, as last read. A run the provider refuses for its limit waits for the reset and carries on by itself.
- Anthropic subscription (Max), which this conversation, Forge and Scout run on: 5-hour window 62% used, resets at 15:30 (in 2 h 10 min); this week 91% used, resets on Friday 20 November at 09:00 (in 3 days). Read 2 min ago.
- OpenAI Codex subscription (Plus), which Worker runs on: 5-hour window 12% used, resets at 17:02 (in 3 h 42 min). Read 40 s ago, from the answer to a request.
```

This is not a tool of its own: `sub_chats` is offered only with `delegate`, so an agent that cannot hand out work is sent nothing more in its prompt, and one that can is sent a sentence more in `sub_chats`' description. Listing asks no provider; it says what was last read, and how long ago.

**In `sub_chats`' list, which sub-chats wait.** Each sub-chat's line says how it stands, and one that waits for a limit says for which and until when, so an agent can hand new work to an agent on another subscription rather than one that waits:

```
- 14: Scout, “Fix the parser”. Waiting for Anthropic's rate limit until 18:20 (in 1 h 45 min), the time Anthropic named; it carries on by itself then; last used 12 min ago. …
```

### In the Inbox, and as a notification

The person is told the story of a subscription's window in one notice, which goes from stage to stage rather than adding a card for each, so that it reads as one story and not three alarms (#343):

1. **Nearly used up.** When a window of a signed-in subscription passes 90% while runs on that subscription are going (conversations whose model is on it, sub-chats included, with work running), a notice goes to the Inbox: which subscription and window, how much is used, when it resets, and which runs were going, each a link to its conversation. It says that a run the provider refuses waits for the reset and carries on by itself, and that nothing needs doing. No notification.
2. **Limit reached.** When the provider refuses runs for its rate limit and one of them waits five minutes or more from its first refusal (a time named that far off, or a backoff grown that long), the notice of the window that refused becomes "Anthropic Max, 5-hour window: limit reached": how many runs wait, until when, whether the provider named the time, and which runs, kept up to date as more are refused or the time moves. A shorter wait, such as a per-minute limit of 30 seconds, is no news. The window is the one whose reset is the time named, give or take ten minutes, or else the one most used at 90% or more; with no such window, as for a key or an endpoint, which report no windows, the notice names only the provider. While it stands, no 90% notice comes for that subscription. A waiting run that is overloaded rather than limited is not counted.
3. **Carrying on.** When the provider answers one of those runs again, the limit has reset: the notice becomes "…: carrying on", with the runs that waited and how long, and leaves the Inbox twelve hours later unless dismissed first. The other runs, asleep until the same time give or take their jitter, carry on in the next moments and are not news again.

The notice says how the story went in one line ("Passed 90% at 16:02 · limit reached at 16:35 · carried on at 18:20"). If every run that waited stops or changes models before the provider answers, nothing waits any more and a "limit reached" notice goes. Changing models is not evidence that the old provider's limit reset.

Notices are information, not requests: they are not counted in the Dock's badge or the menu bar, which count what waits on the person; the sidebar's Inbox row counts them in grey. The second and third stages also post a macOS notification, once each, while pi² is in the background, unless **Notify me when a subscription's limit is reached, and when work carries on** is off in Settings › General (it is on by default). It asks macOS nothing by itself: without notifications allowed for pi² (turning on either switch there asks), nothing is posted. The first stage posts none. engine.log has a line for each stage.

A window is noticed at 90% once per reset: not again while it stays above 90%, nor after the notice is dismissed, until its reset time has passed or, for a window whose provider gives none, a reading shows it below 80%. A 90% notice leaves the Inbox by itself when its window resets, and with its subscription when that is signed out. A window past 90% with no run on its subscription is not noticed until a run on it starts. A dismissed notice that its limit was reached is not shown again in that episode, but carrying on is: it is news of its own. Notices, and which windows were noticed, are kept in `limits.json`, and the episode a run waits in is worked out again from the waits the engine keeps, so a restart neither loses nor repeats one.

### How it works

The retrying is pi durable's: a failed request becomes a stored sleep in the run's checkpoint (`pi.live`'s `generation.retry`), which a restart resumes and Stop ends. Unpatched, it retries three times, 2, 4 and 8 seconds apart, and reads nothing of what the provider said, which only reaches it as the error's text: pi-ai turns a refused response into an error message and drops its status and headers. So:

- each model request is made with a `fetch` of the engine's that notes a refused response's status and headers, and the body of a 429 or 529, in memory only, and matches the note to the error the request ends with (`noticingRefusals` in `engine/src/limitwait.ts`). Providers that do not use `fetch` (Codex over a WebSocket) are judged by the error's text alone;
- a patch to pi durable (`engine/scripts/patch-dependencies.ts`) asks the engine about each failed request before its own rule: how long to wait, or to end the run, and how many attempts were spent on such waits, which then do not count against its three retries;
- the engine keeps each wait (when it began, until when, how many refusals, whose) in a session document, `pi2.limitWaits`, for what is shown, the log, and the 6 hours.

A project can use the readings **Usage** shows to hold back new starts ([project limits](projects.md#83-limits-and-the-one-admission-check)). Outside a project, the figures do not hold work back.

## The prompt cache

Every request sends the whole conversation again. A provider with a prompt cache keeps what it read of the last request for a while, and the next request that starts the same way reads it from there instead, at a tenth of the price or less, and counts for less of a subscription's allowance. By default the cache lasts five minutes. A request after a longer pause reads nothing from it and writes the whole conversation into it again: for a conversation of 150,000 tokens on Anthropic's API, that is 1.25 times the price of all of it, where reading it costs 0.1 times (#159).

A conversation that hands out work is the one that pauses longest: it waits for its sub-chats for tens of minutes, then pays for its whole context again. So **from its first `delegate` call on, a conversation asks for the long cache** (pi-ai's `cacheRetention: "long"`). Every other conversation, its sub-chats included, stays on the short one. That is what Claude Code does on a Claude subscription: an hour for the main conversation, five minutes for its subagents ([How Claude Code uses prompt caching](https://code.claude.com/docs/en/prompt-caching#which-ttl-each-request-gets)).

What the long cache is, by provider:

| Provider | Long cache | Costs, against the short one |
|---|---|---|
| Anthropic, by key or a Claude subscription | An hour (`cache_control.ttl: "1h"`) | A write costs 2 times the input price instead of 1.25; a read costs the same. On a subscription the cost is part of the plan's allowance; Anthropic does not say how writes and reads weigh in it, and its own Claude Code asks for the hour there by default |
| Amazon Bedrock, Claude models that have it | An hour (`cachePoint.ttl`) | As Anthropic's |
| OpenAI's API | Extended retention (`prompt_cache_retention: "24h"` on older models; on GPT-5.6 and later the same 30 minutes as by default) | Nothing more |
| ChatGPT sign-in (Codex), Google, Mistral, a custom OpenAI-compatible endpoint | Nothing different is sent | — |

A one-hour write costs more only on what a turn adds; a rewrite after a long wait costs the whole context. The first round of `delegate` calls still finds the cache gone when it returns, since the request that made those calls asked for the short cache; the rounds after it do not, as long as each takes less than the hour. A wait of more than an hour loses it all the same.

**A provider that refuses it.** A gateway or endpoint that does not know the long cache may refuse a request that asks for it. A request refused before any answer, with an error that names the cache (`ttl`, `cache`, `retention`) and is not a limit, a bad key or a server error, is sent again at once with the short cache; the conversation sees only the answer. That provider is then not asked for the long cache again until the engine restarts, and `engine.log` says so once: `Stand-in refused a request that asked for the long prompt cache (400 invalid_request_error: cache_control.ttl: Extra inputs are not permitted); it was sent again with the short cache, and Stand-in is not asked for the long one again until the engine restarts`. If the request is refused the same way with the short cache too, the long cache was not the cause, and it is asked for again next time.

**Seeing the effect.** `engine.log` has a line when a conversation starts asking for the long cache (`conversation 12 hands out work: its requests ask Anthropic for the long prompt cache from now on`), and one for each request that comes more than five minutes after the one before it in the same conversation, saying what it read from the cache and which lifetime the request before it asked for:

```
conversation 12 read 143,912 tokens from the prompt cache after 31 min without a request; the request before asked for the long cache
conversation 14 read nothing from the prompt cache after 6 min without a request, and wrote 88,301 tokens to it again; the request before asked for the short cache
```

A provider that reports no cache writes (OpenAI's) shows a miss as input sent again instead. **Usage** shows the cost: pi-ai prices a one-hour write at twice the input price, and each request's `usage` keeps `cacheRead` and `cacheWrite`.

**How it works** (`engine/src/cache.ts`). pi durable sends each conversation's requests with a provider session id of its own (`pi.provider`); a hook before each request notes which conversation it belongs to, and the models the harness is given are wrapped so that a request of a conversation that has a sub-chat is sent with `cacheRetention: "long"`, unless its caller chose a lifetime itself (a compaction asks for none). The wrapper holds the request's events until its answer begins, so a refusal of the long cache can be sent again unseen. `engine/test/cache.ts` runs an engine against a stand-in Anthropic endpoint on 127.0.0.1 that answers, hands out work, and then refuses the one-hour cache; `PI2_CACHE_PAUSE_MS` sets the pause after which a request has a line in `engine.log` (five minutes otherwise).

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
  stage: "nearly" | "reached" | "carried_on", nearlyAt?, reachedAt?, carriedOnAt?,
  waiting?, until?, told?,
  runs: [{ conversationId, rootConversationId, title, agentName, subChat }], more? }
```

Times are milliseconds since 1970; `usedPercent` is 0–100, or null (with `window` and `label` empty) for a provider that reports no windows. A notice kept before the stages has no `stage`, which means `nearly`. `waiting`, `until` and `told` are set while it is `reached`. `limits.refresh` (optionally `{ id }`) asks again, within the limits above, and answers with the same event. `limits.dismiss` `{ id }` takes a notice away.

The limits feature answers `planLimits()` ([features.ts](../engine/src/features.ts)) with the providers above, which `delegate` (`engine/src/extensions.ts`) and `sub_chats` (`engine/src/subchats.ts`) put in words with `nearlyUsedUp` and `limitsReport` from `engine/src/limits.ts`. The notices are its own: it looks for a window to notice when a reading comes and when what is running changes, and only reads which model a running conversation is on when some window is past 90% and not yet noticed. `engine/test/planwindows.ts` checks the wording, then runs an engine with two stand-in subscriptions signed in under a test Keychain service: Claude, whose usage address is a stand-in on 127.0.0.1, and GitHub Copilot, whose requests go to a stand-in over TLS that sets the premium requests in its answers' headers and can hold an answer back so a run is going when they arrive.

For tests, the usage addresses can be pointed elsewhere with `PI2_LIMITS_ANTHROPIC_URL`, `PI2_LIMITS_CODEX_URL` and `PI2_LIMITS_KIMI_URL`, and the minimum time between two requests to one provider set with `PI2_LIMITS_MIN_INTERVAL_MS`.

A conversation's state has `limitWait` while its run sleeps for a limit, and its row in the `activity` event has `limit` while it waits; both are `{ kind: "rate_limit" | "overloaded", since, until, told, refusals, provider }`, with times in milliseconds since 1970, `told` saying whether the provider named `until`, and `provider` its name. `engine/test/limitwait.ts` checks the reading of refusals and the waits, and runs an engine against a stand-in provider on 127.0.0.1 that refuses with 429 and 529, with and without a time; `PI2_LIMIT_BACKOFF_MS` sets the first backoff step (15 seconds otherwise), `PI2_LIMIT_WAIT_MAX_MS` the longest wait when no time is named (6 hours otherwise), and `PI2_LIMIT_REACHED_MS` how long a run must wait for a limit to count as reached (5 minutes otherwise).

The wait payload also includes `model` (`{ provider, modelId }`, or null for a wait restored without the refusing model). The app sends `conversation.carryOn { id, model, since }` for the wait it shows, or `{ id, model, subChats: true }` for a parent's waiting sub-chats. The engine checks which generation retries are still asleep and changes the model, advances the sleep and adds a display-only transcript entry in the same commit. The retry places queued steers as usual, then prepares its first attempt on the selected model. The original submission and task ownership are unchanged. `engine/test/limitwait.ts` covers both requests.

The episodes of a provider's limit (the runs that wait for its rate limit, from the first refusal to the first answer after it) are worked out by `Waits` in `engine/src/limitwait.ts` from the waits it keeps, and told to every feature's `limitEpisode` as `{ phase: "reached" | "carried_on" | "ended", episode: { provider, providerName, since, until, told, waiting, runs }, at }`; the limits feature turns them into the stages of its notices. `limitWaitOf(id)` gives a conversation's wait, for `sub_chats`' list. The app shows a run as waiting from Activity's `limit`, and a parent's line from its sub-chats' rows there; it posts a notification for a notice that comes to `reached` or `carried_on` after it first heard of the notices (`Notifier.limitNotices`), so a launch posts none.

## Known limits

- Every source is undocumented and may change. A change shows as "Could not read the limits", not as wrong figures, but it needs a fix in `engine/src/limits.ts`.
- Anthropic's usage address may refuse to answer ("too many requests") for a while; the figures then come from the next answer to a request on that subscription.
- Copilot's figures appear only after a request in pi², and premium requests are the only allowance shown (chat and completions are unlimited on paid plans).
- The figures from answers are as of the start of that answer.
- Signing in again to a different account of the same provider, without signing out first, keeps showing the old account's figures until they are next read.
- Outside a project, the plan readings do not hold a run back before a provider refuses it, however full a window is: the wait starts with the first refusal. An agent that hands out work and the person are told how the windows stand ([above](#telling-an-agent-that-hands-out-work-and-the-person)). Project limits are a check on new starts, not a reservation; they do not stop work already running.
- Nearly-used-up notices can keep a run's original provider until its work ends. A change through **Carry on with…** does remove the run from the old provider's reached-limit notice.
- A summary of earlier messages (compaction) that a provider refuses for its limit is still retried only three times, and then fails as it did before.
