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

## What is kept

The last good reading of each signed-in subscription (plan, windows, when it was read) is kept in `limits.json` in the data folder, so it shows at once after a restart. It holds no token. Signing a subscription out removes its reading.

## For developers

The engine sends `{ event: "limits", providers: [...] }` to an app as it connects and whenever something changes. Each provider is:

```
{ id, name, plan, note, reports: "usage" | "responses" | "none",
  windows: [{ id, label, usedPercent, resetsAt }],
  fetchedAt, source: "usage" | "responses" | null, error, errorAt, refreshing }
```

Times are milliseconds since 1970; `usedPercent` is 0–100. `limits.refresh` (optionally `{ id }`) asks again, within the limits above, and answers with the same event.

For tests, the usage addresses can be pointed elsewhere with `PI2_LIMITS_ANTHROPIC_URL`, `PI2_LIMITS_CODEX_URL` and `PI2_LIMITS_KIMI_URL`, and the minimum time between two requests to one provider set with `PI2_LIMITS_MIN_INTERVAL_MS`.

## Known limits

- Every source is undocumented and may change. A change shows as "Could not read the limits", not as wrong figures, but it needs a fix in `engine/src/limits.ts`.
- Anthropic's usage address may refuse to answer ("too many requests") for a while; the figures then come from the next answer to a request on that subscription.
- Copilot's figures appear only after a request in pi², and premium requests are the only allowance shown (chat and completions are unlimited on paid plans).
- The figures from answers are as of the start of that answer.
- Signing in again to a different account of the same provider, without signing out first, keeps showing the old account's figures until they are next read.
