
# Waking an agent that is not answering

An agent answers when it is sent a message, and stops when it has answered. Two things it leaves running can start an answer of their own once they end, without the person doing anything: a sub-chat it handed work to without waiting (#158), and a command it started in the background and asked to be woken for (#104). The code is `engine/src/wakes.ts`.

## What wakes an agent

- **A sub-chat started with `delegate` and `wait: false`.** The call returns at once with the sub-chat's number ("Sub-chat 12, “Fix login”, with Forge, is working on it. Its answer will come to you as a message when it is done…"), and the agent can answer the person, hand out more work or stop. When the sub-chat answers, or its run ends without an answer, the agent is woken with exactly what `delegate` would have answered: the sub-chat's answer, which sub-chat it was and how to continue it, and the line about the plan's limits when a window is nearly used up ([limits.md](limits.md#telling-an-agent-that-hands-out-work-and-the-person)). Continuing a sub-chat (`chat`) with `wait: false` works the same way. The waiting form stays the default: an agent that does not pass `wait: false` sees no change, until the person sends it a message to steer while it waits: that ends the wait, and the sub-chat carries on as one started with `wait: false` ([architecture.md](architecture.md#a-message-while-an-agent-waits)).
- **A command started with `bash`, `background: true` and `wake: true`.** When the command ends, the agent is woken with how it ended ("exited with code 1 after 4 minutes") and the end of what it printed: the last 40 lines, 4,000 characters at most, or all of it when that is less. Reading it there does not change what counts as read for the `background` tool. An end the agent already knows of does not wake it: one it stopped itself, or one the call that started the command reported, because the command was over within its first second.

For a command already running, including one moved to the background at its time limit, `background` with `action: "wake"` and its `id` asks for the same wake (#317). Asking twice watches it once. It refuses commands already over or belonging to another conversation, and does not turn back on a wake the person turned off.

Only a conversation of its own is woken. A sub-chat's answers go to the agent that handed it the work, not to anyone reading its transcript, so a sub-chat cannot pass `wake: true` (the call is refused before anything is started), and it cannot hand out work.

## How it is woken

What ended is kept until the conversation is not answering, then handed to its agent as one message, which starts an answer like any message the person sends:

```
[pi² woke you: these 2 ended while you were not answering, oldest first.]

Sub-chat 12 “Fix login” answered:

…its answer…

---

Background command bg-3 (`npm test`) exited with code 1 after 4 minutes. The end of what it printed:
…
```

- **One at a time, together.** What ends while the agent is answering waits for that answer to end, and everything waiting then comes in one message, in the order it ended. A message from the person sent meanwhile is answered first, as it was queued first.
- **The person sees it.** The conversation gets a row, "pi² woke the agent: sub-chat 12 “Fix login” answered", in place of the message the model reads. Open its chevron to read exactly what the agent was given, including all results when several ended together. It starts closed and remembers whether you opened it. For a single command it also has **Output**, as the command's own lines do. A conversation that was woken moves to the top of the sidebar, as one the person wrote in does.
- **Waiting for one instead.** An agent with several sub-chats working can wait for the next one to finish, whichever it is, with `sub_chats` and `action: "wait"` (or only some of them, with `chats`). It gets that sub-chat's answer as the call's result, together with any that finished and were not yet handed over, and is not woken for them as well. With nothing left to wait for, it says so at once. This is an action of `sub_chats` rather than of `delegate` because it is about sub-chats already working, which `sub_chats` lists and archives; `delegate` hands out work. `sub_chats`' list says of such a sub-chat that it is working "and its answer will come to you as a message".

## What the person sees and can do

Above the message field, a strip like the one for background commands names what will wake the agent: each sub-chat and command, how long it has been going, or "ended" for what is waiting to be handed over. Each has **Don't Wake** (a bell crossed out): the sub-chat goes on working and its answer stays in it, the command goes on running, but the agent is not woken for it. With more than one, **Don't Wake** at the top turns them all off. The conversation gets a line: "You turned off waking the agent for …".

When the agent is not woken for a while, the strip says why, and so does a line in the conversation, once:

- **The person stopped the agent.** Stop ends the answer, as always, and from then on nothing wakes the agent until the person sends a message: "You stopped the agent, so pi² will not wake it until you send a message. What ends meanwhile is kept for it." After that message is answered, what was kept is handed over. **Wake When Done** in the strip lets it be woken again without a message. Stop does not stop sub-chats started without waiting, or background commands: they are meant to outlast an answer, and each can be stopped on its own (the sub-chat in the sidebar, the command in the strip or Activity).
- **Today's budget is used up.** "pi² did not wake the agent: Today's budget of $5.00 is used up. It is woken once there is budget again." A wake costs what any answer costs, so it is held exactly as a message from the person would be refused. It goes as soon as the budget is raised, turned off or a new day begins.
- **The hourly cap is reached.** See below.

## The bounds

- **The daily budget.** As above: no wake starts while the budget is used up.
- **The turn limit.** A wake starts a run like any message, under the agent's turn limit.
- **Ask first.** A wake starts an answer, not an action. What the woken answer does is judged as always: under Ask first, its commands and edits wait for the person, and rules and Always Allow cover what they always cover.
- **Archived or deleted.** An archived or deleted conversation is never woken. Archiving or deleting it stops the sub-chats it started without waiting, as it stops its background commands, and what it was waiting for is let go: nothing is handed over later, even if it is restored. An archived one gets a line saying what it will not be woken for; a sub-chat's answer, if it came, stays in the sub-chat.
- **At most 30 wakes an hour** for a conversation. An agent that hands work to many sub-chats is woken once for each that answers on its own, and those that answer together come in one wake; the busiest such round seen had eighteen sub-chats. Thirty leaves room for that and the builds it waits on, and stops a loop: a command whose end has the woken agent start it again, or work handed back and forth. The thirtieth wake tells the agent it was the last for now. After it, what ends is kept, and the person is told: "pi² has woken the agent 30 times in the last hour, the most it does. What ends now is kept for it, and given to it at 14:32, or after your next message." It goes when the first of those wakes is an hour old, all together. A message from the person starts the count again: they are there to see what the agent does.
- **An engine that stops.** What the agent waits for is kept in the engine's database from the moment it starts, and so is what has ended and not been handed over. An engine that starts again hands over what was waiting, follows the sub-chats again (their runs carry on as any run does), and a background command that ended with the engine wakes the agent once, saying it "ended when pi²’s engine stopped". Nothing is handed over twice.

## For developers

- `engine/src/wakes.ts` is a feature. Its session document, `pi2.wakes`, holds `watching` (what will wake whom: `{ key, conversationId, kind, ref, label, startedAt, submissionId?, agent? }`), `arrived` (by conversation, oldest first), `woken` (by conversation, when it was woken in the last hour), `held` (why a conversation is not woken for now) and `seen` (keys that arrived, kept for a week, so that a call run again after a crash cannot watch the same thing twice).
- `watch` starts watching; `arrive` moves a watch to `arrived` in one commit, so it arrives once; `unwatch` lets one go. `delegate` (`engine/src/extensions.ts`) watches the sub-chat's submission and follows it with `harness.submission(id).wait()`, which `start` does again for every sub-chat watch once the engine is ready; `subChatResult` puts the result in the words `delegate` uses. `startInBackground` (`engine/src/background.ts`) watches a command before it starts it, and passes its end on from where it notes it, also for the commands the last engine left.
- A sub-chat that is not waited for belongs to no tool call (`ownerless`): one owned by the call would keep the call from ending until the sub-chat was idle. `Meta.madeBy` names the call that made it, so that the call, run again after a crash, finds it instead of making another, as ownership does for the waiting form. It is sent its task as the person's messages are (`Host.sendToChat`).
- Waking is one input, entry kind `pi2.wake` (`{ items: [{ kind, ref, label, ended }] }`, a line in the transcript), submitted with `whenBusy: "reject"` inside the commit that takes what arrived: if a run started in between, nothing is written, and the end of that run looks again. It is tried when something arrives, whenever what is running changes (`runsChanged`), when usage is counted again (`usageChanged`), and when a hold's time is up. Lines for the person alone are entries of kind `pi2.wake-note`.
- Features take part in three more moments (`engine/src/features.ts`): `messageSent` and `stopped`, when the person sends a message or stops a conversation, and `usageChanged`. The engine also tells a feature whether today's budget is used up (`overBudget`).
- The engine sends `{"event": "wakes", "items": [{ key, conversationId, rootConversationId, kind, ref, label, startedAt, state }], "held": [{ conversationId, why, since, until }], "perHour"}` whenever that changes, and to each app as it connects. `wakes.cancel { conversationId, key? }` is Don't Wake; `wakes.resume { conversationId }` is Wake When Done. The app's side is `app/Sources/pi2/WakeViews.swift`.
- The demo model acts on the first line of a wake that starts with `/`, as if it had been typed, so a test chooses what a woken agent does by what a command prints. `PI2_WAKES_PER_HOUR` sets another cap, for the test.
- `node test/wakes.ts` from `engine/` (also part of `npm test`) checks all of the above against a real engine with the demo model: a sub-chat started without waiting and its wake, two that end during an answer coming together and in order, `sub_chats` with `wait`, a command with `wake: true` and the ends that do not wake, the turn limit, Ask first, the budget, the cap reached by a loop of the agent's own making, Stop and Don't Wake, archiving and deleting, and an engine stopped and started again.

## Known limits

- A message from the person ends a call that only waits, but not a code mode script or the calls it makes ([architecture.md](architecture.md#a-message-while-an-agent-waits)).
