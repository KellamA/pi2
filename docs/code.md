# Working things out with code

`run_code` runs a short JavaScript program and gives back what it printed: for arithmetic, dates, counting, converting or checking data, anything a model is better off working out than guessing (#286). It is one of the [built-in tools](architecture.md#built-in-tools), **Work things out with code**, key `code`, and it is **off by default**: an agent is offered it only once its settings turn it on (`toolsOn`), and the chat assistant is given it. An agent without it has nothing more in its prompt or tool definitions.

## What a program can do

`code` is the body of an async function, as in code mode: `console.log()` and `text()` print, `return` gives a value, top-level `await` works. The result is what it printed, in order, then `Returned: …` (a string as it is, anything else as JSON), or the error with its stack. Output longer than 30,000 characters keeps its start and end, with how much was left out between. `timeout` gives it up to 120 seconds; without it, 30. It may allocate 64 MB, beyond which an allocation fails inside the program as `InternalError: out of memory`. Nothing is kept between calls.

## What it cannot reach

The program runs in the sandbox code mode's scripts run in, pi-codemode's QuickJS VM in a worker thread of its own, with **no tools and no globals** added (`src/runcode.ts`):

- **No files, network or processes.** QuickJS has no `require`, `process`, `fetch`, `XMLHttpRequest`, `WebSocket` or timers, and `import()` of anything (`node:fs`, QuickJS's own `qjs:os`) fails. The VM is WebAssembly, and the only system calls it is given (quickjs-wasi's WASI shim) are a clock, random numbers and a standard output that is thrown away: there is nothing through which it could open a file or a socket.
- **No tools.** `tools` is empty and `ALL_TOOLS` lists nothing, unlike a code mode script, which calls the conversation's tools.
- **Stopped when it runs too long or is stopped.** At its time limit, or when the person stops the answer, the VM is interrupted and its worker thread terminated, so a program that never ends (`while (true) {}`, or one that only awaits) does not go on in the background.

So it changes nothing on the Mac, and never asks for approval, at any access level, **No tools** included. It is not one of the tools that run one at a time ([The calls of one answer](architecture.md#the-calls-of-one-answer)), and a call cut off by a restart is run again.

## In the conversation

The row reads "Worked it out with code" and opens to the program and what it printed.

## Checking it

`engine/test/runcode.ts` drives the sandbox the tool uses: printing and returning, errors, that `require`, `process`, `fetch`, timers, `import()` and `tools` are not there (no file is written and a server on 127.0.0.1 is never asked anything), that a program that never ends is stopped at its limit and its worker thread exits, that one stopped from outside ends, that too much memory fails inside the program, and that a long output is shortened. `engine/test/offered.ts` checks that no agent is offered `run_code` until its settings turn it on, that it then comes alone with no section, at any access level, and runs without asking, and that a copy of the agent keeps it.
