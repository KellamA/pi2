### For contributors
- The conversation page's web view is in a module of its own, `TranscriptKit`, with the page loaded ahead for the next pane, and `pi2-transcript-check` checks it with real pages in windows that never come on screen; CI runs it. The speed probe's line for an opening now has a `page ready` step.
