# Schedules an agent sets for itself

An agent asked to "check this every morning" or "look again in two hours" can set the schedule itself, if the person has allowed it, and the person approves each one before it is set. It is the same kind of schedule the person makes in Activity › Schedules: at its time, a new conversation starts with the agent and the schedule's prompt. The engine side is `engine/src/selfschedule.ts`; the schedules themselves are in `engine/src/schedules.ts` and run from `main.ts`.

## Turning it on

Per agent, and **off by default**. In the agent's settings, under Schedules: "Can schedule its own work". With it off the agent has no scheduling tools and nothing about them in its prompt. Turning it on or off reaches the agent's existing conversations at their next message, like the agent's other settings.

Turning it off takes the tools away. Schedules the agent already set, which the person approved, keep running until the person turns them off or deletes them in Activity.

## What the agent can do

Three tools, and a short prompt section, `scheduling`.

- **`schedule_task`** asks for a new schedule: a `title` the person sees, a `prompt` the run will be given, and when.
  - `repeat: "once"` with `at`, a local date and time such as `2026-11-13 09:00`, or `in_minutes` from now.
  - `repeat: "daily"` with `time`, such as `07:30`, on the 24-hour clock.
  - `repeat: "weekly"` with `weekday` (`monday` to `sunday`) and `time`.
  - `repeat: "interval"` with `minutes` between runs.
- **`list_schedules`** lists the schedules for this agent: each one's id, title, when it runs, its next run or whether it is off or finished, a shortened prompt, and whether the agent or the person set it. It starts with the current local time.
- **`cancel_schedule { id }`** deletes a schedule this agent set. Listing and cancelling never ask.

What it cannot do:

- Schedule another agent. A schedule always runs as the agent whose conversation set it (in a sub-chat, the agent the work was handed to).
- Cancel or change a schedule the person made. It is refused with a plain message saying the person can turn it off or delete it in Activity. A schedule the agent set that the person has since moved to another agent counts as the person's.
- Change a schedule. To change one it cancels it and asks for a new one, which is asked about again.

## Times

Times are the Mac's local time, with no time zone given: a time with `Z` or an offset is refused, so is a date or hour that does not exist. The prompt section gives today's date and the time zone (such as `America/Los_Angeles (UTC-08:00)`), so "tomorrow at 9" can be worked out. It gives the date and not the clock, because a section that changes is sent to the model again, and a clock would change at every message. For a time counted from now the agent uses `in_minutes`; `list_schedules` and any refusal about a time say what time it is now.

Daily and weekly schedules follow the wall clock, through changes to and from summer time, as the person's do.

## The approval

Every new schedule asks the person first, whatever the agent's tool access. A schedule runs later with no one watching, so there is **no "always allow"**: the choices are Allow Once and Deny. (An app that sends "always" anyway is treated as once, and nothing is remembered.)

The question goes to the Inbox and to the call in the transcript, like any approval. It says what will run and when, in plain words:

> Atlas wants to schedule “Morning news brief”: every day at 07:00, first run Friday 13 November at 07:00 — Sum up the morning's news in five lines.

The cards show the title in the heading, when it would run (the item's `when`, worded by the engine), the prompt in full, and a line saying that each run starts a new conversation with no one watching and can be turned off or deleted in Activity. Dates are written out ("Friday 13 November"), never "tomorrow", because a question can wait past midnight. A notification, if they are on, carries the whole sentence.

Before asking, the engine checks everything it can: the switch, the words, the time and the limits. A call that could not be carried out is refused with a reason and nothing is asked. After the person allows it, the engine checks again (the switch may have been turned off, the time may have passed, the agent may have reached its limit meanwhile) and only then saves it. If the person denies it, nothing is saved and the agent is told not to ask again unless the person brings it up.

The first run is the one shown in the question, unless it went by while the question waited; then it is the next one after the decision.

## Limits

- Repeating schedules run at most every **15 minutes** (and at least every 30 days). Daily and weekly ones are well within that.
- Each agent may have **20** schedules it set that can still run. A one-off that has run is finished and does not count; it stays listed until the agent cancels it or the person deletes it. Beyond the limit the call is refused, before anything is asked, with a message saying to cancel one first. The person's own schedules for the agent do not count.
- A title is one line of at most **80** characters; a prompt at most **2,000**.
- A one-off can be at most a year ahead.

## Nothing runs on its own without the person

Each new schedule waits for the person, every time. A run started by a schedule can itself call `schedule_task`; its question then waits in the Inbox like any other, and nothing more is set until the person answers. The same goes for a script that calls the tool (code mode): each call asks. Many calls asked together each wait for their own answer, and the limit of 20 is checked again as each is saved.

The run itself works with the agent's own tool access, as the person's scheduled runs do: under "Ask first" its commands wait in the Inbox too.

## Who made it

A schedule an agent set carries `createdBy: { agentId, conversationId }`. Only the engine sets it: `schedules.save` from the app ignores it on a new schedule and keeps it when the person edits one. Activity shows "set by Atlas" on its row, and the row's tooltip names the conversation it was set in.

Deleting an agent does not touch schedules, the person's or the agent's: they stay listed, and a run whose agent is gone starts with the first agent, as before. The row then says "set by a deleted agent".

## Crashes

`schedule_task` is safe to run again. The schedule's id and its times are kept with the call before the question is asked, so after a restart the same question is asked again (the same schedule, at the same time), and a call whose schedule was already saved finds it and does not save a second.

## Tests

In `engine/test/engine.ts`, the `selfschedule` block: tools absent with the switch off; deny makes nothing; allow once makes it with `createdBy`; "always" is not remembered; asked again after `kill -9`; listing and who set what; cancelling only the agent's own; too often, too long, already passed and the cap refused without asking, the cap through a script whose every call asks; a schedule that fires and starts a conversation whose own `schedule_task` waits for the person; the person's edits keep `createdBy`; switching off. The one-line summaries and the approval card's wording are tested in `app/Web/test/tools.test.mjs`.
