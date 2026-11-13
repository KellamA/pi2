# The task list

When an agent takes on something with several steps, it can keep a short checklist for the conversation. The person sees it pinned above the message field without reading the transcript.

## For the agent

The `update_plan` tool is offered in every conversation, sub-chats included, and never asks for approval. It takes the whole list each time: `items`, each `{ content, status }` with status `pending`, `in_progress` or `completed`. It replaces the previous list and answers "3 of 5 done".

A list is refused, and the old one kept, when it has no items, more than 20, an item with no text or more than 120 characters, an unknown status, or more than one `in_progress`. The refusal says what to fix.

A short section of the prompt tells the model to use it for work of three or more steps, to write the list first, to keep one item in progress, to tick items off as they are done, and not to use it for a quick answer.

## Where it lives

In a durable document per conversation (`pi2.plan`, in `src/plan.ts`). It survives a restart, a fork starts with a copy of its parent's list, and a sub-chat has its own. The conversation state sent to the app carries it as `plan: { items, updatedAt }`, or `null`.

pi durable's conversation view holds only its own documents, so the engine reads the list when the app opens a conversation (`preparePlan`, called from `subscribe` in `main.ts`) and `update_plan` refreshes it as it writes.

## In the app

`PlanStrip.swift`: nothing without a list; otherwise one line with a progress ring, "3 of 5" and the step in hand, which opens to the whole checklist. When every item is done and the agent has stopped, it reads "All 5 done" and can be dismissed. A new list shows again. A dismissal is not remembered across restarts of the app.
